//! Parse flags and a required positional argument.

const std = @import("std");
const zlap = @import("zlap");

const App = struct {
    jobs: u16 = 1,
    verbose: bool = false,
    input: []const u8,

    pub const meta: zlap.Meta(@This()) = .{
        .bin = "basic",
        .version = "0.1.0",
        .about = "Process one input file.",
        .fields = .{
            .jobs = .{
                .short = 'j',
                .help = "Number of jobs to use.",
                .value_name = "COUNT",
                .env = "ZLAP_JOBS",
            },
            .verbose = .{
                .short = 'v',
                .help = "Print processing details.",
            },
            .input = .{
                .positional = true,
                .help = "Input file to process.",
            },
        },
    };
};

pub fn main(init: std.process.Init) !void {
    const app = zlap.parse(App, init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    try stdout.interface.print(
        "Processing {s} with {d} job(s). Verbose output: {}\n",
        .{ app.input, app.jobs, app.verbose },
    );
}
