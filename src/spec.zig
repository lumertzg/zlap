//! Comptime JSON descriptions of compiled command declarations.

const std = @import("std");
const compile = @import("compile.zig");
const declaration = @import("declaration.zig");
const schema = @import("schema.zig");

/// Returns a JSON description of command nodes, flags, positionals, and subcommands.
pub fn spec(comptime T: type) []const u8 {
    _ = compile.Compiled(T);
    return generatedSpec(T);
}

fn generatedSpec(comptime T: type) []const u8 {
    const length = specLength(T);
    const output = comptime blk: {
        var buffer: [length]u8 = undefined;
        var writer: JsonWriter = .{ .buffer = &buffer };
        writeSpec(T, &writer);
        std.debug.assert(writer.index == buffer.len);
        break :blk buffer;
    };
    return &output;
}

fn specLength(comptime T: type) usize {
    var writer: JsonWriter = .{};
    writeSpec(T, &writer);
    return writer.index;
}

const JsonWriter = struct {
    buffer: ?[]u8 = null,
    index: usize = 0,

    fn write(self: *JsonWriter, text: []const u8) void {
        if (self.buffer) |buffer| {
            @memcpy(buffer[self.index..][0..text.len], text);
        }
        self.index += text.len;
    }

    fn byte(self: *JsonWriter, value: u8) void {
        if (self.buffer) |buffer| buffer[self.index] = value;
        self.index += 1;
    }

    fn number(self: *JsonWriter, value: usize) void {
        var digits: [std.fmt.count("{}", .{std.math.maxInt(usize)})]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{}", .{value}) catch unreachable;
        self.write(text);
    }

    fn string(self: *JsonWriter, value: []const u8) void {
        self.byte('"');
        for (value) |byte_value| switch (byte_value) {
            '"' => self.write("\\\""),
            '\\' => self.write("\\\\"),
            '\x08' => self.write("\\b"),
            '\x0c' => self.write("\\f"),
            '\n' => self.write("\\n"),
            '\r' => self.write("\\r"),
            '\t' => self.write("\\t"),
            else => if (byte_value < 0x20) {
                self.write("\\u00");
                self.byte(hex(byte_value >> 4));
                self.byte(hex(byte_value & 0x0f));
            } else self.byte(byte_value),
        };
        self.byte('"');
    }
};

fn hex(value: u8) u8 {
    std.debug.assert(value < 16);
    return if (value < 10) '0' + value else 'a' + value - 10;
}

fn writeSpec(comptime T: type, writer: *JsonWriter) void {
    const compiled = compile.Compiled(T);
    writer.write("{\"commands\":[");
    var node_count: usize = 0;
    var next_binding: schema.FlagId = 0;
    writeCommand(T, T, 0, &node_count, &next_binding, writer);
    std.debug.assert(next_binding == compiled.bindings.len);
    writer.write("]}");
}

fn writeCommand(
    comptime Root: type,
    comptime Current: type,
    node_id: schema.CmdId,
    node_count: *usize,
    next_binding: *schema.FlagId,
    writer: *JsonWriter,
) void {
    const compiled = compile.Compiled(Root);
    std.debug.assert(node_id < compiled.nodes.len);
    const command_index = node_count.*;
    node_count.* += 1;

    if (command_index != 0) writer.byte(',');
    writer.write("{\"id\":");
    writer.number(node_id);
    writer.write(",\"name\":");
    writer.string(compiled.nodes[node_id].name);
    writer.write(",\"parent\":");
    if (compiled.nodes[node_id].parent) |parent| writer.number(parent) else writer.write("null");
    writer.write(",\"about\":");
    writer.string(commandMeta(Current).about);
    writer.write(",\"default_subcommand\":");
    writeDefaultSubcommand(Current, writer);
    writer.write(",\"external_subcommand\":");
    writer.write(if (commandMeta(Current).external_subcommand) "true" else "false");
    const binding_start = next_binding.*;
    next_binding.* += bindingCount(Current);
    writer.write(",\"flags\":[");
    writeBindings(Root, Current, node_id, binding_start, false, writer);
    writer.write("],\"positionals\":[");
    writeBindings(Root, Current, node_id, binding_start, true, writer);
    writer.write("],\"subcommands\":[");
    writeSubcommands(Root, Current, node_id, writer);
    writer.write("]}");

    if (commandField(Current)) |field| {
        const Union = commandUnion(field.type) orelse unreachable;
        inline for (unionFields(Union)) |variant| {
            if (isExternalVariant(variant)) continue;
            writeCommand(
                Root,
                variant.type,
                nodeId(Root, node_id, variant.name),
                node_count,
                next_binding,
                writer,
            );
        }
    }
}

fn writeBindings(
    comptime Root: type,
    comptime Current: type,
    node_id: schema.CmdId,
    binding_start: schema.FlagId,
    comptime positional: bool,
    writer: *JsonWriter,
) void {
    const compiled = compile.Compiled(Root);
    const meta = commandMeta(Current);
    var first = true;
    var binding_id = binding_start;
    inline for (structFields(Current)) |field| {
        if (isCommandField(field.type)) continue;
        const options = @field(meta.fields, field.name);
        if (options.positional == positional) {
            std.debug.assert(compiled.bindings[binding_id].command == node_id);
            if (options.one_of_flags) {
                inline for (@typeInfo(field.type).@"enum".fields) |tag| {
                    writeBinding(
                        Root,
                        binding_id,
                        field,
                        options,
                        kebabCase(tag.name),
                        false,
                        &first,
                        writer,
                    );
                }
            } else {
                writeBinding(
                    Root,
                    binding_id,
                    field,
                    options,
                    options.long orelse kebabCase(field.name),
                    positional,
                    &first,
                    writer,
                );
            }
        }
        binding_id += 1;
    }
}

fn writeBinding(
    comptime Root: type,
    binding_id: schema.FlagId,
    comptime field: std.builtin.Type.StructField,
    comptime options: anytype,
    comptime name: []const u8,
    comptime positional: bool,
    first: *bool,
    writer: *JsonWriter,
) void {
    const compiled = compile.Compiled(Root);
    if (!first.*) writer.byte(',');
    first.* = false;
    writer.write("{\"id\":");
    writer.number(binding_id);
    writer.write(",\"field\":");
    writer.string(field.name);
    writer.write(",\"kind\":");
    writer.string(@tagName(compiled.table.flags[binding_id].kind));
    if (options.one_of_flags) {
        writer.write(",\"takes_value\":false");
        writer.write(",\"value\":");
        writer.string(name);
    }
    writer.write(",\"help\":");
    writer.string(options.long_help orelse options.help);
    writer.write(",\"hidden\":");
    writer.write(if (options.hide) "true" else "false");
    if (positional) {
        writer.write(",\"name\":");
        writer.string(options.value_name orelse field.name);
    } else {
        writer.write(",\"long\":");
        writer.string(name);
        writer.write(",\"short\":");
        if (options.one_of_flags) {
            writer.write("null");
        } else if (options.short) |short| {
            writer.string(&.{short});
        } else writer.write("null");
        writer.write(",\"aliases\":[");
        if (!options.one_of_flags) writeStrings(options.aliases, writer);
        writer.write("]");
        writer.write(",\"negate\":");
        if (!options.one_of_flags) {
            if (options.negate) |negate| writer.string(negate) else writer.write("null");
        } else writer.write("null");
        writer.write(",\"value_name\":");
        if (takesValue(field.type, options)) {
            if (options.value_name) |value_name| {
                writer.string(value_name);
            } else writer.write("null");
        } else writer.write("null");
        writer.write(",\"global\":");
        writer.write(if (options.global) "true" else "false");
    }
    writer.byte('}');
}

fn bindingCount(comptime T: type) schema.FlagId {
    var count: schema.FlagId = 0;
    inline for (structFields(T)) |field| {
        if (!isCommandField(field.type)) count += 1;
    }
    return count;
}

fn writeSubcommands(
    comptime Root: type,
    comptime Current: type,
    node_id: schema.CmdId,
    writer: *JsonWriter,
) void {
    const field = commandField(Current) orelse return;
    const Union = commandUnion(field.type) orelse unreachable;
    const meta = variantsMeta(Union);
    var first = true;
    inline for (unionFields(Union)) |variant| {
        if (isExternalVariant(variant)) continue;
        if (!first) writer.byte(',');
        first = false;
        const options = @field(meta.variants, variant.name);
        writer.write("{\"id\":");
        writer.number(nodeId(Root, node_id, variant.name));
        writer.write(",\"name\":");
        writer.string(options.name orelse kebabCase(variant.name));
        writer.write(",\"aliases\":[");
        writeStrings(options.aliases, writer);
        writer.write("],\"help\":");
        writer.string(options.help);
        writer.write(",\"hidden\":");
        writer.write(if (options.hide) "true" else "false");
        writer.byte('}');
    }
}

fn writeDefaultSubcommand(comptime T: type, writer: *JsonWriter) void {
    const command = commandField(T) orelse {
        writer.write("null");
        return;
    };
    const default_variant = commandMeta(T).default_subcommand orelse {
        writer.write("null");
        return;
    };
    const meta = variantsMeta(commandUnion(command.type) orelse unreachable);
    const name = @tagName(default_variant);
    writer.string(@field(meta.variants, name).name orelse kebabCase(name));
}

fn nodeId(
    comptime Root: type,
    parent: schema.CmdId,
    comptime variant: []const u8,
) schema.CmdId {
    inline for (compile.Compiled(Root).nodes, 0..) |node, index| {
        if (node.parent == parent and std.mem.eql(u8, node.variant.?, variant)) {
            return @intCast(index);
        }
    }
    unreachable;
}

fn writeStrings(comptime strings: []const []const u8, writer: *JsonWriter) void {
    inline for (strings, 0..) |value, index| {
        if (index != 0) writer.byte(',');
        writer.string(value);
    }
}

const commandMeta = declaration.commandMeta;
const variantsMeta = declaration.variantsMeta;
const structFields = declaration.structFields;
const unionFields = declaration.unionFields;
const commandField = declaration.commandField;
const isCommandField = declaration.isCommandField;

fn takesValue(comptime T: type, comptime options: anytype) bool {
    const Scalar = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    return !options.count and !options.one_of_flags and @typeInfo(Scalar) != .bool;
}

const commandUnion = declaration.commandUnion;
const kebabCase = declaration.kebabCase;

fn isExternalVariant(comptime field: std.builtin.Type.UnionField) bool {
    return field.type == schema.ExternalCommand;
}

test "spec emits metadata for commands, flags, and positionals" {
    const Run = struct {
        task: []const u8,
        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .task = .{ .positional = true, .value_name = "TASK", .help = "Task to run" },
        } };
    };
    const Commands = union(enum) {
        run_task: Run,
        pub const meta: schema.VariantsMeta(@This()) = .{ .variants = .{
            .run_task = .{ .name = "run", .aliases = &.{"r"}, .help = "Run a task" },
        } };
    };
    const Root = struct {
        dry_run: bool = false,
        output: []const u8 = "",
        command: Commands,
        pub const meta: schema.Meta(@This()) = .{
            .about = "A \"quoted\" tool",
            .fields = .{
                .dry_run = .{ .short = 'd', .negate = "no-dry-run", .help = "Dry run" },
                .output = .{ .long = "output", .aliases = &.{"out"}, .help = "Output" },
            },
        };
    };

    const result = comptime spec(Root);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"commands\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"run\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"long\":\"output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"TASK\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "A \\\"quoted\\\" tool") != null);
}

test "spec lists generated one-of switches and optional boolean switches" {
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
    const result = comptime spec(Command);
    for (compiled.table.scopes[0].names) |name| {
        const binding = switch (name.target) {
            .action => continue,
            .flag => |id| id,
        };
        if (binding > 1 or name.kind != .long) continue;

        var expected: [40]u8 = undefined;
        const field = try std.fmt.bufPrint(&expected, "\"long\":\"{s}\"", .{name.spelling});
        try std.testing.expect(std.mem.indexOf(u8, result, field) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, result, "\"long\":\"format\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"value_name\":\"FORMAT\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"value_name\":\"STATE\"") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, result, "\"takes_value\":false,\"value\":\"table\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, result, "\"takes_value\":false,\"value\":\"json\"") != null,
    );
}

test "spec describes default and external subcommands" {
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

    try std.testing.expect(std.mem.indexOf(
        u8,
        comptime spec(DefaultApp),
        "\"default_subcommand\":\"run\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        comptime spec(ExternalApp),
        "\"external_subcommand\":true",
    ) != null);
}
