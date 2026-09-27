//! Shell completion for compiled zlap command declarations.

const std = @import("std");
const compile = @import("compile.zig");
const declaration = @import("declaration.zig");
const schema = @import("schema.zig");

/// Shell protocols supported by `completionScript` and `complete`.
pub const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,
    nu,
};

/// Completion rejects oversized input rather than allocating while a shell is waiting.
pub const max_line_bytes: usize = 4096;
pub const max_words: usize = 256;

pub const Error = std.Io.Writer.Error || error{
    CursorOutOfBounds,
    LineTooLong,
    TooManyWords,
};

/// Returns an installation script that calls the program's hidden `__complete` request.
pub fn completionScript(comptime T: type, comptime shell: Shell) []const u8 {
    const bin = comptime binName(T);
    return comptime switch (shell) {
        .bash => std.fmt.comptimePrint(
            \\_zlap_complete() {{
            \\    local IFS=$'\\n'
            \\    COMPREPLY=($("{s}" __complete --shell bash --line "$COMP_LINE" --cursor "$COMP_POINT"))
            \\}}
            \\complete -F _zlap_complete "{s}"
            \\
        , .{ bin, bin }),
        .zsh => std.fmt.comptimePrint(
            \\_zlap_complete() {{
            \\    local -a candidates
            \\    candidates=("${{(@f)$("{s}" __complete --shell zsh --line "$BUFFER" --cursor "$CURSOR")}}")
            \\    _describe 'values' candidates
            \\}}
            \\compdef _zlap_complete "{s}"
            \\
        , .{ bin, bin }),
        .fish => std.fmt.comptimePrint(
            \\complete -c "{s}" -f -a '({s} __complete --shell fish --line (commandline -cp) --cursor (commandline -C))'
            \\
        , .{ bin, bin }),
        .powershell => std.fmt.comptimePrint(
            \\Register-ArgumentCompleter -Native -CommandName '{s}' -ScriptBlock {{
            \\    param($wordToComplete, $commandAst, $cursorPosition)
            \\    & '{s}' __complete --shell powershell --line $commandAst.ToString() --cursor $cursorPosition |
            \\        ForEach-Object {{ [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }}
            \\}}
            \\
        , .{ bin, bin }),
        .nu => std.fmt.comptimePrint(
            \\def "nu-complete {s}" [context: string] {{
            \\    ^{s} __complete --shell nu --line $context --cursor ($context | str length)
            \\}}
            \\
        , .{ bin, bin }),
    };
}

/// Writes newline-delimited candidates for `line[0..cursor]`.
///
/// The first shell word is treated as the program name. The parser walks only complete
/// words before the cursor, so an unfinished word remains the candidate prefix.
pub fn complete(
    comptime T: type,
    line: []const u8,
    cursor: usize,
    shell: Shell,
    writer: *std.Io.Writer,
) Error!void {
    if (cursor > line.len) return error.CursorOutOfBounds;
    if (cursor > max_line_bytes) return error.LineTooLong;

    var storage: [max_line_bytes]u8 = undefined;
    var words: [max_words][]const u8 = undefined;
    const split = try splitLine(line[0..cursor], shell, &storage, &words);
    if (split.word_count == 0) return;

    const current = split.current;
    const previous_count = split.previous_count;
    if (previous_count == 0) return;

    const compiled = compile.Compiled(T);
    var diagnostic: schema.Diagnostic = .{};
    var parser = schema.Parser.init(
        &compiled.table,
        .{ .values = words[1..previous_count] },
        &diagnostic,
    );
    var pending_value: ?schema.FlagId = null;
    while (true) {
        _ = parser.next() catch |err| {
            if (err == error.ParseFailed and diagnostic.kind == .missing_value) {
                pending_value = diagnostic.binding;
            }
            break;
        } orelse break;
    }

    if (parser.external_selected) return;
    if (parser.flags_stopped) return;

    if (attachedValue(&compiled.table, parser.scope, current)) |attached| {
        if (try writeEnumValues(T, attached.id, attached.prefix, writer)) return;
    }
    if (pending_value) |binding| {
        if (try writeEnumValues(T, binding, current, writer)) return;
    }
    try writeScopeCandidates(
        &compiled.table,
        parser.scope,
        current,
        !parser.positional_started,
        writer,
    );
}

const Split = struct {
    word_count: usize,
    previous_count: usize,
    current: []const u8,
};

fn splitLine(
    line: []const u8,
    shell: Shell,
    storage: []u8,
    words: [][]const u8,
) Error!Split {
    if (line.len > storage.len) return error.LineTooLong;

    var quote: ?u8 = null;
    var in_word = false;
    var output_start: usize = 0;
    var output_index: usize = 0;
    var word_count: usize = 0;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (quote) |active_quote| {
            if (byte == active_quote) {
                quote = null;
                continue;
            }
            if (byte == escapeByte(shell) and active_quote != '\'') {
                if (index + 1 < line.len) {
                    index += 1;
                    try appendByte(storage, &output_index, line[index]);
                    continue;
                }
            }
            try appendByte(storage, &output_index, byte);
            continue;
        }

        if (isWhitespace(byte)) {
            if (in_word) {
                try appendWord(words, &word_count, storage[output_start..output_index]);
                in_word = false;
            }
            continue;
        }
        if (!in_word) {
            output_start = output_index;
            in_word = true;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == escapeByte(shell)) {
            if (index + 1 < line.len) {
                index += 1;
                try appendByte(storage, &output_index, line[index]);
                continue;
            }
        }
        try appendByte(storage, &output_index, byte);
    }

    if (in_word) {
        try appendWord(words, &word_count, storage[output_start..output_index]);
        return .{
            .word_count = word_count,
            .previous_count = word_count - 1,
            .current = words[word_count - 1],
        };
    }
    return .{ .word_count = word_count, .previous_count = word_count, .current = "" };
}

fn appendByte(storage: []u8, output_index: *usize, byte: u8) Error!void {
    if (output_index.* >= storage.len) return error.LineTooLong;
    storage[output_index.*] = byte;
    output_index.* += 1;
}

fn appendWord(words: [][]const u8, word_count: *usize, word: []const u8) Error!void {
    if (word_count.* >= words.len) return error.TooManyWords;
    words[word_count.*] = word;
    word_count.* += 1;
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn escapeByte(shell: Shell) u8 {
    return switch (shell) {
        .powershell => '`',
        .bash, .zsh, .fish, .nu => '\\',
    };
}

const AttachedValue = struct {
    id: schema.FlagId,
    prefix: []const u8,
};

fn attachedValue(
    table: *const schema.Table,
    command: schema.CmdId,
    current: []const u8,
) ?AttachedValue {
    std.debug.assert(command < table.scopes.len);
    if (std.mem.startsWith(u8, current, "--")) {
        const rest = current[2..];
        const equal_index = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
        const name = findName(
            table.scopes[command],
            .long,
            rest[0..equal_index],
        ) orelse return null;
        return switch (name.target) {
            .flag => |id| if (flagTakesValue(table.flags[id]) and !name.negated)
                .{ .id = id, .prefix = rest[equal_index + 1 ..] }
            else
                null,
            .action => null,
        };
    }
    if (current.len < 4 or current[0] != '-') return null;
    const equal_index = std.mem.indexOfScalar(u8, current, '=') orelse return null;
    if (equal_index != 2) return null;
    const name = findName(table.scopes[command], .short, current[1..2]) orelse return null;
    return switch (name.target) {
        .flag => |id| if (flagTakesValue(table.flags[id]) and !name.negated)
            .{ .id = id, .prefix = current[equal_index + 1 ..] }
        else
            null,
        .action => null,
    };
}

fn writeScopeCandidates(
    table: *const schema.Table,
    command: schema.CmdId,
    prefix: []const u8,
    include_commands: bool,
    writer: *std.Io.Writer,
) Error!void {
    std.debug.assert(command < table.scopes.len);
    const scope = table.scopes[command];
    if (std.mem.startsWith(u8, prefix, "-")) {
        for (scope.names) |name| {
            if (name.kind == .long) {
                if (startsWithDashed(prefix, "--", name.spelling)) {
                    try writer.print("--{s}\n", .{name.spelling});
                }
            } else if (startsWithDashed(prefix, "-", name.spelling)) {
                try writer.print("-{s}\n", .{name.spelling});
            }
        }
        return;
    }
    if (include_commands) {
        for (scope.commands) |child| {
            if (std.mem.startsWith(u8, child.spelling, prefix)) {
                try writer.print("{s}\n", .{child.spelling});
            }
        }
    }
    for (scope.names) |name| {
        if (name.kind == .long) {
            if (startsWithDashed(prefix, "--", name.spelling)) {
                try writer.print("--{s}\n", .{name.spelling});
            }
        } else if (startsWithDashed(prefix, "-", name.spelling)) {
            try writer.print("-{s}\n", .{name.spelling});
        }
    }
}

fn startsWithDashed(prefix: []const u8, comptime dash: []const u8, spelling: []const u8) bool {
    if (prefix.len <= dash.len) return std.mem.startsWith(u8, dash, prefix);
    if (!std.mem.startsWith(u8, prefix, dash)) return false;
    return std.mem.startsWith(u8, spelling, prefix[dash.len..]);
}

fn findName(scope: schema.Scope, kind: schema.Name.Kind, spelling: []const u8) ?*const schema.Name {
    for (scope.names) |*name| {
        if (name.kind == kind and std.mem.eql(u8, name.spelling, spelling)) return name;
    }
    return null;
}

fn flagTakesValue(flag: schema.Flag) bool {
    return switch (flag.kind) {
        .boolean, .count => false,
        .signed_integer, .unsigned_integer, .float, .enumeration, .string, .custom, .list => true,
    };
}

fn writeEnumValues(
    comptime T: type,
    binding: schema.FlagId,
    prefix: []const u8,
    writer: *std.Io.Writer,
) Error!bool {
    const compiled = compile.Compiled(T);
    std.debug.assert(binding < compiled.bindings.len);
    return writeEnumValuesForBinding(T, T, binding, prefix, writer, compiled.table.root);
}

fn writeEnumValuesForBinding(
    comptime Root: type,
    comptime Current: type,
    binding: schema.FlagId,
    prefix: []const u8,
    writer: *std.Io.Writer,
    comptime current: schema.CmdId,
) Error!bool {
    const compiled = compile.Compiled(Root);
    if (comptime compiled.bindings.len == 0) return false;
    const target = compiled.bindings[binding];
    if (target.command == current) {
        inline for (comptime structFields(Current)) |field| {
            if (std.mem.eql(u8, target.field, field.name)) {
                const Enum = enumType(field.type) orelse return false;
                inline for (@typeInfo(Enum).@"enum".fields) |item| {
                    if (kebabStartsWith(item.name, prefix)) {
                        try writeKebab(item.name, writer);
                        try writer.writeByte('\n');
                    }
                }
                return true;
            }
        }
        unreachable;
    }

    const command = commandField(Current) orelse return false;
    const Union = commandUnion(command.type) orelse unreachable;
    inline for (comptime unionFields(Union)) |variant| {
        const child = comptime nodeId(Root, current, variant.name);
        if (isDescendant(compiled.nodes, target.command, child)) {
            return writeEnumValuesForBinding(Root, variant.type, binding, prefix, writer, child);
        }
    }
    return false;
}

fn enumType(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"enum" => T,
        .optional => |optional| enumType(optional.child),
        .pointer => |pointer| if (pointer.size == .slice) switch (@typeInfo(pointer.child)) {
            .@"enum" => pointer.child,
            else => null,
        } else null,
        else => null,
    };
}

fn kebabStartsWith(name: []const u8, prefix: []const u8) bool {
    var prefix_index: usize = 0;
    for (name, 0..) |byte, index| {
        if (byte == '_') {
            if (prefix_index == prefix.len) return true;
            if (prefix[prefix_index] != '-') return false;
            prefix_index += 1;
            continue;
        }
        if (std.ascii.isUpper(byte) and index != 0 and name[index - 1] != '_') {
            if (prefix_index == prefix.len) return true;
            if (prefix[prefix_index] != '-') return false;
            prefix_index += 1;
        }
        if (prefix_index == prefix.len) return true;
        if (prefix[prefix_index] != std.ascii.toLower(byte)) return false;
        prefix_index += 1;
    }
    return prefix_index == prefix.len;
}

fn writeKebab(name: []const u8, writer: *std.Io.Writer) Error!void {
    for (name, 0..) |byte, index| {
        if (byte == '_') {
            try writer.writeByte('-');
            continue;
        }
        if (std.ascii.isUpper(byte) and index != 0 and name[index - 1] != '_') {
            try writer.writeByte('-');
        }
        try writer.writeByte(std.ascii.toLower(byte));
    }
}

const structFields = declaration.structFields;
const unionFields = declaration.unionFields;
const commandField = declaration.commandField;
const commandUnion = declaration.commandUnion;

fn nodeId(
    comptime T: type,
    comptime parent: schema.CmdId,
    comptime variant: []const u8,
) schema.CmdId {
    inline for (compile.Compiled(T).nodes, 0..) |node, index| {
        if (node.parent == parent and std.mem.eql(u8, node.variant.?, variant)) {
            return @intCast(index);
        }
    }
    unreachable;
}

fn isDescendant(nodes: []const compile.Node, command: schema.CmdId, ancestor: schema.CmdId) bool {
    var current = command;
    var remaining = nodes.len;
    while (remaining > 0) : (remaining -= 1) {
        if (current == ancestor) return true;
        current = nodes[current].parent orelse return false;
    }
    unreachable;
}

fn binName(comptime T: type) []const u8 {
    return declaration.commandMeta(T).bin orelse "program";
}

test "splitLine accepts shell quotes" {
    var storage: [max_line_bytes]u8 = undefined;
    var words: [max_words][]const u8 = undefined;
    const split = try splitLine("tool run --format 'json output", .bash, &storage, &words);

    try std.testing.expectEqual(@as(usize, 4), split.word_count);
    try std.testing.expectEqual(@as(usize, 3), split.previous_count);
    try std.testing.expectEqualStrings("json output", split.current);
}

test "complete suggests subcommands flags and enum values" {
    const Format = enum { json_output, plain };
    const Run = struct {
        format: Format = .plain,
        optional_format: ?Format = null,
        force: bool = false,
    };
    const Commands = union(enum) { run_task: Run };
    const Root = struct {
        verbose: bool = false,
        command: Commands,

        pub const meta: schema.Meta(@This()) = .{
            .bin = "tool",
            .fields = .{ .verbose = .{ .short = 'v' } },
        };
    };

    try expectCompletion(Root, "tool ru", "run-task\n");
    try expectCompletion(Root, "tool run-task --f", "--format\n--force\n");
    try expectCompletion(Root, "tool run-task --format j", "json-output\n");
    try expectCompletion(Root, "tool run-task --format=pl", "plain\n");
    try expectCompletion(Root, "tool run-task --optional-format j", "json-output\n");
}

test "complete respects parser state" {
    const Format = enum { json, plain };
    const Run = struct {
        format: Format = .plain,
    };
    const Commands = union(enum) { run: Run };
    const Root = struct {
        input: []const u8 = "",
        verbose: bool = false,
        command: Commands,

        pub const meta: schema.Meta(@This()) = .{
            .bin = "tool",
            .fields = .{ .input = .{ .positional = true } },
        };
    };

    try expectCompletion(Root, "tool -- ", "");
    try expectCompletion(Root, "tool input ", "--verbose\n--help\n-h\n");
    try expectCompletion(Root, "tool run ", "--format\n--help\n-h\n");
    try expectCompletion(Root, "tool run --format ", "json\nplain\n");
    try expectCompletion(Root, "tool run --format json ", "--format\n--help\n-h\n");
}

test "complete stops after an external subcommand" {
    const Run = struct {};
    const Commands = union(enum) {
        run: Run,
        external: schema.ExternalCommand,
    };
    const Root = struct {
        command: Commands,

        pub const meta: schema.Meta(@This()) = .{
            .bin = "tool",
            .external_subcommand = true,
        };
    };

    try expectCompletion(Root, "tool cargo ", "");
}

test "completion scripts invoke the hidden request" {
    const Command = struct {
        pub const meta: schema.Meta(@This()) = .{ .bin = "tool" };
    };
    inline for (comptime @typeInfo(Shell).@"enum".fields) |field| {
        const shell: Shell = comptime @enumFromInt(field.value);
        const script = completionScript(Command, shell);
        try std.testing.expect(std.mem.indexOf(u8, script, "__complete") != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "tool") != null);
    }
}

fn expectCompletion(comptime T: type, line: []const u8, expected: []const u8) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try complete(T, line, line.len, .bash, &output.writer);
    try std.testing.expectEqualStrings(expected, output.written());
}
