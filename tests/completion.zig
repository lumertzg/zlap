//! Executable fixture exercised through each shell's completion adapter.

const std = @import("std");
const zlap = @import("zlap");

const Format = enum { json, plain, @"two words", @"star*value", @"it's", @"x:y", @"ümlaut" };
const Run = struct {
    format: Format = .plain,
    mode: ?Format = null,

    pub const meta: zlap.Meta(@This()) = .{ .fields = .{
        .format = .{ .short = 'f' },
        .mode = .{ .positional = true },
    } };
};
const Commands = union(enum) { run: Run };
const App = struct {
    output: []const u8 = "",
    format: Format = .plain,
    mode: ?Format = null,
    command: ?Commands = null,

    pub const meta: zlap.Meta(@This()) = .{
        .bin = "zlap-fixture",
        .completion = true,
        .fields = .{
            .format = .{ .short = 'f' },
            .mode = .{ .positional = true },
        },
    };
};

fn Named(comptime name: []const u8) type {
    return struct {
        pub const meta: zlap.Meta(@This()) = .{ .bin = name };
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 3 and std.mem.eql(u8, args[1], "script")) {
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        defer stdout.interface.flush() catch {};

        inline for (comptime @typeInfo(zlap.Shell).@"enum".field_names) |name| {
            if (std.mem.eql(u8, args[2], name)) {
                const shell = @field(zlap.Shell, name);
                const script = if (args.len == 4 and std.mem.eql(u8, args[3], "quoted"))
                    zlap.completionScript(Named("zlap'fixture"), shell)
                else if (args.len == 4 and std.mem.eql(u8, args[3], "double-quoted"))
                    zlap.completionScript(Named("zlap\"fixture"), shell)
                else if (args.len == 4)
                    zlap.completionScript(Named("zlap-other"), shell)
                else
                    zlap.completionScript(App, shell);
                try stdout.interface.writeAll(script);
                return;
            }
        }

        return error.UnknownShell;
    }

    _ = zlap.parse(App, init);
}
