//! Plain-text rendering for compiled command declarations.

const std = @import("std");
const compile = @import("compile.zig");
const declaration = @import("declaration.zig");
const schema = @import("schema.zig");

/// Output controls reserved for terminal-aware rendering.
pub const Style = struct {
    color: bool = false,
    width: u16 = 80,
};

/// Writes the help page for one command in `T`'s command tree.
pub fn writeHelp(
    comptime T: type,
    command: schema.CmdId,
    writer: *std.Io.Writer,
    style: Style,
) std.Io.Writer.Error!void {
    const compiled = compile.Compiled(T);
    std.debug.assert(command < compiled.nodes.len);
    _ = style;

    try writeHelpForNode(T, T, command, writer, 0);
}

/// Writes the configured program name and version, when the declaration has a version.
pub fn writeVersion(comptime T: type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const meta = comptime commandMeta(T);
    if (meta.version) |version| {
        try writer.print("{s} {s}\n", .{ binName(T), version });
    }
}

/// Writes a plain-text explanation of a parsing or binding diagnostic.
pub fn renderDiagnostic(
    comptime T: type,
    diagnostic: schema.Diagnostic,
    writer: *std.Io.Writer,
    style: Style,
) std.Io.Writer.Error!void {
    const compiled = compile.Compiled(T);
    std.debug.assert(diagnostic.command < compiled.nodes.len);
    _ = style;

    try writer.writeAll("error: ");
    switch (diagnostic.kind) {
        .none => try writer.writeAll("unknown error"),
        .unknown_flag => try writer.print("unknown flag '{s}'", .{diagnostic.token}),
        .unknown_subcommand => try writer.print("unknown command '{s}'", .{diagnostic.token}),
        .missing_value => try writeBindingProblem(T, diagnostic, writer, "requires a value"),
        .unexpected_value => try writeUnexpectedValue(T, diagnostic, writer),
        .unexpected_positional => try writeUnexpectedPositional(diagnostic, writer),
        .invalid_value => try writeInvalidValue(T, diagnostic, writer),
        .missing_required => try writeMissingRequired(T, diagnostic, writer),
        .conflict => try writer.writeAll("conflicting options were provided"),
        .missing_requirement => try writer.writeAll("a required option is missing"),
        .missing_subcommand => try writer.writeAll("a subcommand is required"),
        .help => try writer.writeAll("help was requested"),
        .version => try writer.writeAll("version was requested"),
    }
    try writer.writeAll("\n\nFor more information, try '--help'.\n");
}

fn writeHelpForNode(
    comptime Root: type,
    comptime Current: type,
    command: schema.CmdId,
    writer: *std.Io.Writer,
    comptime current: schema.CmdId,
) std.Io.Writer.Error!void {
    const compiled = compile.Compiled(Root);
    if (command == current) {
        return writeCommandHelp(Root, Current, current, writer);
    }

    const command_field = commandField(Current) orelse unreachable;
    const Union = commandUnion(command_field.type) orelse unreachable;
    inline for (comptime unionFields(Union)) |field| {
        const child = comptime nodeId(Root, current, field.name) orelse unreachable;
        if (isDescendant(compiled.nodes, command, child)) {
            return writeHelpForNode(Root, field.type, command, writer, child);
        }
    }
    unreachable;
}

fn writeCommandHelp(
    comptime Root: type,
    comptime T: type,
    comptime command: schema.CmdId,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writeUsage(Root, T, command, writer);

    const meta = comptime commandMeta(T);
    const about = meta.long_about orelse meta.about;
    if (about.len > 0) try writer.print("\n{s}\n", .{about});

    try writePositionals(T, writer);
    try writeLocalOptions(T, writer);
    try writeGlobalOptions(Root, T, command, writer);
    try writeCommands(T, writer);
    if (meta.default_subcommand != null) {
        try writer.writeAll("\nUnrecognized commands are passed to the default subcommand.\n");
    }
    if (meta.external_subcommand) {
        try writer.writeAll(
            "\nUnrecognized commands and their remaining arguments are captured " ++
                "verbatim.\n",
        );
    }
    if (meta.after_help) |after_help| try writer.print("\n{s}\n", .{after_help});
}

fn writeUsage(
    comptime Root: type,
    comptime T: type,
    comptime command: schema.CmdId,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const compiled = compile.Compiled(Root);
    try writer.print("Usage: {s}", .{binName(Root)});
    for (compiled.nodes, 0..) |_, index| {
        const id: schema.CmdId = @intCast(index);
        if (id != 0 and isAncestor(compiled.nodes, id, command)) {
            try writer.print(" {s}", .{compiled.nodes[index].name});
        }
    }
    if (hasVisibleOptions(T)) try writer.writeAll(" [OPTIONS]");
    try writeUsagePositionals(T, writer);
    if (commandField(T)) |field| {
        const optional = @typeInfo(field.type) == .optional;
        if (hasVisibleCommands(T) or commandMeta(T).external_subcommand) {
            if (commandMeta(T).external_subcommand) {
                const usage = if (optional) " [COMMAND [ARGS]...]" else " <COMMAND> [ARGS]...";
                try writer.writeAll(usage);
            } else {
                const usage = if (optional) " [COMMAND]" else " <COMMAND>";
                try writer.writeAll(usage);
            }
        }
    }
    try writer.writeByte('\n');
}

fn writeUsagePositionals(comptime T: type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const meta = comptime commandMeta(T);
    inline for (comptime structFields(T)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const options = comptime @field(meta.fields, field.name);
        if (comptime !options.positional or options.hide) continue;
        const name = valueName(field.name, options);
        try writer.print(" <{s}>", .{name});
        if (isList(field.type)) try writer.writeAll("...");
    }
}

fn writePositionals(comptime T: type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const meta = comptime commandMeta(T);
    var any = false;
    inline for (comptime structFields(T)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const options = comptime @field(meta.fields, field.name);
        if (comptime options.positional and !options.hide) any = true;
    }
    if (!any) return;

    try writer.writeAll("\nArguments:\n");
    inline for (comptime structFields(T)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const options = comptime @field(meta.fields, field.name);
        if (comptime !options.positional or options.hide) continue;
        try writePositionalRow(field.name, field.type, options, writer);
    }
}

fn writeLocalOptions(comptime T: type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (!hasVisibleOptions(T)) return;

    const meta = comptime commandMeta(T);
    try writer.writeAll("\nOptions:\n");
    inline for (comptime structFields(T)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const options = comptime @field(meta.fields, field.name);
        if (comptime options.positional or options.hide) continue;
        try writeOptionRow(field.name, field.type, options, writer);
    }
}

fn writeGlobalOptions(
    comptime Root: type,
    comptime Current: type,
    comptime command: schema.CmdId,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    if (command == 0) return;
    if (!hasVisibleInheritedGlobals(Root, command)) return;

    try writer.writeAll("\nGlobal options:\n");
    try writeAncestorGlobals(Root, Root, Current, command, writer, 0);
}

fn writeAncestorGlobals(
    comptime Root: type,
    comptime Ancestor: type,
    comptime Current: type,
    comptime command: schema.CmdId,
    writer: *std.Io.Writer,
    comptime current: schema.CmdId,
) std.Io.Writer.Error!void {
    if (command == current) return;

    const command_field = commandField(Ancestor) orelse unreachable;
    const Union = commandUnion(command_field.type) orelse unreachable;
    inline for (comptime unionFields(Union)) |field| {
        const child = comptime nodeId(Root, current, field.name) orelse unreachable;
        if (isDescendant(compile.Compiled(Root).nodes, command, child)) {
            try writeOwnGlobals(Root, Ancestor, command, current, writer);
            return writeAncestorGlobals(Root, field.type, Current, command, writer, child);
        }
    }
    unreachable;
}

fn writeOwnGlobals(
    comptime Root: type,
    comptime Owner: type,
    comptime command: schema.CmdId,
    comptime current: schema.CmdId,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const meta = comptime commandMeta(Owner);
    inline for (comptime structFields(Owner)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const options = comptime @field(meta.fields, field.name);
        if (comptime !options.global or options.positional or options.hide) continue;
        const binding = comptime bindingId(Root, current, field.name);
        if (comptime !globalBindingIsVisible(Root, binding, command)) continue;
        try writeOptionRow(field.name, field.type, options, writer);
    }
}

fn writeCommands(comptime T: type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const command_field = commandField(T) orelse return;
    const Union = commandUnion(command_field.type) orelse unreachable;
    const meta = comptime variantsMeta(Union);
    var any = false;
    inline for (comptime unionFields(Union)) |field| {
        if (comptime isExternalVariant(field)) continue;
        if (!@field(meta.variants, field.name).hide) any = true;
    }
    if (!any) return;

    try writer.writeAll("\nCommands:\n");
    inline for (comptime unionFields(Union)) |field| {
        if (comptime isExternalVariant(field)) continue;
        const options = comptime @field(meta.variants, field.name);
        if (comptime options.hide) continue;
        const name = options.name orelse kebabCase(field.name);
        try writer.print("  {s}", .{name});
        if (options.aliases.len > 0) {
            try writer.writeAll(" (");
            for (options.aliases, 0..) |alias, index| {
                if (index != 0) try writer.writeAll(", ");
                try writer.writeAll(alias);
            }
            try writer.writeByte(')');
        }
        if (options.help.len > 0) try writer.print("\t{s}", .{options.help});
        try writer.writeByte('\n');
    }
}

fn writeOptionRow(
    comptime field_name: []const u8,
    comptime Field: type,
    comptime options: anytype,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    if (options.one_of_flags) {
        inline for (@typeInfo(Field).@"enum".fields) |tag| {
            try writer.writeAll("      ");
            try writer.print("--{s}", .{kebabCase(tag.name)});
            const help = options.long_help orelse options.help;
            if (help.len > 0) try writer.print("\t{s}", .{help});
            if (options.env) |env| try writer.print(" [env: {s}]", .{env});
            try writer.writeByte('\n');
        }
        return;
    }
    if (options.short) |short| {
        try writer.print("  -{c}, ", .{short});
    } else {
        try writer.writeAll("      ");
    }
    try writer.print("--{s}", .{options.long orelse kebabCase(field_name)});
    if (takesValue(Field, options)) try writer.print(" <{s}>", .{valueName(field_name, options)});
    const help = options.long_help orelse options.help;
    if (help.len > 0) try writer.print("\t{s}", .{help});
    if (options.env) |env| try writer.print(" [env: {s}]", .{env});
    try writer.writeByte('\n');
}

fn writePositionalRow(
    comptime field_name: []const u8,
    comptime Field: type,
    comptime options: anytype,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("  <{s}>", .{valueName(field_name, options)});
    if (isList(Field)) try writer.writeAll("...");
    if (options.help.len > 0) try writer.print("\t{s}", .{options.help});
    try writer.writeByte('\n');
}

fn writeBindingProblem(
    comptime T: type,
    diagnostic: schema.Diagnostic,
    writer: *std.Io.Writer,
    comptime problem: []const u8,
) std.Io.Writer.Error!void {
    if (diagnostic.binding) |binding| {
        try writer.writeAll("option '");
        try writeBindingName(T, binding, writer);
        try writer.print("' {s}", .{problem});
        return;
    }
    try writer.writeAll(problem);
}

fn writeUnexpectedValue(
    comptime T: type,
    diagnostic: schema.Diagnostic,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writeBindingProblem(T, diagnostic, writer, "does not take a value");
}

fn writeUnexpectedPositional(
    diagnostic: schema.Diagnostic,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("unexpected argument '{s}'", .{diagnostic.token});
}

fn writeInvalidValue(
    comptime T: type,
    diagnostic: schema.Diagnostic,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.print("invalid value '{s}'", .{diagnostic.token});
    if (diagnostic.binding) |binding| {
        try writer.writeAll(" for '");
        try writeBindingName(T, binding, writer);
        try writer.writeByte('\'');
    }
    if (diagnostic.expected) |expected| try writer.print(": expected {s}", .{expected});
}

fn writeMissingRequired(
    comptime T: type,
    diagnostic: schema.Diagnostic,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.writeAll("required argument '");
    if (diagnostic.binding) |binding| {
        try writeBindingName(T, binding, writer);
    } else {
        try writer.writeAll("argument");
    }
    try writer.writeAll("' is missing");
}

fn writeBindingName(
    comptime T: type,
    binding: schema.FlagId,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const compiled = compile.Compiled(T);
    std.debug.assert(binding < compiled.bindings.len);
    try writeBindingNameForNode(T, T, binding, writer, 0);
}

fn writeBindingNameForNode(
    comptime Root: type,
    comptime Current: type,
    binding: schema.FlagId,
    writer: *std.Io.Writer,
    comptime current: schema.CmdId,
) std.Io.Writer.Error!void {
    const compiled = compile.Compiled(Root);
    const target = compiled.bindings[binding].command;
    if (target == current) {
        inline for (comptime structFields(Current)) |field| {
            if (comptime isCommandField(field.type)) continue;
            if (std.mem.eql(u8, compiled.bindings[binding].field, field.name)) {
                const options = comptime @field(commandMeta(Current).fields, field.name);
                if (options.positional) {
                    return writer.print("<{s}>", .{valueName(field.name, options)});
                }
                return writer.print("--{s}", .{options.long orelse kebabCase(field.name)});
            }
        }
        unreachable;
    }

    if (comptime commandField(Current)) |command_field| {
        const Union = comptime commandUnion(command_field.type) orelse unreachable;
        inline for (comptime unionFields(Union)) |field| {
            const child = comptime nodeId(Root, current, field.name) orelse unreachable;
            if (isDescendant(compiled.nodes, target, child)) {
                return writeBindingNameForNode(Root, field.type, binding, writer, child);
            }
        }
    }
    unreachable;
}

fn hasVisibleOptions(comptime T: type) bool {
    const meta = comptime commandMeta(T);
    inline for (comptime structFields(T)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const options = comptime @field(meta.fields, field.name);
        if (!options.positional and !options.hide) return true;
    }
    return false;
}

fn hasVisibleCommands(comptime T: type) bool {
    const command_field = commandField(T) orelse return false;
    const Union = commandUnion(command_field.type) orelse unreachable;
    const meta = comptime variantsMeta(Union);
    inline for (comptime unionFields(Union)) |field| {
        if (comptime isExternalVariant(field)) continue;
        if (!@field(meta.variants, field.name).hide) return true;
    }
    return false;
}

fn hasVisibleInheritedGlobals(comptime Root: type, comptime command: schema.CmdId) bool {
    const compiled = compile.Compiled(Root);
    inline for (compiled.bindings, 0..) |binding, index| {
        if (comptime !isAncestor(compiled.nodes, binding.command, command)) continue;
        if (comptime binding.command == command) continue;
        const id: schema.FlagId = @intCast(index);
        if (comptime !bindingIsGlobal(Root, id)) continue;
        if (comptime bindingIsHidden(Root, id)) continue;
        if (comptime globalBindingIsVisible(Root, id, command)) return true;
    }
    return false;
}

fn globalBindingIsVisible(
    comptime Root: type,
    comptime binding: schema.FlagId,
    comptime command: schema.CmdId,
) bool {
    const compiled = compile.Compiled(Root);
    const owner = compiled.bindings[binding].command;
    inline for (compiled.table.scopes[owner].names) |name| {
        const target = switch (name.target) {
            .action => continue,
            .flag => |id| id,
        };
        if (target != binding) continue;
        if (!scopeHasBindingName(compiled.table.scopes[command], name, binding)) return false;
    }
    return true;
}

fn scopeHasBindingName(
    scope: schema.Scope,
    expected: schema.Name,
    binding: schema.FlagId,
) bool {
    for (scope.names) |name| {
        if (name.kind != expected.kind) continue;
        if (!std.mem.eql(u8, name.spelling, expected.spelling)) continue;
        return switch (name.target) {
            .action => false,
            .flag => |id| id == binding,
        };
    }
    return false;
}

fn bindingIsGlobal(comptime T: type, binding: schema.FlagId) bool {
    return bindingIsGlobalForNode(T, T, binding, 0);
}

fn bindingIsHidden(comptime T: type, binding: schema.FlagId) bool {
    return bindingIsHiddenForNode(T, T, binding, 0);
}

fn bindingIsGlobalForNode(
    comptime Root: type,
    comptime Current: type,
    binding: schema.FlagId,
    comptime current: schema.CmdId,
) bool {
    const compiled = compile.Compiled(Root);
    const target = compiled.bindings[binding].command;
    if (target == current) {
        inline for (comptime structFields(Current)) |field| {
            if (std.mem.eql(u8, field.name, compiled.bindings[binding].field)) {
                return @field(commandMeta(Current).fields, field.name).global;
            }
        }
        unreachable;
    }

    const command_field = commandField(Current) orelse unreachable;
    const Union = commandUnion(command_field.type) orelse unreachable;
    inline for (comptime unionFields(Union)) |field| {
        const child = comptime nodeId(Root, current, field.name) orelse unreachable;
        if (isDescendant(compiled.nodes, target, child)) {
            return bindingIsGlobalForNode(Root, field.type, binding, child);
        }
    }
    unreachable;
}

fn bindingIsHiddenForNode(
    comptime Root: type,
    comptime Current: type,
    binding: schema.FlagId,
    comptime current: schema.CmdId,
) bool {
    const compiled = compile.Compiled(Root);
    const target = compiled.bindings[binding].command;
    if (target == current) {
        inline for (comptime structFields(Current)) |field| {
            if (std.mem.eql(u8, field.name, compiled.bindings[binding].field)) {
                return @field(commandMeta(Current).fields, field.name).hide;
            }
        }
        unreachable;
    }

    const command_field = commandField(Current) orelse unreachable;
    const Union = commandUnion(command_field.type) orelse unreachable;
    inline for (comptime unionFields(Union)) |field| {
        const child = comptime nodeId(Root, current, field.name) orelse unreachable;
        if (isDescendant(compiled.nodes, target, child)) {
            return bindingIsHiddenForNode(Root, field.type, binding, child);
        }
    }
    unreachable;
}

fn bindingId(
    comptime Root: type,
    comptime command: schema.CmdId,
    comptime field_name: []const u8,
) schema.FlagId {
    inline for (compile.Compiled(Root).bindings, 0..) |binding, index| {
        if (binding.command != command) continue;
        if (std.mem.eql(u8, binding.field, field_name)) return @intCast(index);
    }
    unreachable;
}

fn nodeId(
    comptime T: type,
    comptime parent: schema.CmdId,
    comptime variant: []const u8,
) ?schema.CmdId {
    inline for (comptime compile.Compiled(T).nodes, 0..) |node, index| {
        if (node.parent == parent and std.mem.eql(u8, node.variant.?, variant)) {
            return @intCast(index);
        }
    }
    return null;
}

fn isAncestor(nodes: []const compile.Node, ancestor: schema.CmdId, command: schema.CmdId) bool {
    var current = command;
    var remaining = nodes.len;
    while (remaining > 0) : (remaining -= 1) {
        if (current == ancestor) return true;
        current = nodes[current].parent orelse return false;
    }
    unreachable;
}

fn isDescendant(nodes: []const compile.Node, command: schema.CmdId, ancestor: schema.CmdId) bool {
    return isAncestor(nodes, ancestor, command);
}

const commandMeta = declaration.commandMeta;
const variantsMeta = declaration.variantsMeta;
const structFields = declaration.structFields;
const unionFields = declaration.unionFields;
const commandField = declaration.commandField;
const isCommandField = declaration.isCommandField;
const commandUnion = declaration.commandUnion;

fn takesValue(comptime T: type, comptime options: anytype) bool {
    const Scalar = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    return !options.count and @typeInfo(Scalar) != .bool;
}

fn isList(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and pointer.child != u8,
        else => false,
    };
}

fn valueName(comptime field_name: []const u8, comptime options: anytype) []const u8 {
    return options.value_name orelse kebabCase(field_name);
}

fn binName(comptime T: type) []const u8 {
    return commandMeta(T).bin orelse "program";
}

const kebabCase = declaration.kebabCase;

fn isExternalVariant(comptime field: std.builtin.Type.UnionField) bool {
    return field.type == schema.ExternalCommand;
}

test "writeHelp renders root and child commands" {
    const Run = struct {
        path: []const u8,
        pub const meta: schema.Meta(@This()) = .{ .about = "Run one task", .fields = .{
            .path = .{ .positional = true, .help = "Task path", .value_name = "PATH" },
        } };
    };
    const Commands = union(enum) {
        run_task: Run,
        pub const meta: schema.VariantsMeta(@This()) = .{ .variants = .{
            .run_task = .{ .name = "run", .aliases = &.{"r"}, .help = "Run a task" },
        } };
    };
    const App = struct {
        verbose: bool = false,
        command: ?Commands = null,
        pub const meta: schema.Meta(@This()) = .{
            .bin = "demo",
            .about = "A demonstration program",
            .fields = .{ .verbose = .{ .short = 'v', .global = true, .help = "Print more" } },
        };
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelp(App, 0, &output.writer, .{});
    try std.testing.expectEqualStrings(
        "Usage: demo [OPTIONS] [COMMAND]\n" ++
            "\nA demonstration program\n" ++
            "\nOptions:\n  -v, --verbose\tPrint more\n" ++
            "\nCommands:\n  run (r)\tRun a task\n",
        output.written(),
    );

    output.clearRetainingCapacity();
    try writeHelp(App, 1, &output.writer, .{});
    try std.testing.expectEqualStrings(
        "Usage: demo run <PATH>\n" ++
            "\nRun one task\n" ++
            "\nArguments:\n  <PATH>\tTask path\n" ++
            "\nGlobal options:\n  -v, --verbose\tPrint more\n",
        output.written(),
    );
}

test "writeHelp retains globals when child fields are renamed" {
    const Child = struct {
        verbose: bool = false,
        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .verbose = .{ .long = "detail" },
        } };
    };
    const Commands = union(enum) { child: Child };
    const App = struct {
        verbose: bool = false,
        command: Commands,
        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .verbose = .{ .short = 'v', .global = true, .help = "Print more" },
        } };
    };

    const compiled = compile.Compiled(App);
    try std.testing.expectEqualStrings("verbose", compiled.table.scopes[1].names[1].spelling);
    try std.testing.expectEqualStrings("detail", compiled.table.scopes[1].names[0].spelling);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelp(App, 1, &output.writer, .{});
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "Global options:\n  -v, --verbose") != null,
    );
}

test "writeHelp renders one command slot for external forwarding" {
    const Run = struct {};
    const Commands = union(enum) {
        run: Run,
        external: schema.ExternalCommand,
    };
    const Required = struct {
        command: Commands,

        pub const meta: schema.Meta(@This()) = .{
            .bin = "required",
            .external_subcommand = true,
        };
    };
    const Optional = struct {
        command: ?Commands = null,

        pub const meta: schema.Meta(@This()) = .{
            .bin = "optional",
            .external_subcommand = true,
        };
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelp(Required, 0, &output.writer, .{});
    try std.testing.expectEqualStrings(
        "Usage: required <COMMAND> [ARGS]...\n" ++
            "\nCommands:\n  run\n" ++
            "\nUnrecognized commands and their remaining arguments are captured verbatim.\n",
        output.written(),
    );

    output.clearRetainingCapacity();
    try writeHelp(Optional, 0, &output.writer, .{});
    try std.testing.expectEqualStrings(
        "Usage: optional [COMMAND [ARGS]...]\n" ++
            "\nCommands:\n  run\n" ++
            "\nUnrecognized commands and their remaining arguments are captured verbatim.\n",
        output.written(),
    );
}

test "renderDiagnostic names the failed binding" {
    const App = struct {
        output: []const u8 = "",
        pub const meta: schema.Meta(@This()) = .{ .bin = "demo", .fields = .{
            .output = .{ .short = 'o', .help = "Output file" },
        } };
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostic(
        App,
        .{ .kind = .missing_value, .binding = 0, .token = "--output" },
        &output.writer,
        .{},
    );
    try std.testing.expectEqualStrings(
        "error: option '--output' requires a value\n\nFor more information, try '--help'.\n",
        output.written(),
    );
}

test "writeHelp renders generated one-of switches and optional boolean switches" {
    const Format = enum { table, json };
    const Command = struct {
        format: Format,
        enabled: ?bool = null,
        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .format = .{ .one_of_flags = true, .value_name = "FORMAT" },
            .enabled = .{ .value_name = "STATE" },
        } };
    };

    const compiled = compile.Compiled(Command);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelp(Command, 0, &output.writer, .{});

    for (compiled.table.scopes[0].names) |name| {
        const binding = switch (name.target) {
            .action => continue,
            .flag => |id| id,
        };
        if (binding > 1 or name.kind != .long) continue;

        var expected: [32]u8 = undefined;
        const flag = try std.fmt.bufPrint(&expected, "--{s}", .{name.spelling});
        try std.testing.expect(std.mem.indexOf(u8, output.written(), flag) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "--format") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "<FORMAT>") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "<STATE>") == null);
}

test "writeHelp describes default and external subcommands" {
    const Run = struct {};
    const Defaults = union(enum) { run: Run };
    const DefaultApp = struct {
        command: ?Defaults = null,
        pub const meta: schema.Meta(@This()) = .{ .default_subcommand = .run };
    };
    const External = union(enum) { external: schema.ExternalCommand };
    const ExternalApp = struct {
        command: External,
        pub const meta: schema.Meta(@This()) = .{ .external_subcommand = true };
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelp(DefaultApp, 0, &output.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "default subcommand") != null);

    output.clearRetainingCapacity();
    try writeHelp(ExternalApp, 0, &output.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "captured verbatim") != null);
}
