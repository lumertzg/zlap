//! Process entry point for parsing command line arguments.

const std = @import("std");
const bind = @import("bind.zig");
const completion = @import("completion.zig");
const render = @import("render.zig");
const schema = @import("schema.zig");

/// The result of handling a parse without terminating the process.
pub fn HandleResult(comptime T: type) type {
    return union(enum) {
        value: T,
        exit: u8,
    };
}

/// Parses the current process arguments and exits after rendering a parse action or error.
///
/// List storage and any Windows or WASI argument conversion use the process arena.
pub fn parse(comptime T: type, init: std.process.Init) T {
    const allocator = init.arena.allocator();
    const words = init.minimal.args.toSlice(allocator) catch {
        writeOutOfMemory(init.io);
        std.process.exit(2);
    };
    const argv = argvFromWords(words);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);

    if (handleCompletion(T, argv, &stdout.interface, &stderr.interface) catch {
        stdout.interface.flush() catch {};
        stderr.interface.flush() catch {};
        std.process.exit(2);
    }) |status| {
        stdout.interface.flush() catch {};
        stderr.interface.flush() catch {};
        std.process.exit(status);
    }

    var diagnostic: schema.Diagnostic = .{};
    const result = bind.parseFrom(T, allocator, argv, .{
        .env = .{ .map = init.environ_map },
        .diagnostic = &diagnostic,
    });

    const handled = handleResult(
        T,
        result,
        diagnostic,
        &stdout.interface,
        &stderr.interface,
    ) catch {
        stdout.interface.flush() catch {};
        stderr.interface.flush() catch {};
        std.process.exit(2);
    };
    switch (handled) {
        .value => |value| return value,
        .exit => |status| {
            stdout.interface.flush() catch {};
            stderr.interface.flush() catch {};
            std.process.exit(status);
        },
    }
}

/// Handles a completion-enabled root's hidden shell-completion request and returns its exit status.
///
/// A null result means argv belongs to the regular parser.
pub fn handleCompletion(
    comptime T: type,
    argv: schema.Argv,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!?u8 {
    if (!completionEnabled(T)) return null;
    if (argv.len() == 0 or !std.mem.eql(u8, argv.get(0), "__complete")) return null;

    const request = completionRequest(argv) orelse {
        try writeInvalidCompletionRequest(stderr);
        return 2;
    };

    completion.complete(T, request.line, request.cursor, request.shell, stdout) catch |err| {
        switch (err) {
            error.CursorOutOfBounds, error.LineTooLong, error.TooManyWords => {
                try writeInvalidCompletionRequest(stderr);
                return 2;
            },
            error.WriteFailed => return error.WriteFailed,
        }
    };
    return 0;
}

fn completionEnabled(comptime T: type) bool {
    if (@hasDecl(T, "meta")) return T.meta.completion;
    return false;
}

const CompletionRequest = struct {
    shell: completion.Shell,
    line: []const u8,
    cursor: usize,
};

fn completionRequest(argv: schema.Argv) ?CompletionRequest {
    if (argv.len() != 7) return null;
    if (!std.mem.eql(u8, argv.get(1), "--shell")) return null;
    if (!std.mem.eql(u8, argv.get(3), "--line")) return null;
    if (!std.mem.eql(u8, argv.get(5), "--cursor")) return null;

    return .{
        .shell = parseShell(argv.get(2)) orelse return null,
        .line = argv.get(4),
        .cursor = parseCursor(argv.get(6)) orelse return null,
    };
}

fn parseShell(value: []const u8) ?completion.Shell {
    if (std.mem.eql(u8, value, "bash")) return .bash;
    if (std.mem.eql(u8, value, "zsh")) return .zsh;
    if (std.mem.eql(u8, value, "fish")) return .fish;
    if (std.mem.eql(u8, value, "powershell")) return .powershell;
    if (std.mem.eql(u8, value, "nu")) return .nu;
    return null;
}

fn parseCursor(value: []const u8) ?usize {
    if (value.len == 0) return null;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn writeInvalidCompletionRequest(stderr: *std.Io.Writer) std.Io.Writer.Error!void {
    try stderr.writeAll("error: invalid completion request\n");
}

/// Renders a parse result and returns either the value or the intended exit status.
pub fn handleResult(
    comptime T: type,
    result: schema.Error!T,
    diagnostic: schema.Diagnostic,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!HandleResult(T) {
    if (result) |value| return .{ .value = value } else |err| {
        switch (err) {
            error.HelpRequested => {
                try render.writeHelp(T, diagnostic.command, stdout, .{});
                return .{ .exit = 0 };
            },
            error.VersionRequested => {
                try render.writeVersion(T, stdout);
                return .{ .exit = 0 };
            },
            error.ParseFailed => {
                try render.renderDiagnostic(T, diagnostic, stderr, .{});
                return .{ .exit = 2 };
            },
            error.OutOfMemory => {
                try stderr.writeAll("error: out of memory\n");
                return .{ .exit = 2 };
            },
        }
    }
}

fn argvFromWords(words: []const [:0]const u8) schema.Argv {
    if (words.len == 0) return .{};
    return .{
        .program = words[0],
        .values = words[1..],
    };
}

fn writeOutOfMemory(io: std.Io) void {
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    defer stderr.interface.flush() catch {};
    stderr.interface.writeAll("error: out of memory\n") catch {};
}

test "handleResult returns parsed value" {
    const Command = struct { verbose: bool = false };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const result = try handleResult(
        Command,
        Command{ .verbose = true },
        .{},
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expectEqual(true, result.value.verbose);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}

test "handleResult writes help to stdout" {
    const Command = struct {
        verbose: bool = false,

        pub const meta: schema.Meta(@This()) = .{
            .bin = "example",
        };
    };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const result = try handleResult(
        Command,
        error.HelpRequested,
        .{ .kind = .help },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit);
    try std.testing.expectEqualStrings(
        "Usage: example [OPTIONS]\n\nOptions:\n      --verbose\n",
        stdout.written(),
    );
    try std.testing.expectEqualStrings("", stderr.written());
}

test "handleResult writes diagnostics to stderr" {
    const Command = struct { verbose: bool = false };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const result = try handleResult(
        Command,
        error.ParseFailed,
        .{ .kind = .unknown_flag, .token = "--unknown" },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 2), result.exit);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings(
        "error: unknown flag '--unknown'\n\nFor more information, try '--help'.\n",
        stderr.written(),
    );
}

test "handleCompletion leaves __complete to disabled roots" {
    const Command = struct {
        value: []const u8,

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .value = .{ .positional = true },
        } };
    };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(?u8, null), try handleCompletion(
        Command,
        .{ .values = &.{"__complete"} },
        &stdout.writer,
        &stderr.writer,
    ));
    const value = try bind.parseFrom(
        Command,
        std.testing.allocator,
        .{ .values = &.{"__complete"} },
        .{},
    );
    try std.testing.expectEqualStrings("__complete", value.value);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}

test "handleCompletion writes hidden completion candidates to stdout" {
    const Command = struct {
        verbose: bool = false,

        pub const meta: schema.Meta(@This()) = .{ .completion = true };
    };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = (try handleCompletion(
        Command,
        .{ .values = &.{
            "__complete", "--shell", "bash", "--line", "example --v", "--cursor", "11",
        } },
        &stdout.writer,
        &stderr.writer,
    )).?;
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualStrings("--verbose\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}

test "handleCompletion rejects malformed hidden requests" {
    const Command = struct {
        verbose: bool = false,

        pub const meta: schema.Meta(@This()) = .{ .completion = true };
    };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = (try handleCompletion(
        Command,
        .{ .values = &.{ "__complete", "--shell", "invalid" } },
        &stdout.writer,
        &stderr.writer,
    )).?;
    try std.testing.expectEqual(@as(u8, 2), status);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("error: invalid completion request\n", stderr.written());
}

test "handleCompletion leaves regular parse arguments alone" {
    const Command = struct { verbose: bool = false };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(?u8, null), try handleCompletion(
        Command,
        .{ .values = &.{"--verbose"} },
        &stdout.writer,
        &stderr.writer,
    ));
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}
