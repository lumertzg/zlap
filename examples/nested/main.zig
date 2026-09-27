//! Select a nested command and dispatch its parsed values.

const std = @import("std");
const zlap = @import("zlap");

const Greet = struct {
    name: []const u8,
    excited: bool = false,

    pub const meta: zlap.Meta(@This()) = .{
        .about = "Greet one person.",
        .fields = .{
            .name = .{
                .positional = true,
                .help = "Person to greet.",
            },
            .excited = .{
                .short = 'e',
                .help = "Add an exclamation mark.",
            },
        },
    };
};

const Commands = union(enum) {
    greet: Greet,

    pub const meta: zlap.VariantsMeta(@This()) = .{
        .variants = .{
            .greet = .{
                .help = "Print a greeting.",
            },
        },
    };
};

const App = struct {
    verbose: bool = false,
    command: Commands,

    pub const meta: zlap.Meta(@This()) = .{
        .bin = "command",
        .version = "0.1.0",
        .about = "Greet someone through a nested command.",
        .fields = .{
            .verbose = .{
                .short = 'v',
                .global = true,
                .help = "Print the selected command.",
            },
        },
    };
};

pub fn main(init: std.process.Init) !void {
    const app = zlap.parse(App, init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    switch (app.command) {
        .greet => |greet| {
            if (app.verbose) try stdout.interface.writeAll("Selected command: greet\n");
            try stdout.interface.print(
                "Hello, {s}{s}\n",
                .{ greet.name, if (greet.excited) "!" else "." },
            );
        },
    }
}
