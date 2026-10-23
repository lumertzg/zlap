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
    const bin = comptime quoteCommand(binName(T), shell);
    const function = comptime std.fmt.comptimePrint("_zlap_{x}", .{
        std.hash.Wyhash.hash(0, binName(T)),
    });

    return comptime switch (shell) {
        .bash => std.fmt.comptimePrint(
            \\{s}() {{
            \\    local candidate current="$2" quote='' byte escaped=0 i
            \\    local line="${{COMP_LINE:0:COMP_POINT}}"
            \\    current="${{current#\"}}"
            \\    current="${{current#\'}}"
            \\    current="${{current%\"}}"
            \\    current="${{current%\'}}"
            \\    local prefix="${{line%\"}}"
            \\    prefix="${{prefix%\'}}"
            \\    prefix="${{prefix%"$current"}}"
            \\    prefix="${{prefix%\"}}"
            \\    prefix="${{prefix%\'}}"
            \\    prefix="${{prefix##*[[:space:]]}}"
            \\    for ((i=0; i<${{#line}}; i++)); do
            \\        byte="${{line:i:1}}"
            \\        if ((escaped)); then
            \\            escaped=0
            \\        elif [[ "$byte" == \\ && "$quote" != "'" ]]; then
            \\            escaped=1
            \\        elif [[ -n "$quote" ]]; then
            \\            [[ "$byte" == "$quote" ]] && quote=''
            \\        elif [[ "$byte" == \" || "$byte" == "'" ]]; then
            \\            quote="$byte"
            \\        fi
            \\    done
            \\    COMPREPLY=()
            \\    while IFS= read -r candidate; do
            \\        candidate="${{candidate#"$prefix"}}"
            \\        case "$quote" in
            \\            \') candidate="${{candidate//\'/\'\\\'\'}}" ;;
            \\            \")
            \\                candidate="${{candidate//\\/\\\\}}"
            \\                candidate="${{candidate//\"/\\\"}}"
            \\                candidate="${{candidate//\$/\\\$}}"
            \\                candidate="${{candidate//\`/\\\`}}" ;;
            \\            *) printf -v candidate '%q' "$candidate" ;;
            \\        esac
            \\        COMPREPLY+=("$candidate")
            \\    done < <({s} __complete --shell bash --line "$line" 2>/dev/null)
            \\}}
            \\complete -F {s} {s}
            \\
        , .{ function, bin, function, bin }),
        .zsh => std.fmt.comptimePrint(
            \\{s}() {{
            \\    local -a candidates previous
            \\    (( CURRENT > 1 )) || return
            \\    previous=("${{(@Q)words[1,CURRENT-1]}}")
            \\    candidates=("${{(@f)$({s} __complete --shell zsh \
            \\        --words "${{previous[@]}}" "${{(Q)PREFIX}}" 2>/dev/null)}}")
            \\    compadd -a candidates
            \\}}
            \\compdef {s} {s}
            \\
        , .{ function, bin, function, bin }),
        .fish => std.fmt.comptimePrint(
            \\function {s}
            \\    {s} __complete --shell fish --line (commandline -cp) 2>/dev/null |
            \\        while read -l candidate
            \\            string escape -- "$candidate"
            \\        end
            \\end
            \\complete -c {s} -f -a '({s})'
            \\
        , .{ function, bin, bin, function }),
        .powershell => std.fmt.comptimePrint(
            \\Register-ArgumentCompleter -Native -CommandName {s} -ScriptBlock {{
            \\    param($wordToComplete, $commandAst, $cursorPosition)
            \\    $offset = $cursorPosition - $commandAst.Extent.StartOffset
            \\    $line = $commandAst.Extent.Text.PadRight($offset).Substring(0, $offset)
            \\    & {s} __complete --shell powershell --line $line 2>$null |
            \\        ForEach-Object {{
            \\            $value = $_
            \\            if ($_ -match '[^a-zA-Z0-9_=./:-]') {{
            \\                $value = "'" + $_.Replace("'", "''") + "'"
            \\            }}
            \\            [System.Management.Automation.CompletionResult]::new(
            \\                $value, $_, 'ParameterValue', $_)
            \\        }}
            \\}}
            \\
        , .{ bin, bin }),
        .nu => std.fmt.comptimePrint(
            \\def {s} [place: record] {{
            \\    do {{ ^{s} __complete --shell nu --words ...$place.command }} |
            \\        complete | get stdout | lines
            \\}}
            \\@complete {s}
            \\export extern {s} [...args: string]
            \\
        , .{ function, bin, function, bin }),
    };
}

fn quoteCommand(comptime value: []const u8, comptime shell: Shell) []const u8 {
    comptime var quoted: []const u8 = if (shell == .nu) "\"" else "'";
    inline for (value) |byte| {
        quoted = quoted ++ switch (byte) {
            '"' => if (shell == .nu) "\\\"" else "\"",
            '\'' => switch (shell) {
                .bash, .zsh => "'\\''",
                .fish => "\\'",
                .powershell => "''",
                .nu => "'",
            },
            '\\' => if (shell == .fish or shell == .nu) "\\\\" else "\\",
            else => &[_]u8{byte},
        };
    }

    return quoted ++ if (shell == .nu) "\"" else "'";
}

/// Writes newline-delimited candidates for `line[0..cursor]`.
///
/// `cursor` is a byte offset. The first shell word is treated as the program name.
/// The parser walks only complete words before the cursor, leaving an unfinished
/// word as the candidate prefix. Shell expansions are never evaluated.
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

    try completeWords(T, words[0..previous_count], current, writer);
}

/// Completes shell-tokenized input without reparsing its quoting or cursor units.
/// `previous` includes the program name. `current` is the unfinished word.
pub fn completeWords(
    comptime T: type,
    previous: []const []const u8,
    current: []const u8,
    writer: *std.Io.Writer,
) Error!void {
    if (previous.len == 0) return;
    if (previous.len >= max_words) return error.TooManyWords;

    var bytes = current.len;
    for (previous) |word| bytes +|= word.len +| 1;
    if (bytes > max_line_bytes) return error.LineTooLong;

    const compiled = compile.Compiled(T);
    var diagnostic: schema.Diagnostic = .{};
    var parser = schema.Parser.init(
        &compiled.table,
        .{ .values = previous[1..] },
        &diagnostic,
    );
    var pending_value: ?schema.FlagId = null;

    while (true) {
        const event = parser.next() catch |err| {
            if (err == error.ParseFailed and diagnostic.kind == .missing_value) {
                if (comptime compiled.table.flags.len > 0) {
                    if (diagnostic.binding) |binding| {
                        if (!compiled.table.flags[binding].require_equals) pending_value = binding;
                    }
                }
            }
            break;
        } orelse break;
        switch (event) {
            .flag => |flag| {
                if (comptime compiled.table.flags.len > 0) {
                    const option = compiled.table.flags[flag.id];
                    const last = previous[previous.len - 1];
                    if (flag.arg_index == previous.len - 2 and option.default_missing != null and
                        !option.require_equals and
                        (current.len < 2 or current[0] != '-' or option.allow_hyphen_values) and
                        attachedValue(&compiled.table, parser.scope, last) == null)
                    {
                        pending_value = flag.id;
                    }
                }
            },
            else => {},
        }
    }

    if (parser.external_selected) return;

    if (pending_value) |binding| {
        _ = try writeEnumValues(T, binding, current, "", writer);
        return;
    }
    if (!parser.flags_stopped) {
        if (attachedValue(&compiled.table, parser.scope, current)) |attached| {
            const stem = current[0 .. current.len - attached.prefix.len];
            _ = try writeEnumValues(T, attached.id, attached.prefix, stem, writer);
            return;
        }
    }

    const scope = compiled.table.scopes[parser.scope];
    if (comptime compiled.table.flags.len > 0) {
        if (parser.flags_stopped or !std.mem.startsWith(u8, current, "-")) {
            var positional = parser.positional_index;
            while (positional < scope.positionals.len) : (positional += 1) {
                const binding = scope.positionals[positional];
                if (compiled.table.flags[binding].max == 0) continue;
                _ = try writeEnumValues(T, binding, current, "", writer);
                break;
            }
        }
    }
    if (parser.flags_stopped) return;

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
                if (shell == .powershell and index + 1 < line.len and
                    line[index + 1] == active_quote)
                {
                    index += 1;
                    try appendByte(storage, &output_index, byte);
                    continue;
                }
                quote = null;
                continue;
            }
            if (byte == escapeByte(shell) and index + 1 < line.len) {
                const next = line[index + 1];
                const escaped = if (active_quote == '\'')
                    shell == .fish and (next == '\\' or next == '\'')
                else if (shell == .bash or shell == .zsh)
                    next == '\\' or next == '"' or next == '$' or next == '`' or next == '\n'
                else
                    true;
                if (escaped) {
                    index += 1;
                    try appendByte(storage, &output_index, next);
                    continue;
                }
            }
            try appendByte(storage, &output_index, byte);
            continue;
        }

        if (byte == '|' or byte == ';' or byte == '&') {
            word_count = 0;
            in_word = false;
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

const AttachedArgument = struct {
    id: schema.FlagId,
    prefix: []const u8,
};

fn attachedValue(
    table: *const schema.Table,
    command: schema.CmdId,
    current: []const u8,
) ?AttachedArgument {
    std.debug.assert(command < table.scopes.len);
    const scope = table.scopes[command];

    if (std.mem.startsWith(u8, current, "--")) {
        const rest = current[2..];
        const equal_index = std.mem.findScalar(u8, rest, '=') orelse return null;
        const name = findName(
            scope,
            .long,
            rest[0..equal_index],
        ) orelse return null;
        if (name.negated or name.value != null) return null;

        return switch (name.target) {
            .flag => |id| if (flagTakesValue(table.flags[id]))
                .{ .id = id, .prefix = rest[equal_index + 1 ..] }
            else
                null,
            .action => null,
        };
    }

    if (current.len < 3 or current[0] != '-') return null;

    for (current[1..], 1..) |_, index| {
        const name = findName(scope, .short, current[index..][0..1]) orelse return null;
        switch (name.target) {
            .flag => |id| {
                if (!flagTakesValue(table.flags[id]) or name.negated or name.value != null) {
                    continue;
                }
                const suffix = current[index + 1 ..];
                if (suffix.len == 0) return null;
                if (suffix[0] == '=') return .{ .id = id, .prefix = suffix[1..] };
                if (table.flags[id].require_equals) return null;

                return .{ .id = id, .prefix = suffix };
            },
            .action => {},
        }
    }

    return null;
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
    stem: []const u8,
    writer: *std.Io.Writer,
) Error!bool {
    const compiled = compile.Compiled(T);
    std.debug.assert(binding < compiled.bindings.len);

    return writeEnumValuesForBinding(T, T, binding, prefix, stem, writer, compiled.table.root);
}

fn writeEnumValuesForBinding(
    comptime Root: type,
    comptime Current: type,
    binding: schema.FlagId,
    prefix: []const u8,
    stem: []const u8,
    writer: *std.Io.Writer,
    comptime current: schema.CmdId,
) Error!bool {
    const compiled = compile.Compiled(Root);
    if (comptime compiled.bindings.len == 0) return false;

    const target = compiled.bindings[binding];
    if (target.command == current) {
        const info = comptime structInfo(Current);
        inline for (info.field_names, info.field_types) |field_name, Field| {
            if (std.mem.eql(u8, target.field, field_name)) {
                const enum_type = enumType(Field) orelse return false;
                inline for (@typeInfo(enum_type).@"enum".field_names) |item_name| {
                    if (kebabStartsWith(item_name, prefix)) {
                        try writer.writeAll(stem);
                        try writeKebab(item_name, writer);
                        try writer.writeByte('\n');
                    }
                }

                return true;
            }
        }

        unreachable;
    }

    const command_type = commandFieldType(Current) orelse return false;
    const union_type = commandUnion(command_type) orelse unreachable;
    const union_info = comptime unionInfo(union_type);

    inline for (union_info.field_names, union_info.field_types) |variant_name, Variant| {
        const child = comptime nodeId(Root, current, variant_name);
        if (isDescendant(compiled.nodes, target.command, child)) {
            return writeEnumValuesForBinding(Root, Variant, binding, prefix, stem, writer, child);
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

const structInfo = declaration.structInfo;
const unionInfo = declaration.unionInfo;
const commandFieldType = declaration.commandFieldType;
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
    try expectCompletion(Root, "tool run-task --format=pl", "--format=plain\n");
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

test "complete keeps flag and positional value contexts separate" {
    const Format = enum { json, plain };
    const Command = struct {
        output: []const u8 = "",
        format: Format = .plain,
        modes: []const Format = &.{},
        final: Format,
        verbose: bool = false,

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .format = .{ .short = 'f', .default_missing = "plain" },
            .verbose = .{ .short = 'v' },
            .modes = .{ .positional = true, .max = 1 },
            .final = .{ .positional = true },
        } };
    };

    try expectCompletion(Command, "tool --output ", "");
    try expectCompletion(Command, "tool --output=", "");
    try expectCompletion(Command, "tool --format j", "json\n");
    try expectCompletion(Command, "tool --format --ver", "--verbose\n");
    try expectCompletion(Command, "tool --format=", "--format=json\n--format=plain\n");
    try expectCompletion(Command, "tool -f=", "-f=json\n-f=plain\n");
    try expectCompletion(Command, "tool -vfpl", "-vfplain\n");
    try expectCompletion(Command, "tool -vf=pl", "-vf=plain\n");
    try expectCompletion(Command, "tool -vfplain j", "json\n");
    try expectCompletion(Command, "tool j", "json\n");
    try expectCompletion(Command, "tool -- j", "json\n");
    try expectCompletion(Command, "tool -- json pl", "plain\n");
    try expectCompletion(Command, "tool -- json plain j", "");
}

test "completion scripts invoke the hidden request" {
    const Command = struct {
        pub const meta: schema.Meta(@This()) = .{ .bin = "tool" };
    };

    inline for (comptime @typeInfo(Shell).@"enum".field_values) |value| {
        const shell: Shell = comptime @fromBackingInt(@intCast(value));
        const script = completionScript(Command, shell);

        try std.testing.expect(std.mem.indexOf(u8, script, "__complete") != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "tool") != null);
    }
}

fn expectCompletion(comptime T: type, line: []const u8, expected: []const u8) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    inline for (comptime @typeInfo(Shell).@"enum".field_values) |value| {
        const shell: Shell = comptime @fromBackingInt(@intCast(value));
        output.clearRetainingCapacity();
        try complete(T, line, line.len, shell, &output.writer);

        try std.testing.expectEqualStrings(expected, output.written());
    }
}
