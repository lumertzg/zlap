//! Response-file expansion before command parsing.

const std = @import("std");
const schema = @import("schema.zig");

pub const Options = struct {
    /// The greatest number of nested response files permitted below argv.
    max_depth: usize = 16,
    /// A response file larger than this is rejected before allocating its contents.
    max_file_bytes: usize = 1024 * 1024,
};

/// Owned argv storage returned by `expandResponseFiles`.
pub const ExpandedArgv = struct {
    allocator: std.mem.Allocator,
    argv: schema.Argv,

    /// Releases the expanded words and their backing slice.
    pub fn deinit(self: *ExpandedArgv) void {
        for (self.argv.values) |value| self.allocator.free(value);
        self.allocator.free(self.argv.values);
        self.* = undefined;
    }
};

/// Replaces `@path` words with the recursively expanded words from `path`.
///
/// `@@word` produces the literal word `@word`. Paths resolve from the current working
/// directory. A file may appear more than once, but it cannot contain itself through a
/// recursive path. The returned argv owns copies of every word and must be deinitialized.
pub fn expandResponseFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: schema.Argv,
    options: Options,
) !ExpandedArgv {
    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    for (argv.values) |value| {
        try expandWord(allocator, io, &values, &paths, value, options, 0);
    }
    return .{
        .allocator = allocator,
        .argv = .{
            .program = argv.program,
            .values = try values.toOwnedSlice(allocator),
        },
    };
}

fn expandWord(
    allocator: std.mem.Allocator,
    io: std.Io,
    values: *std.ArrayList([]const u8),
    paths: *std.ArrayList([]const u8),
    word: []const u8,
    options: Options,
    depth: usize,
) !void {
    if (!std.mem.startsWith(u8, word, "@")) return appendWord(allocator, values, word);
    if (word.len > 1 and word[1] == '@') return appendWord(allocator, values, word[1..]);
    if (word.len == 1) return appendWord(allocator, values, word);
    if (depth >= options.max_depth) return error.ResponseFileDepthExceeded;

    const path = word[1..];
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(canonical[0 .. canonical.len + 1]);
    const resolved = try allocator.dupe(u8, canonical);
    for (paths.items) |active| {
        if (std.mem.eql(u8, active, resolved)) {
            allocator.free(resolved);
            return error.ResponseFileCycle;
        }
    }
    paths.append(allocator, resolved) catch |err| {
        allocator.free(resolved);
        return err;
    };
    defer {
        const active = paths.pop().?;
        std.debug.assert(std.mem.eql(u8, active, resolved));
        allocator.free(active);
    }

    const text = try readFile(allocator, io, path, options.max_file_bytes);
    defer allocator.free(text);

    var iterator = try std.process.Args.IteratorGeneral(.{
        .comments = true,
        .single_quotes = true,
    }).init(allocator, text);
    defer iterator.deinit();

    while (iterator.next()) |token| {
        try expandWord(allocator, io, values, paths, token, options, depth + 1);
    }
}

fn appendWord(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    word: []const u8,
) !void {
    const owned = try allocator.dupe(u8, word);
    errdefer allocator.free(owned);
    try values.append(allocator, owned);
}

fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_file_bytes: usize,
) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > max_file_bytes) return error.ResponseFileTooLarge;
    const size: usize = @intCast(stat.size);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const contents = try reader.interface.readAlloc(allocator, size);
    defer allocator.free(contents);

    const text = try allocator.alloc(u8, contents.len + 1);
    @memcpy(text[0..contents.len], contents);
    text[contents.len] = '\n';
    return text;
}

test "expandResponseFiles expands nested files and escapes at signs" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const outer_path = "/tmp/zlap-response-outer";
    const inner_path = "/tmp/zlap-response-inner";

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = inner_path, .data = "two \"three four\"" });
    defer std.Io.Dir.cwd().deleteFile(io, inner_path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = outer_path,
        .data = "one @/tmp/zlap-response-inner @@literal # ignored",
    });
    defer std.Io.Dir.cwd().deleteFile(io, outer_path) catch {};

    var expanded = try expandResponseFiles(allocator, io, .{
        .program = "zlap",
        .values = &.{ "@/tmp/zlap-response-outer", "tail" },
    }, .{});
    defer expanded.deinit();

    try std.testing.expectEqualStrings("zlap", expanded.argv.program);
    try std.testing.expectEqualStrings("one", expanded.argv.values[0]);
    try std.testing.expectEqualStrings("two", expanded.argv.values[1]);
    try std.testing.expectEqualStrings("three four", expanded.argv.values[2]);
    try std.testing.expectEqualStrings("@literal", expanded.argv.values[3]);
    try std.testing.expectEqualStrings("tail", expanded.argv.values[4]);
}

test "expandResponseFiles rejects cycles and excessive depth" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const first_path = "/tmp/zlap-response-first";
    const second_path = "/tmp/zlap-response-second";

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = first_path,
        .data = "@/tmp/zlap-response-second",
    });
    defer std.Io.Dir.cwd().deleteFile(io, first_path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = second_path,
        .data = "@/tmp/zlap-response-first",
    });
    defer std.Io.Dir.cwd().deleteFile(io, second_path) catch {};

    try std.testing.expectError(
        error.ResponseFileCycle,
        expandResponseFiles(allocator, io, .{ .values = &.{"@/tmp/zlap-response-first"} }, .{}),
    );
    try std.testing.expectError(
        error.ResponseFileDepthExceeded,
        expandResponseFiles(allocator, io, .{
            .values = &.{"@/tmp/zlap-response-first"},
        }, .{ .max_depth = 1 }),
    );
}
