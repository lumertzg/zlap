//! Comptime compilation of command declarations into parser tables.

const std = @import("std");
const declaration = @import("declaration.zig");
const schema = @import("schema.zig");

pub const Node = struct {
    parent: ?schema.CmdId,
    name: []const u8,
    command_field: ?[]const u8,
    variant: ?[]const u8,
    depth: u16,
};

pub const Binding = struct {
    command: schema.CmdId,
    field: []const u8,
    parse_arg_expected: ?[]const u8 = null,
};

const FieldKind = struct {
    kind: schema.ValueKind,
    list_element: ?schema.ValueKind = null,
};

const CommandField = struct {
    index: usize,
    union_type: type,
};

const Stats = struct {
    nodes: usize = 0,
    bindings: usize = 0,
    names: usize = 0,
    commands: usize = 0,
    positionals: usize = 0,
    global_names: usize = 0,
    max_depth: u16 = 0,
};

const State = struct {
    next_node: usize = 1,
    next_binding: usize = 0,
    next_name: usize = 0,
    next_command: usize = 0,
    next_positional: usize = 0,
};

const BuildNode = struct {
    id: schema.CmdId,
    parent: ?schema.CmdId,
    name: []const u8,
    command_field: ?[]const u8,
    variant: ?[]const u8,
    depth: u16,
};

const ScopeData = struct {
    name_start: usize,
    name_count: usize,
    command_start: usize,
    command_count: usize,
    positional_start: usize,
    positional_count: usize,
    default_command: ?schema.CmdId = null,
    external_command: ?schema.CmdId = null,
    unknown_flags: schema.UnknownFlags,
};

fn BuildContext(comptime T: type) type {
    return struct {
        data: *TableData(T),
        state: *State,
    };
}

fn TableData(comptime T: type) type {
    const stats = treeStats(T, 0, 0);
    return struct {
        nodes: [stats.nodes]Node,
        bindings: [stats.bindings]Binding,
        flags: [stats.bindings]schema.Flag,
        scope_data: [stats.nodes]ScopeData,
        names: [stats.names]schema.Name,
        commands: [stats.commands]schema.Command,
        positionals: [stats.positionals]schema.FlagId,
    };
}

/// The generated tables are shared by parsers of `T` and describe every command node.
pub fn Compiled(comptime T: type) type {
    @setEvalBranchQuota(1_000_000);
    validateTree(T);
    const stats = treeStats(T, 0, 0);
    validateCounts(stats);

    return struct {
        const generated = buildTableData(T);
        const scopes = buildScopes(&generated);

        pub const table: schema.Table = .{
            .scopes = &scopes,
            .flags = &generated.flags,
        };
        pub const nodes = &generated.nodes;
        pub const bindings = &generated.bindings;
        pub const max_depth = stats.max_depth;
    };
}

fn buildScopes(comptime generated: anytype) [generated.nodes.len]schema.Scope {
    var scopes: [generated.nodes.len]schema.Scope = undefined;
    inline for (generated.scope_data, 0..) |scope_data, index| {
        const positional_end = scope_data.positional_start + scope_data.positional_count;
        scopes[index] = .{
            .names = generated.names[scope_data.name_start..][0..scope_data.name_count],
            .commands = generated.commands[scope_data.command_start..][0..scope_data.command_count],
            .positionals = generated.positionals[scope_data.positional_start..positional_end],
            .default_command = scope_data.default_command,
            .external_command = scope_data.external_command,
            .unknown_flags = scope_data.unknown_flags,
        };
    }
    return scopes;
}

fn buildTableData(comptime T: type) TableData(T) {
    @setEvalBranchQuota(1_000_000);

    const stats = treeStats(T, 0, 0);
    var data: TableData(T) = undefined;
    var state: State = .{};
    var no_globals: [0]schema.Name = .{};
    var context: BuildContext(T) = .{ .data = &data, .state = &state };
    buildNode(
        T,
        &context,
        .{
            .id = 0,
            .parent = null,
            .name = "",
            .command_field = null,
            .variant = null,
            .depth = 0,
        },
        no_globals[0..],
        .@"error",
        false,
        stats.global_names,
    );

    std.debug.assert(state.next_node == stats.nodes);
    std.debug.assert(state.next_binding == stats.bindings);
    std.debug.assert(state.next_name <= stats.names);
    std.debug.assert(state.next_command == stats.commands);
    std.debug.assert(state.next_positional == stats.positionals);
    return data;
}

fn buildNode(
    comptime T: type,
    context: anytype,
    node: BuildNode,
    inherited: []const schema.Name,
    inherited_unknown_flags: schema.UnknownFlags,
    inherited_version: bool,
    comptime global_capacity: usize,
) void {
    const data = context.data;
    const state = context.state;
    if (T == schema.ExternalCommand) {
        data.nodes[node.id] = .{
            .parent = node.parent,
            .name = node.name,
            .command_field = node.command_field,
            .variant = node.variant,
            .depth = node.depth,
        };
        data.scope_data[node.id] = .{
            .name_start = state.next_name,
            .name_count = 0,
            .command_start = state.next_command,
            .command_count = 0,
            .positional_start = state.next_positional,
            .positional_count = 0,
            .unknown_flags = inherited_unknown_flags,
        };
        return;
    }
    const meta = commandMeta(T);
    const name_start = state.next_name;
    const positional_start = state.next_positional;
    var scope_name_count: usize = 0;
    var local_globals: [global_capacity]schema.Name = undefined;
    var local_global_count: usize = 0;

    data.nodes[node.id] = .{
        .parent = node.parent,
        .name = node.name,
        .command_field = node.command_field,
        .variant = node.variant,
        .depth = node.depth,
    };

    buildBindings(
        T,
        context,
        node.id,
        name_start,
        &scope_name_count,
        local_globals[0..],
        &local_global_count,
    );

    appendInheritedNames(data.names[name_start..], &scope_name_count, inherited);
    const version_available = inherited_version or meta.version != null;
    appendActions(data.names[name_start..], &scope_name_count, version_available);
    state.next_name = name_start + scope_name_count;

    const unknown_flags = meta.unknown_flags orelse inherited_unknown_flags;
    data.scope_data[node.id] = .{
        .name_start = name_start,
        .name_count = scope_name_count,
        .command_start = state.next_command,
        .command_count = 0,
        .positional_start = positional_start,
        .positional_count = state.next_positional - positional_start,
        .unknown_flags = unknown_flags,
    };

    buildChildren(
        T,
        context,
        node,
        inherited,
        unknown_flags,
        version_available,
        local_globals[0..local_global_count],
        global_capacity,
    );
}

fn buildBindings(
    comptime T: type,
    context: anytype,
    node_id: schema.CmdId,
    name_start: usize,
    scope_name_count: *usize,
    local_globals: []schema.Name,
    local_global_count: *usize,
) void {
    const data = context.data;
    const state = context.state;
    const meta = commandMeta(T);

    const info = structInfo(T);
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (isCommandField(Field)) continue;

        const options = @field(meta.fields, field_name);
        const id: schema.FlagId = @intCast(state.next_binding);
        const field_kind = classifyField(Field);
        state.next_binding += 1;
        data.bindings[id] = .{
            .command = node_id,
            .field = field_name,
            .parse_arg_expected = parseArgExpected(Field),
        };
        data.flags[id] = .{
            .kind = if (options.count) .count else field_kind.kind,
            .list_element = field_kind.list_element,
            .positional = options.positional,
            .require_equals = options.require_equals,
            .allow_hyphen_values = options.allow_hyphen_values,
            .default_missing = options.default_missing,
            .min = options.min,
            .max = options.max,
            .one_of_flags = options.one_of_flags,
        };

        if (options.positional) {
            appendPositional(data.positionals[0..], &state.next_positional, id);
            continue;
        }
        appendFieldNames(data.names[name_start..], scope_name_count, field_name, Field, options, id, true);
        if (options.global) {
            appendFieldNames(local_globals, local_global_count, field_name, Field, options, id, true);
        }
    }
}

fn buildChildren(
    comptime T: type,
    context: anytype,
    parent: BuildNode,
    inherited: []const schema.Name,
    inherited_unknown_flags: schema.UnknownFlags,
    inherited_version: bool,
    local_globals: []const schema.Name,
    comptime global_capacity: usize,
) void {
    const command = commandField(T) orelse return;
    const meta = commandMeta(T);
    const data = context.data;
    const state = context.state;
    const union_meta = variantsMeta(command.union_type);
    const variants = unionInfo(command.union_type);
    const command_start = state.next_command;
    var scope_command_count: usize = 0;
    var child_globals: [global_capacity]schema.Name = undefined;
    var child_global_count: usize = 0;
    var child_ids: [variants.field_names.len]schema.CmdId = undefined;
    appendNamesUnlessClaimed(child_globals[0..], &child_global_count, local_globals);
    appendNamesUnlessClaimed(child_globals[0..], &child_global_count, inherited);

    inline for (variants.field_names, variants.field_types, 0..) |variant_name, Variant, index| {
        const child_id: schema.CmdId = @intCast(state.next_node);
        state.next_node += 1;
        child_ids[index] = child_id;
        const options = @field(union_meta.variants, variant_name);
        if (isExternalVariant(Variant)) continue;
        const child_name = options.name orelse kebabCase(variant_name);
        appendCommand(data.commands[command_start..], &scope_command_count, child_name, child_id);
        inline for (options.aliases) |alias| {
            appendCommand(data.commands[command_start..], &scope_command_count, alias, child_id);
        }
    }
    state.next_command = @max(state.next_command, command_start + scope_command_count);

    if (meta.default_subcommand) |default_variant| {
        data.scope_data[parent.id].default_command = child_ids[
            unionFieldIndex(
                command.union_type,
                @tagName(default_variant),
            )
        ];
    }
    if (meta.external_subcommand) {
        data.scope_data[parent.id].external_command = child_ids[
            externalVariantIndex(command.union_type)
        ];
    }

    inline for (variants.field_names, variants.field_types, 0..) |variant_name, Variant, index| {
        const options = @field(union_meta.variants, variant_name);
        buildNode(
            Variant,
            context,
            .{
                .id = child_ids[index],
                .parent = parent.id,
                .name = options.name orelse kebabCase(variant_name),
                .command_field = structInfo(T).field_names[command.index],
                .variant = variant_name,
                .depth = parent.depth + 1,
            },
            child_globals[0..child_global_count],
            inherited_unknown_flags,
            inherited_version,
            global_capacity,
        );
    }
    data.scope_data[parent.id].command_count = scope_command_count;
}

fn validateTree(comptime T: type) void {
    validateCommand(T);
    if (commandField(T)) |command| {
        validateVariants(command.union_type, commandMeta(T).external_subcommand);
        const variants = unionInfo(command.union_type);
        inline for (variants.field_types) |Variant| {
            if (!isExternalVariant(Variant)) validateTree(Variant);
        }
    }
}

fn validateCounts(comptime stats: Stats) void {
    const max_id_count = @as(usize, std.math.maxInt(schema.CmdId)) + 1;
    if (stats.nodes > max_id_count) @compileError("zlap supports at most 65536 command nodes");
    if (stats.bindings > max_id_count) @compileError("zlap supports at most 65536 bindings");
}

fn validateCommand(comptime T: type) void {
    const meta = commandMeta(T);
    const fields = structInfo(T);
    var command_count: usize = 0;
    var previous_positional_list = false;
    var previous_list_max: ?u32 = null;

    if (meta.repeated_scalar == .@"error") {
        @compileError("zlap does not support repeated_scalar = .error");
    }

    inline for (fields.field_names, fields.field_types, fields.field_attrs) |field_name, Field, attrs| {
        const options = @field(meta.fields, field_name);
        if (isCommandField(Field)) {
            command_count += 1;
            validateCommandField(Field, attrs, options);
            continue;
        }

        validateField(T, field_name, Field, attrs, options);
        if (options.positional) {
            if (previous_positional_list and previous_list_max == null) {
                @compileError("zlap positional lists before another positional require .max");
            }
            previous_positional_list = classifyField(Field).kind == .list;
            previous_list_max = options.max;
        }
    }
    if (command_count > 1) @compileError("zlap supports at most one command field per struct");
    validateSubcommandPolicies(T, command_count);
}

fn validateSubcommandPolicies(comptime T: type, comptime command_count: usize) void {
    const meta = commandMeta(T);
    const command = commandField(T);
    if (meta.default_subcommand != null) {
        if (command == null) {
            @compileError("zlap default_subcommand requires an optional command field");
        }
        if (@typeInfo(structInfo(T).field_types[command.?.index]) != .optional) {
            @compileError("zlap default_subcommand requires an optional command field");
        }
        if (isExternalVariant(unionInfo(command.?.union_type).field_types[
            unionFieldIndex(command.?.union_type, @tagName(meta.default_subcommand.?))
        ])) {
            @compileError("zlap default_subcommand cannot select an external subcommand");
        }
    }
    if (!meta.external_subcommand) {
        if (command) |field| {
            if (hasExternalVariant(field.union_type)) {
                @compileError("zlap ExternalCommand requires .external_subcommand = true");
            }
        }
        return;
    }
    if (command_count != 1 or command == null or !hasExternalVariant(command.?.union_type)) {
        @compileError("zlap external_subcommand requires one ExternalCommand variant");
    }
    if (meta.default_subcommand != null) {
        @compileError("zlap external_subcommand cannot be combined with default_subcommand");
    }
    const info = structInfo(T);
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (isCommandField(Field)) continue;
        if (@field(meta.fields, field_name).positional) {
            @compileError("zlap external_subcommand cannot be combined with positional fields");
        }
    }
}

fn validateCommandField(
    comptime Field: type,
    comptime attrs: std.lang.Type.Struct.FieldAttributes,
    comptime options: anytype,
) void {
    if (@typeInfo(Field) == .optional) {
        const default_value = attrs.defaultValue(Field) orelse
            @compileError("zlap optional command fields must default to null");
        if (default_value != null) {
            @compileError("zlap optional command fields must default to null");
        }
    }
    if (options.positional or options.global or options.count or options.short != null or
        options.long != null or options.aliases.len != 0 or options.negate != null or
        options.default_missing != null or options.require_equals or options.allow_hyphen_values or
        options.env != null or options.min != null or options.max != null or
        options.one_of_flags or options.conflicts.len != 0 or options.requires.len != 0)
    {
        @compileError("zlap command fields cannot have flag metadata");
    }
}

fn validateVariants(comptime U: type, comptime external_subcommand: bool) void {
    const meta = variantsMeta(U);
    if (variantsHaveCollision(U)) {
        @compileError("zlap duplicate subcommand spelling");
    }
    const info = unionInfo(U);
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (isExternalVariant(Field)) {
            validateExternalVariant(@field(meta.variants, field_name), external_subcommand);
            continue;
        }
        if (@typeInfo(Field) != .@"struct") {
            @compileError("zlap command variants must contain struct command payloads");
        }
        const options = @field(meta.variants, field_name);
        validateCommandName(options.name orelse kebabCase(field_name));
        inline for (options.aliases) |alias| validateCommandName(alias);
    }
}

fn validateExternalVariant(comptime options: anytype, comptime external_subcommand: bool) void {
    if (!external_subcommand) {
        @compileError("zlap ExternalCommand requires .external_subcommand = true");
    }
    if (options.name != null or options.aliases.len != 0) {
        @compileError("zlap external subcommands cannot have names or aliases");
    }
}

fn variantsHaveCollision(comptime U: type) bool {
    const meta = variantsMeta(U);
    var names: [commandNameCount(U)][]const u8 = undefined;
    var count: usize = 0;
    const info = unionInfo(U);
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (isExternalVariant(Field)) continue;
        const options = @field(meta.variants, field_name);
        const name = options.name orelse kebabCase(field_name);
        for (names[0..count]) |previous| {
            if (std.mem.eql(u8, previous, name)) return true;
        }
        names[count] = name;
        count += 1;
        inline for (options.aliases) |alias| {
            for (names[0..count]) |previous| {
                if (std.mem.eql(u8, previous, alias)) return true;
            }
            names[count] = alias;
            count += 1;
        }
    }
    return false;
}

fn validateField(
    comptime T: type,
    comptime field_name: []const u8,
    comptime Field: type,
    comptime attrs: std.lang.Type.Struct.FieldAttributes,
    comptime options: anytype,
) void {
    const field_kind = classifyField(Field);
    if (isOptionalScalar(Field)) {
        const default_value = attrs.defaultValue(Field) orelse
            @compileError("zlap optional scalar fields must default to null");
        if (default_value != null) {
            @compileError("zlap optional scalar fields must default to null");
        }
    }
    if (options.count) {
        if (options.positional) @compileError("zlap count fields cannot be positional");
        if (!isInteger(Field)) @compileError("zlap count requires an integer field");
    }
    if (options.global and options.positional) {
        @compileError("zlap global fields cannot be positional");
    }
    if (options.negate != null and field_kind.kind != .boolean) {
        @compileError("zlap negate requires a bool field");
    }
    if (options.negate != null and options.positional) {
        @compileError("zlap positional fields cannot have negate names");
    }
    if (options.one_of_flags) {
        validateOneOfFlags(Field, attrs, options);
    }
    if (options.default_missing != null and !takesValue(field_kind, options.count)) {
        @compileError("zlap default_missing requires a value-taking field");
    }
    if (options.require_equals and !takesValue(field_kind, options.count)) {
        @compileError("zlap require_equals requires a value-taking field");
    }
    if (options.env) |env| {
        if (env.len == 0) @compileError("zlap environment names cannot be empty");
        if (options.count) @compileError("zlap count fields cannot have environment fallback");
    }
    validateListBounds(field_kind, options);
    validateRelationships(T, field_name, options);
    if (options.positional) {
        validatePositionalOptions(options);
    } else {
        validateNamedOptions(options);
    }
}

fn validateOneOfFlags(
    comptime Field: type,
    comptime attrs: std.lang.Type.Struct.FieldAttributes,
    comptime options: anytype,
) void {
    if (@typeInfo(Field) != .@"enum") {
        @compileError("zlap one_of_flags requires an enum field");
    }
    if (attrs.default_value_ptr != null) {
        @compileError("zlap one_of_flags fields must not have a default");
    }
    if (options.positional or options.count or options.short != null or options.long != null or
        options.aliases.len != 0 or options.negate != null or options.default_missing != null or
        options.require_equals or options.allow_hyphen_values)
    {
        @compileError("zlap one_of_flags only supports its generated long switches");
    }
}

fn validateListBounds(comptime field_kind: FieldKind, comptime options: anytype) void {
    if (options.min != null or options.max != null) {
        if (field_kind.kind != .list) @compileError("zlap min and max require a list field");
    }
    if (options.min) |min| {
        if (options.max) |max| {
            if (min > max) @compileError("zlap list min cannot exceed max");
        }
    }
}

fn validateRelationships(
    comptime T: type,
    comptime field_name: []const u8,
    comptime options: anytype,
) void {
    validateRelationshipTargets(T, field_name, options.conflicts);
    validateRelationshipTargets(T, field_name, options.requires);
    inline for (options.conflicts) |conflict| {
        inline for (options.requires) |requirement| {
            if (conflict == requirement) {
                @compileError("zlap a field cannot conflict with and require the same field");
            }
        }
    }
}

fn validateRelationshipTargets(
    comptime T: type,
    comptime field_name: []const u8,
    comptime targets: anytype,
) void {
    inline for (targets, 0..) |target, index| {
        const target_name = @tagName(target);
        if (std.mem.eql(u8, field_name, target_name)) {
            @compileError("zlap fields cannot declare relationships with themselves");
        }
        if (isCommandField(@FieldType(T, target_name))) {
            @compileError("zlap relationships cannot target command fields");
        }
        inline for (targets[0..index]) |previous| {
            if (previous == target) @compileError("zlap duplicate field relationship");
        }
    }
}

fn validatePositionalOptions(comptime options: anytype) void {
    if (options.short != null or options.long != null or options.aliases.len != 0) {
        @compileError("zlap positional fields cannot have names");
    }
    if (options.require_equals or options.default_missing != null) {
        @compileError("zlap positional fields cannot require a flag value policy");
    }
}

fn validateNamedOptions(comptime options: anytype) void {
    if (options.long) |long| validateCommandName(long);
    inline for (options.aliases) |alias| validateCommandName(alias);
    if (options.negate) |negate| validateCommandName(negate);
    if (options.short) |short| {
        if (short == '-') @compileError("zlap short names cannot be '-'");
    }
}

fn validateCommandName(comptime name: []const u8) void {
    if (name.len == 0) @compileError("zlap names cannot be empty");
    if (name[0] == '-') @compileError("zlap names are raw and cannot start with '-'");
    if (std.mem.indexOfScalar(u8, name, '=') != null) {
        @compileError("zlap names and aliases cannot contain '='");
    }
}

fn treeStats(comptime T: type, inherited_global_names: usize, depth: u16) Stats {
    const fields = structInfo(T);
    var result: Stats = .{
        .nodes = 1,
        .names = declaredNameCount(T) + inherited_global_names + 4,
        .positionals = positionalCount(T),
        .global_names = globalNameCount(T),
        .max_depth = depth,
    };
    inline for (fields.field_types) |Field| {
        if (!isCommandField(Field)) result.bindings += 1;
    }
    if (commandField(T)) |command| {
        const child_inherited = inherited_global_names + globalNameCount(T);
        result.commands += commandNameCount(command.union_type);
        const variants = unionInfo(command.union_type);
        inline for (variants.field_types) |Variant| {
            const child = if (isExternalVariant(Variant))
                externalStats(depth + 1)
            else
                treeStats(Variant, child_inherited, depth + 1);
            result.nodes += child.nodes;
            result.bindings += child.bindings;
            result.names += child.names;
            result.commands += child.commands;
            result.positionals += child.positionals;
            result.global_names += child.global_names;
            result.max_depth = @max(result.max_depth, child.max_depth);
        }
    }
    return result;
}

fn commandNameCount(comptime U: type) usize {
    const meta = variantsMeta(U);
    var count: usize = 0;
    const info = unionInfo(U);
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (isExternalVariant(Field)) continue;
        count += 1 + @field(meta.variants, field_name).aliases.len;
    }
    return count;
}

fn externalStats(depth: u16) Stats {
    return .{ .nodes = 1, .max_depth = depth };
}

fn isExternalVariant(comptime Variant: type) bool {
    return Variant == schema.ExternalCommand;
}

fn hasExternalVariant(comptime U: type) bool {
    var count: usize = 0;
    inline for (unionInfo(U).field_types) |Variant| {
        if (isExternalVariant(Variant)) count += 1;
    }
    if (count > 1) @compileError("zlap external_subcommand supports one ExternalCommand variant");
    return count == 1;
}

fn externalVariantIndex(comptime U: type) usize {
    inline for (unionInfo(U).field_types, 0..) |Variant, index| {
        if (isExternalVariant(Variant)) return index;
    }
    @compileError("zlap external_subcommand requires one ExternalCommand variant");
}

fn unionFieldIndex(comptime U: type, comptime name: []const u8) usize {
    inline for (unionInfo(U).field_names, 0..) |field_name, index| {
        if (std.mem.eql(u8, field_name, name)) return index;
    }
    @compileError("zlap command variant is missing from the declaration");
}

fn declaredNameCount(comptime T: type) usize {
    const meta = commandMeta(T);
    var count: usize = 0;
    const info = structInfo(T);
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (isCommandField(Field)) continue;
        const options = @field(meta.fields, field_name);
        if (!options.positional) count += fieldNameCount(Field, options);
    }
    return count;
}

fn globalNameCount(comptime T: type) usize {
    const meta = commandMeta(T);
    var count: usize = 0;
    const info = structInfo(T);
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (isCommandField(Field)) continue;
        const options = @field(meta.fields, field_name);
        if (options.global) count += fieldNameCount(Field, options);
    }
    return count;
}

fn positionalCount(comptime T: type) usize {
    const meta = commandMeta(T);
    var count: usize = 0;
    const info = structInfo(T);
    inline for (info.field_names, info.field_types) |field_name, Field| {
        if (isCommandField(Field)) continue;
        if (@field(meta.fields, field_name).positional) count += 1;
    }
    return count;
}

fn fieldNameCount(comptime T: type, comptime options: anytype) usize {
    if (options.one_of_flags) return @typeInfo(scalarType(T)).@"enum".field_names.len;
    var count: usize = 1 + options.aliases.len;
    if (options.short != null) count += 1;
    if (options.negate != null) count += 1;
    return count;
}

fn appendFieldNames(
    names: []schema.Name,
    count: *usize,
    comptime field_name: []const u8,
    comptime Field: type,
    comptime options: anytype,
    id: schema.FlagId,
    comptime reject_duplicates: bool,
) void {
    if (options.one_of_flags) {
        inline for (@typeInfo(scalarType(Field)).@"enum".field_names) |tag_name| {
            appendName(
                names,
                count,
                .{
                    .spelling = kebabCase(tag_name),
                    .target = .{ .flag = id },
                    .value = kebabCase(tag_name),
                },
                reject_duplicates,
            );
        }
        return;
    }
    appendName(
        names,
        count,
        .{
            .spelling = options.long orelse kebabCase(field_name),
            .target = .{ .flag = id },
        },
        reject_duplicates,
    );
    inline for (options.aliases) |alias| {
        appendName(
            names,
            count,
            .{ .spelling = alias, .target = .{ .flag = id } },
            reject_duplicates,
        );
    }
    if (options.short) |short| {
        appendName(
            names,
            count,
            .{ .spelling = &.{short}, .kind = .short, .target = .{ .flag = id } },
            reject_duplicates,
        );
    }
    if (options.negate) |negate| {
        appendName(
            names,
            count,
            .{ .spelling = negate, .target = .{ .flag = id }, .negated = true },
            reject_duplicates,
        );
    }
}

fn appendInheritedNames(names: []schema.Name, count: *usize, inherited: []const schema.Name) void {
    appendNamesUnlessClaimed(names, count, inherited);
}

fn appendNamesUnlessClaimed(
    names: []schema.Name,
    count: *usize,
    additions: []const schema.Name,
) void {
    for (additions) |name| {
        if (!hasName(names[0..count.*], name.spelling, name.kind)) {
            std.debug.assert(count.* < names.len);
            names[count.*] = name;
            count.* += 1;
        }
    }
}

fn appendActions(names: []schema.Name, count: *usize, version: bool) void {
    appendActionUnlessClaimed(names, count, "help", .long, .help);
    appendActionUnlessClaimed(names, count, "h", .short, .help);
    if (version) {
        appendActionUnlessClaimed(names, count, "version", .long, .version);
        appendActionUnlessClaimed(names, count, "V", .short, .version);
    }
}

fn appendActionUnlessClaimed(
    names: []schema.Name,
    count: *usize,
    spelling: []const u8,
    kind: schema.Name.Kind,
    action: schema.Action,
) void {
    if (hasName(names[0..count.*], spelling, kind)) return;
    appendName(
        names,
        count,
        .{ .spelling = spelling, .kind = kind, .target = .{ .action = action } },
        false,
    );
}

fn appendName(
    names: []schema.Name,
    count: *usize,
    name: schema.Name,
    comptime reject_duplicates: bool,
) void {
    std.debug.assert(count.* < names.len);
    if (hasName(names[0..count.*], name.spelling, name.kind)) {
        if (reject_duplicates) @compileError("zlap duplicate command spelling");
        return;
    }
    names[count.*] = name;
    count.* += 1;
}

fn appendPositional(positionals: []schema.FlagId, count: *usize, id: schema.FlagId) void {
    std.debug.assert(count.* < positionals.len);
    positionals[count.*] = id;
    count.* += 1;
}

fn appendCommand(
    commands: []schema.Command,
    count: *usize,
    spelling: []const u8,
    id: schema.CmdId,
) void {
    std.debug.assert(count.* < commands.len);
    for (commands[0..count.*]) |command| {
        if (std.mem.eql(u8, command.spelling, spelling)) {
            @compileError("zlap duplicate subcommand spelling");
        }
    }
    commands[count.*] = .{ .spelling = spelling, .id = id };
    count.* += 1;
}

fn hasName(names: []const schema.Name, spelling: []const u8, kind: schema.Name.Kind) bool {
    for (names) |name| {
        if (name.kind == kind and std.mem.eql(u8, name.spelling, spelling)) return true;
    }
    return false;
}

fn commandField(comptime T: type) ?CommandField {
    var found: ?CommandField = null;
    const info = structInfo(T);
    inline for (info.field_types, 0..) |Field, index| {
        const union_type = declaration.commandUnion(Field) orelse continue;
        if (found != null) @compileError("zlap supports at most one command field per struct");
        found = .{
            .index = index,
            .union_type = union_type,
        };
    }
    return found;
}

fn isCommandField(comptime T: type) bool {
    return declaration.isCommandField(T);
}

fn classifyField(comptime T: type) FieldKind {
    if (isOptionalScalar(T)) {
        const field_kind = classifyNonOptionalField(scalarType(T));
        if (field_kind.kind == .list) {
            @compileError("zlap optional fields must be scalar values");
        }
        return field_kind;
    }
    return classifyNonOptionalField(T);
}

fn classifyNonOptionalField(comptime T: type) FieldKind {
    return switch (@typeInfo(T)) {
        .bool => .{ .kind = .boolean },
        .int => |integer| .{ .kind = if (integer.signedness == .signed)
            .signed_integer
        else
            .unsigned_integer },
        .float => .{ .kind = .float },
        .@"enum" => .{ .kind = .enumeration },
        .pointer => |pointer| classifyPointer(pointer),
        else => if (hasParseArg(T)) blk: {
            validateParseArg(T);
            break :blk .{ .kind = .custom };
        } else @compileError("zlap field type is not supported"),
    };
}

fn classifyPointer(comptime pointer: std.lang.Type.Pointer) FieldKind {
    if (pointer.size != .slice or !pointer.attrs.@"const") {
        @compileError("zlap only supports []const slices as pointer fields");
    }
    if (pointer.child == u8) return .{ .kind = .string };
    return .{
        .kind = .list,
        .list_element = scalarKind(pointer.child) orelse
            @compileError("zlap list element type is not a supported scalar"),
    };
}

fn scalarKind(comptime T: type) ?schema.ValueKind {
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int => |integer| if (integer.signedness == .signed) .signed_integer else .unsigned_integer,
        .float => .float,
        .@"enum" => .enumeration,
        .pointer => |pointer| if (isConstStringSlice(pointer)) .string else null,
        else => if (hasParseArg(T)) blk: {
            validateParseArg(T);
            break :blk .custom;
        } else null,
    };
}

fn isConstStringSlice(comptime pointer: std.lang.Type.Pointer) bool {
    return pointer.size == .slice and pointer.attrs.@"const" and pointer.child == u8;
}

fn isInteger(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

fn scalarType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
}

fn isOptionalScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |optional| declaration.commandUnion(optional.child) == null,
        else => false,
    };
}

fn hasParseArg(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "parseArg"),
        .@"union" => @hasDecl(T, "parseArg"),
        .@"enum" => @hasDecl(T, "parseArg"),
        .@"opaque" => @hasDecl(T, "parseArg"),
        else => false,
    };
}

fn validateParseArg(comptime T: type) void {
    const parse_arg: *const fn ([]const u8) error{InvalidValue}!T = &T.parseArg;
    _ = parse_arg;
}

fn parseArgExpected(comptime T: type) ?[]const u8 {
    const scalar = scalarType(T);
    const Scalar = switch (@typeInfo(scalar)) {
        .pointer => |pointer| if (pointer.size == .slice and pointer.child != u8)
            pointer.child
        else
            scalar,
        else => scalar,
    };
    if (!hasParseArg(Scalar)) return null;
    if (!@hasDecl(Scalar, "parse_arg_expected")) return null;
    const expected: []const u8 = Scalar.parse_arg_expected;
    return expected;
}

fn takesValue(field_kind: FieldKind, count: bool) bool {
    return !count and field_kind.kind != .boolean;
}

const structInfo = declaration.structInfo;
const unionInfo = declaration.unionInfo;
const commandMeta = declaration.commandMeta;
const variantsMeta = declaration.variantsMeta;
const kebabCase = declaration.kebabCase;

test "Compiled generates leaf parser tables" {
    const Command = struct {
        dry_run: bool = false,
        verbose: u8 = 0,
        path: []const u8 = "",

        pub const meta: schema.Meta(@This()) = .{
            .version = "1.0.0",
            .fields = .{
                .dry_run = .{ .short = 'd', .negate = "no-dry-run" },
                .verbose = .{ .count = true, .short = 'v' },
                .path = .{ .positional = true },
            },
        };
    };

    const compiled = Compiled(Command);
    try std.testing.expectEqual(@as(usize, 1), compiled.nodes.len);
    try std.testing.expectEqual(@as(usize, 3), compiled.table.flags.len);
    try std.testing.expectEqual(@as(schema.FlagId, 2), compiled.table.scopes[0].positionals[0]);
    try std.testing.expectEqual(
        schema.Action.help,
        compiled.table.scopes[0].names[5].target.action,
    );
}

test "Compiled builds a two-level command tree" {
    const Leaf = struct { path: []const u8 = "" };
    const Commands = union(enum) {
        run_task: Leaf,
        pub const meta: schema.VariantsMeta(@This()) = .{ .variants = .{
            .run_task = .{ .name = "run", .aliases = &.{"r"} },
        } };
    };
    const Root = struct { command: Commands };

    const compiled = Compiled(Root);
    try std.testing.expectEqual(@as(usize, 2), compiled.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), compiled.bindings.len);
    try std.testing.expectEqual(@as(u16, 1), compiled.max_depth);
    try std.testing.expectEqualStrings("run", compiled.table.scopes[0].commands[0].spelling);
    try std.testing.expectEqualStrings("r", compiled.table.scopes[0].commands[1].spelling);
    try std.testing.expectEqual(@as(schema.CmdId, 0), compiled.nodes[1].parent.?);
    try std.testing.expectEqualStrings("command", compiled.nodes[1].command_field.?);
}

test "Compiled gives reused command payloads separate nodes and bindings" {
    const Payload = struct { force: bool = false };
    const Commands = union(enum) { first: Payload, second: Payload };
    const Root = struct { command: Commands };

    const compiled = Compiled(Root);
    try std.testing.expectEqual(@as(usize, 3), compiled.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), compiled.bindings.len);
    try std.testing.expectEqual(@as(schema.CmdId, 1), compiled.bindings[0].command);
    try std.testing.expectEqual(@as(schema.CmdId, 2), compiled.bindings[1].command);
}

test "Compiled inherits globals with nearest command shadowing" {
    const Leaf = struct {
        verbose: bool = false,
        local: bool = false,
        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .verbose = .{ .long = "verbose" },
        } };
    };
    const Commands = union(enum) { child: Leaf };
    const Root = struct {
        verbose: bool = false,
        command: ?Commands = null,
        pub const meta: schema.Meta(@This()) = .{ .unknown_flags = .as_value, .fields = .{
            .verbose = .{ .global = true },
        } };
    };

    const compiled = Compiled(Root);
    const child = compiled.table.scopes[1];
    try std.testing.expectEqual(schema.UnknownFlags.as_value, child.unknown_flags);
    try std.testing.expectEqual(@as(schema.FlagId, 1), child.names[0].target.flag);
    try std.testing.expectEqual(@as(usize, 2), child.names.len - 2);
}

test "Compiled inherits the root version action into subcommands" {
    const Leaf = struct {};
    const Commands = union(enum) { child: Leaf };
    const Root = struct {
        command: Commands,

        pub const meta: schema.Meta(@This()) = .{ .version = "1.0.0" };
    };

    const compiled = Compiled(Root);
    var child_has_version = false;
    for (compiled.table.scopes[1].names) |name| {
        switch (name.target) {
            .action => |action| child_has_version = child_has_version or action == .version,
            .flag => {},
        }
    }
    try std.testing.expect(child_has_version);
}

test "Compiled detects colliding command aliases at comptime" {
    const Payload = struct {};
    const Commands = union(enum) {
        first: Payload,
        second: Payload,
        pub const meta: schema.VariantsMeta(@This()) = .{ .variants = .{
            .first = .{ .aliases = &.{"shared"} },
            .second = .{ .aliases = &.{"shared"} },
        } };
    };

    comptime try std.testing.expect(variantsHaveCollision(Commands));
}
