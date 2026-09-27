//! Test helpers for parsing command declarations and snapshotting help output.

const std = @import("std");
const bind = @import("bind.zig");
const compile = @import("compile.zig");
const render = @import("render.zig");
const schema = @import("schema.zig");

/// Parses `argv` and deeply compares the result with `expected`.
///
/// Values must be supported by `std.testing.expectEqualDeep`, including slices and
/// tagged unions. Self-referential pointer graphs are unsupported.
pub fn expectParse(comptime T: type, argv: schema.Argv, expected: T) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const actual = try bind.parseFrom(T, arena.allocator(), argv, .{});
    try std.testing.expectEqualDeep(expected, actual);
}

/// Expects parsing `argv` to produce `kind` and its corresponding parse error.
pub fn expectFailure(comptime T: type, argv: schema.Argv, kind: schema.Diagnostic.Kind) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        errorForDiagnostic(kind),
        bind.parseFrom(T, arena.allocator(), argv, .{ .diagnostic = &diagnostic }),
    );
    try std.testing.expectEqual(kind, diagnostic.kind);
}

/// Writes each command's help page in depth-first tree order.
pub fn writeHelpTree(comptime T: type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const compiled = compile.Compiled(T);
    const nodes = compiled.nodes;
    std.debug.assert(nodes.len > 0);

    var stack: [nodes.len]schema.CmdId = undefined;
    var stack_len: usize = 1;
    stack[0] = 0;

    while (stack_len > 0) {
        stack_len -= 1;
        const command = stack[stack_len];
        try render.writeHelp(T, command, writer, .{});

        var child_index = nodes.len;
        while (child_index > 0) {
            child_index -= 1;
            if (nodes[child_index].parent != command) continue;

            std.debug.assert(stack_len < stack.len);
            stack[stack_len] = @intCast(child_index);
            stack_len += 1;
        }
    }
}

fn errorForDiagnostic(kind: schema.Diagnostic.Kind) schema.Error {
    return switch (kind) {
        .help => error.HelpRequested,
        .version => error.VersionRequested,
        else => error.ParseFailed,
    };
}

test "expectParse deeply compares list values" {
    const Command = struct {
        values: []const u16 = &.{},
    };

    try expectParse(
        Command,
        .{ .values = &.{ "--values", "1", "--values", "2" } },
        .{ .values = &.{ 1, 2 } },
    );
}

test "expectParse deeply compares tagged union values" {
    const Run = struct {
        output: []const u8 = "",
    };
    const Commands = union(enum) {
        run: Run,
    };
    const App = struct {
        command: ?Commands = null,
    };

    try expectParse(
        App,
        .{ .values = &.{ "run", "--output", "log.txt" } },
        .{ .command = .{ .run = .{ .output = "log.txt" } } },
    );
}

test "expectFailure checks the diagnostic kind" {
    const Command = struct {
        verbose: bool = false,
    };

    try expectFailure(Command, .{ .values = &.{"--unknown"} }, .unknown_flag);
}

test "writeHelpTree writes pages depth first" {
    const Leaf = struct {};
    const Nested = union(enum) {
        inner: Leaf,
    };
    const First = struct {
        command: Nested,
    };
    const Commands = union(enum) {
        first: First,
        second: Leaf,
    };
    const App = struct {
        command: Commands,

        pub const meta: schema.Meta(@This()) = .{ .bin = "tool" };
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeHelpTree(App, &output.writer);

    const text = output.written();
    const root = std.mem.indexOf(u8, text, "Usage: tool <COMMAND>").?;
    const first = std.mem.indexOf(u8, text, "Usage: tool first <COMMAND>").?;
    const inner = std.mem.indexOf(u8, text, "Usage: tool first inner").?;
    const second = std.mem.indexOf(u8, text, "Usage: tool second").?;
    try std.testing.expect(root < first);
    try std.testing.expect(first < inner);
    try std.testing.expect(inner < second);
}
