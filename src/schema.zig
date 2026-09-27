const std = @import("std");

pub const FlagId = u16;
pub const CmdId = u16;

/// Operations the caller renders after parsing instead of bindings with reserved ids.
pub const Action = enum {
    help,
    version,
};

/// A single argv source. `program` is retained for usage rendering and is never parsed.
pub const Argv = struct {
    program: []const u8 = "",
    values: []const []const u8 = &.{},

    pub fn len(self: Argv) usize {
        return self.values.len;
    }

    pub fn get(self: Argv, index: usize) []const u8 {
        std.debug.assert(index < self.values.len);
        return self.values[index];
    }
};

/// Environment values borrow their selected source for the duration of a parse.
pub const Env = union(enum) {
    none,
    map: *const std.process.Environ.Map,
};

pub const Options = struct {
    env: Env = .none,
    diagnostic: ?*Diagnostic = null,
};

pub const Error = error{
    OutOfMemory,
    ParseFailed,
    HelpRequested,
    VersionRequested,
};

pub const Diagnostic = struct {
    kind: Kind = .none,
    arg_index: u32 = 0,
    command: CmdId = 0,
    binding: ?FlagId = null,
    token: []const u8 = "",
    expected: ?[]const u8 = null,

    pub const Kind = enum {
        none,
        unknown_flag,
        unknown_subcommand,
        missing_value,
        unexpected_value,
        unexpected_positional,
        invalid_value,
        missing_required,
        conflict,
        missing_requirement,
        missing_subcommand,
        help,
        version,
    };
};

pub const ValueKind = enum {
    boolean,
    count,
    signed_integer,
    unsigned_integer,
    float,
    enumeration,
    string,
    custom,
    list,
};

pub const Flag = struct {
    kind: ValueKind,
    /// Set only for `.list`, never to `.list` or `.count`.
    list_element: ?ValueKind = null,
    positional: bool = false,
    require_equals: bool = false,
    allow_hyphen_values: bool = false,
    default_missing: ?[]const u8 = null,
    min: ?u32 = null,
    max: ?u32 = null,
    one_of_flags: bool = false,
};

/// A spelling maps to either a user binding or a parser action.
pub const Target = union(enum) {
    flag: FlagId,
    action: Action,
};

pub const Name = struct {
    spelling: []const u8,
    target: Target,
    kind: Kind = .long,
    negated: bool = false,
    /// A fixed enum word supplied by an enum `one_of_flags` switch.
    value: ?[]const u8 = null,

    pub const Kind = enum {
        long,
        short,
    };
};

/// A child command spelling maps to the command scope it activates.
pub const Command = struct {
    spelling: []const u8,
    id: CmdId,
};

/// Payload for a catch-all subcommand.
/// The outer `args` slice is owned by the parse result. Its strings borrow argv.
pub const ExternalCommand = struct {
    args: []const []const u8 = &.{},
};

pub const UnknownFlags = enum {
    @"error",
    as_value,
};

/// A command scope contains only the lookup data the non-generic parser needs.
pub const Scope = struct {
    names: []const Name = &.{},
    commands: []const Command = &.{},
    positionals: []const FlagId = &.{},
    default_command: ?CmdId = null,
    external_command: ?CmdId = null,
    unknown_flags: UnknownFlags = .@"error",
};

/// Compiler output consumed by `Parser`. Arrays are compile-time owned and immutable.
pub const Table = struct {
    scopes: []const Scope,
    flags: []const Flag,
    root: CmdId = 0,
};

pub const Event = union(enum) {
    action: struct {
        action: Action,
        arg_index: u32,
    },
    flag: struct {
        id: FlagId,
        value: []const u8,
        negated: bool,
        arg_index: u32,
    },
    positional: struct {
        id: FlagId,
        value: []const u8,
        arg_index: u32,
    },
    command: struct {
        id: CmdId,
        arg_index: u32,
    },
    external: struct {
        id: CmdId,
        arg_index: u32,
    },
};

/// Parser state is deliberately independent of a declaration type.
pub const Parser = struct {
    table: *const Table,
    argv: Argv,
    diagnostic: *Diagnostic,
    arg_index: u32 = 0,
    scope: CmdId = 0,
    positional_index: usize = 0,
    positional_count: u32 = 0,
    positional_started: bool = false,
    flags_stopped: bool = false,
    short_token: []const u8 = "",
    short_count: usize = 0,
    short_index: usize = 0,
    short_value: []const u8 = "",
    short_arg_index: u32 = 0,
    replay_token: ?[]const u8 = null,
    replay_arg_index: u32 = 0,
    default_selected: bool = false,
    external_selected: bool = false,
    failed: bool = false,

    pub fn init(table: *const Table, argv: Argv, diagnostic: *Diagnostic) Parser {
        std.debug.assert(table.root < table.scopes.len);
        std.debug.assert(argv.len() <= std.math.maxInt(u32));
        return .{
            .table = table,
            .argv = argv,
            .diagnostic = diagnostic,
            .scope = table.root,
        };
    }

    /// Returns the next parser event. A syntax error is terminal for this parser.
    pub fn next(self: *Parser) Error!?Event {
        if (self.failed) return null;
        if (self.external_selected) return null;
        if (self.short_index < self.short_count) {
            return try self.nextShortEvent();
        }
        if (self.replay_token) |token| {
            const source_index = self.replay_arg_index;
            self.replay_token = null;
            return try self.wordEvent(token, source_index);
        }

        while (self.arg_index < self.argv.len()) {
            const source_index = self.arg_index;
            const token = self.argv.get(source_index);
            self.arg_index += 1;

            if (self.flags_stopped) {
                return try self.positionalEvent(token, source_index);
            }
            if (std.mem.eql(u8, token, "--")) {
                self.flags_stopped = true;
                continue;
            }
            if (std.mem.eql(u8, token, "-")) {
                return try self.positionalEvent(token, source_index);
            }
            if (std.mem.startsWith(u8, token, "--")) {
                return try self.longEvent(token, source_index);
            }
            if (std.mem.startsWith(u8, token, "-")) {
                if (isNegativeNumber(token)) {
                    if (!self.hasShort(token[1])) {
                        return try self.positionalEvent(token, source_index);
                    }
                }
                return try self.startShortEvents(token, source_index);
            }
            return try self.wordEvent(token, source_index);
        }
        return null;
    }

    fn wordEvent(self: *Parser, token: []const u8, source_index: u32) Error!Event {
        std.debug.assert(!self.flags_stopped);
        if (!self.positional_started) {
            if (self.findCommand(token)) |command| {
                std.debug.assert(command.id < self.table.scopes.len);
                self.scope = command.id;
                self.positional_index = 0;
                self.positional_count = 0;
                self.positional_started = false;
                return .{ .command = .{ .id = command.id, .arg_index = source_index } };
            }
            if (std.mem.eql(u8, token, "help")) {
                return .{ .action = .{ .action = .help, .arg_index = source_index } };
            }
            if (self.currentScope().default_command) |command| {
                if (!self.default_selected) {
                    std.debug.assert(command < self.table.scopes.len);
                    self.scope = command;
                    self.positional_index = 0;
                    self.positional_count = 0;
                    self.default_selected = true;
                    self.replay_token = token;
                    self.replay_arg_index = source_index;
                    return .{ .command = .{ .id = command, .arg_index = source_index } };
                }
            }
            if (self.currentScope().external_command) |command| {
                std.debug.assert(command < self.table.scopes.len);
                self.scope = command;
                self.external_selected = true;
                return .{ .external = .{ .id = command, .arg_index = source_index } };
            }
            if (self.currentScope().commands.len > 0 and self.currentScope().positionals.len == 0) {
                return self.fail(.unknown_subcommand, token, source_index, null);
            }
        }
        return self.positionalEvent(token, source_index);
    }

    fn longEvent(self: *Parser, token: []const u8, source_index: u32) Error!Event {
        const spelling_and_value = token[2..];
        const equal_index = std.mem.indexOfScalar(u8, spelling_and_value, '=');
        const spelling = if (equal_index) |index|
            spelling_and_value[0..index]
        else
            spelling_and_value;
        const attached_value = if (equal_index) |index| spelling_and_value[index + 1 ..] else null;
        const name = self.findName(.long, spelling) orelse {
            return self.unknownFlag(token, source_index);
        };
        return self.nameEvent(name, token, attached_value, source_index);
    }

    fn startShortEvents(self: *Parser, token: []const u8, source_index: u32) Error!Event {
        std.debug.assert(token.len > 1);

        var letter_index: usize = 1;
        var short_count: usize = 0;
        var value: []const u8 = "";
        while (letter_index < token.len) : (letter_index += 1) {
            const name = self.findShort(token[letter_index]) orelse {
                return self.unknownFlag(token, source_index);
            };
            short_count += 1;
            if (!self.nameTakesValue(name)) {
                if (letter_index + 1 < token.len and token[letter_index + 1] == '=') {
                    return self.fail(.unexpected_value, token, source_index, nameBinding(name));
                }
                continue;
            }

            const suffix = token[letter_index + 1 ..];
            if (suffix.len > 0) {
                if (self.flag(name.target.flag).require_equals and suffix[0] != '=') {
                    return self.fail(.missing_value, token, source_index, name.target.flag);
                }
                value = if (suffix[0] == '=') suffix[1..] else suffix;
            } else {
                value = try self.detachedValue(name.target.flag, source_index, token);
            }
            break;
        }

        self.short_token = token;
        self.short_count = short_count;
        self.short_index = 0;
        self.short_value = value;
        self.short_arg_index = source_index;
        return self.nextShortEvent();
    }

    fn nextShortEvent(self: *Parser) Error!Event {
        std.debug.assert(self.short_index < self.short_count);
        const letter_index = self.short_index + 1;
        const name = self.findShort(self.short_token[letter_index]) orelse unreachable;
        self.short_index += 1;
        return self.nameEvent(
            name,
            self.short_token,
            self.shortValueFor(name),
            self.short_arg_index,
        );
    }

    fn shortValueFor(self: *const Parser, name: *const Name) ?[]const u8 {
        if (self.nameTakesValue(name)) {
            return self.short_value;
        }
        return null;
    }

    fn nameEvent(
        self: *Parser,
        name: *const Name,
        token: []const u8,
        attached_value: ?[]const u8,
        source_index: u32,
    ) Error!Event {
        switch (name.target) {
            .action => |action| {
                if (attached_value != null) {
                    return self.fail(.unexpected_value, token, source_index, null);
                }
                return .{ .action = .{ .action = action, .arg_index = source_index } };
            },
            .flag => |id| {
                if (!self.nameTakesValue(name)) {
                    if (attached_value != null) {
                        return self.fail(.unexpected_value, token, source_index, id);
                    }
                    return .{ .flag = .{
                        .id = id,
                        .value = name.value orelse "",
                        .negated = name.negated,
                        .arg_index = source_index,
                    } };
                }
                const value = if (attached_value) |attached|
                    attached
                else
                    try self.detachedValue(id, source_index, token);
                return .{ .flag = .{
                    .id = id,
                    .value = value,
                    .negated = false,
                    .arg_index = source_index,
                } };
            },
        }
    }

    fn detachedValue(
        self: *Parser,
        id: FlagId,
        source_index: u32,
        token: ?[]const u8,
    ) Error![]const u8 {
        const option = self.flag(id);
        if (option.require_equals) {
            if (option.default_missing) |value| return value;
            return self.fail(.missing_value, token orelse "", source_index, id);
        }
        if (self.arg_index < self.argv.len()) {
            const candidate = self.argv.get(self.arg_index);
            if (!looksLikeFlag(candidate)) {
                self.arg_index += 1;
                return candidate;
            }
            if (option.allow_hyphen_values) {
                self.arg_index += 1;
                return candidate;
            }
            if (flagAcceptsNegativeNumber(option) and isNegativeNumber(candidate)) {
                self.arg_index += 1;
                return candidate;
            }
        }
        if (option.default_missing) |value| return value;
        return self.fail(.missing_value, token orelse "", source_index, id);
    }

    fn positionalEvent(self: *Parser, token: []const u8, source_index: u32) Error!Event {
        const scope = self.currentScope();
        while (self.positional_index < scope.positionals.len) {
            const id = scope.positionals[self.positional_index];
            const option = self.flag(id);
            if (option.kind != .list) break;
            if (option.max) |max| {
                if (max != 0) break;
            } else break;
            self.positional_index += 1;
            self.positional_count = 0;
        }
        if (self.positional_index >= scope.positionals.len) {
            return self.fail(.unexpected_positional, token, source_index, null);
        }
        const id = scope.positionals[self.positional_index];
        const option = self.flag(id);
        self.positional_started = true;
        if (option.kind != .list) {
            self.positional_index += 1;
            self.positional_count = 0;
        } else {
            std.debug.assert(self.positional_count < std.math.maxInt(u32));
            self.positional_count += 1;
            if (option.max) |max| {
                if (self.positional_count == max) {
                    self.positional_index += 1;
                    self.positional_count = 0;
                }
            }
        }
        return .{ .positional = .{ .id = id, .value = token, .arg_index = source_index } };
    }

    fn unknownFlag(self: *Parser, token: []const u8, source_index: u32) Error!Event {
        if (self.currentScope().unknown_flags == .as_value) {
            return self.positionalEvent(token, source_index);
        }
        return self.fail(.unknown_flag, token, source_index, null);
    }

    fn fail(
        self: *Parser,
        kind: Diagnostic.Kind,
        token: []const u8,
        source_index: u32,
        binding: ?FlagId,
    ) Error {
        self.failed = true;
        self.diagnostic.* = .{
            .kind = kind,
            .arg_index = source_index,
            .command = self.scope,
            .binding = binding,
            .token = token,
        };
        return error.ParseFailed;
    }

    fn currentScope(self: *const Parser) *const Scope {
        return &self.table.scopes[self.scope];
    }

    fn flag(self: *const Parser, id: FlagId) *const Flag {
        std.debug.assert(id < self.table.flags.len);
        return &self.table.flags[id];
    }

    fn findName(self: *const Parser, kind: Name.Kind, spelling: []const u8) ?*const Name {
        for (self.currentScope().names) |*name| {
            if (name.kind == kind and std.mem.eql(u8, name.spelling, spelling)) {
                return name;
            }
        }
        return null;
    }

    fn findShort(self: *const Parser, letter: u8) ?*const Name {
        return self.findName(.short, &.{letter});
    }

    fn hasShort(self: *const Parser, letter: u8) bool {
        return self.findShort(letter) != null;
    }

    fn findCommand(self: *const Parser, spelling: []const u8) ?*const Command {
        for (self.currentScope().commands) |*command| {
            if (std.mem.eql(u8, command.spelling, spelling)) return command;
        }
        return null;
    }

    fn nameTakesValue(self: *const Parser, name: *const Name) bool {
        if (name.value != null) return false;
        switch (name.target) {
            .action => return false,
            .flag => |id| {
                if (name.negated) return false;
                return flagTakesValue(self.flag(id));
            },
        }
    }
};

fn nameBinding(name: *const Name) ?FlagId {
    return switch (name.target) {
        .action => null,
        .flag => |id| id,
    };
}

fn flagTakesValue(flag: *const Flag) bool {
    return switch (flag.kind) {
        .boolean, .count => false,
        .signed_integer, .unsigned_integer, .float, .enumeration, .string, .custom, .list => true,
    };
}

fn flagAcceptsNegativeNumber(flag: *const Flag) bool {
    const kind = if (flag.kind == .list) flag.list_element orelse return false else flag.kind;
    return kind == .signed_integer or kind == .float;
}

fn looksLikeFlag(token: []const u8) bool {
    return token.len > 1 and token[0] == '-';
}

fn isNegativeNumber(token: []const u8) bool {
    if (token.len < 2 or token[0] != '-') return false;
    var index: usize = 1;
    var has_digits = false;
    while (index < token.len and std.ascii.isDigit(token[index])) : (index += 1) {}
    has_digits = index > 1;
    if (index < token.len and token[index] == '.') {
        index += 1;
        const decimal_start = index;
        while (index < token.len and std.ascii.isDigit(token[index])) : (index += 1) {}
        has_digits = has_digits or index != decimal_start;
    }
    if (!has_digits) return false;
    if (index < token.len and (token[index] == 'e' or token[index] == 'E')) {
        index += 1;
        if (index < token.len and (token[index] == '+' or token[index] == '-')) {
            index += 1;
        }
        const exponent_start = index;
        while (index < token.len and std.ascii.isDigit(token[index])) : (index += 1) {}
        if (index == exponent_start) return false;
    }
    return index == token.len;
}

pub const RepeatedScalar = enum {
    last_wins,
    @"error",
};

pub const Variant = struct {
    name: ?[]const u8 = null,
    help: []const u8 = "",
    aliases: []const []const u8 = &.{},
    hide: bool = false,
};

/// Generated metadata whose fields exactly match the tagged variants of `U`.
pub fn Variants(comptime U: type) type {
    const type_info = @typeInfo(U);
    if (type_info != .@"union" or type_info.@"union".tag_type == null) {
        @compileError("zlap VariantsMeta requires a tagged union type");
    }

    const variant_default: Variant = .{};
    const variant_count = type_info.@"union".fields.len;
    const variant_types: [variant_count]type = @splat(Variant);
    const variant_attributes: [variant_count]std.builtin.Type.StructField.Attributes = @splat(.{
        .@"comptime" = false,
        .@"align" = null,
        .default_value_ptr = &variant_default,
    });
    comptime var variant_names: [variant_count][]const u8 = undefined;
    inline for (type_info.@"union".fields, 0..) |field, index| {
        variant_names[index] = field.name;
    }
    return @Struct(.auto, null, &variant_names, &variant_types, &variant_attributes);
}

pub fn VariantsMeta(comptime U: type) type {
    return struct {
        variants: Variants(U) = .{},
    };
}

/// Typed options for one field of `T`. Relationships reject misspelled field names.
pub fn FieldMeta(comptime T: type) type {
    return struct {
        help: []const u8 = "",
        long_help: ?[]const u8 = null,
        short: ?u8 = null,
        long: ?[]const u8 = null,
        aliases: []const []const u8 = &.{},
        negate: ?[]const u8 = null,
        value_name: ?[]const u8 = null,
        env: ?[]const u8 = null,
        default_missing: ?[]const u8 = null,
        min: ?u32 = null,
        max: ?u32 = null,
        positional: bool = false,
        count: bool = false,
        global: bool = false,
        hide: bool = false,
        require_equals: bool = false,
        allow_hyphen_values: bool = false,
        one_of_flags: bool = false,
        conflicts: []const std.meta.FieldEnum(T) = &.{},
        requires: []const std.meta.FieldEnum(T) = &.{},
    };
}

/// Generated per-field metadata. Its members exactly match the fields of `T`.
pub fn Fields(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("zlap Meta requires a struct type");
    }

    const field_default: FieldMeta(T) = .{};
    const field_count = type_info.@"struct".fields.len;
    const field_types: [field_count]type = @splat(FieldMeta(T));
    const field_attributes: [field_count]std.builtin.Type.StructField.Attributes = @splat(.{
        .@"comptime" = false,
        .@"align" = null,
        .default_value_ptr = &field_default,
    });
    comptime var field_names: [field_count][]const u8 = undefined;
    inline for (type_info.@"struct".fields, 0..) |field, index| {
        field_names[index] = field.name;
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attributes);
}

/// Declaration metadata. Unsupported field shapes remain explicit for compiler checks.
pub fn Meta(comptime T: type) type {
    return struct {
        bin: ?[]const u8 = null,
        version: ?[]const u8 = null,
        about: []const u8 = "",
        long_about: ?[]const u8 = null,
        after_help: ?[]const u8 = null,
        default_subcommand: ?std.meta.FieldEnum(SubcommandUnion(T)) = null,
        external_subcommand: bool = false,
        unknown_flags: ?UnknownFlags = null,
        repeated_scalar: RepeatedScalar = .last_wins,
        /// Reserves `__complete` for this root command's hidden completion request.
        completion: bool = false,
        fields: Fields(T) = .{},
    };
}

/// Returns the tagged union selected by `T`'s command field, or an empty enum for
/// commands without one. Validation rejects metadata that requires a command field.
pub fn SubcommandUnion(comptime T: type) type {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const Union = switch (@typeInfo(field.type)) {
            .@"union" => field.type,
            .optional => |optional| switch (@typeInfo(optional.child)) {
                .@"union" => optional.child,
                else => continue,
            },
            else => continue,
        };
        if (@typeInfo(Union).@"union".tag_type != null) return Union;
    }
    return enum {};
}

test "Meta generates typed fields" {
    const TestCommand = struct {
        count: u8 = 0,
        output: []const u8,
    };
    const meta: Meta(TestCommand) = .{
        .fields = .{
            .count = .{ .count = true },
            .output = .{ .positional = true },
        },
    };
    const default_meta: Meta(TestCommand) = .{};
    try std.testing.expect(meta.fields.count.count);
    try std.testing.expect(meta.fields.output.positional);
    try std.testing.expect(!default_meta.fields.count.count);
}

test "parser preserves a table root" {
    const table: Table = .{ .scopes = &.{.{}}, .flags = &.{} };
    var diagnostic: Diagnostic = .{};
    const parser = Parser.init(&table, .{}, &diagnostic);
    try std.testing.expectEqual(@as(CmdId, 0), parser.scope);
}

test "parser emits long values and actions" {
    const table: Table = .{
        .scopes = &.{.{ .names = &.{
            .{ .spelling = "output", .target = .{ .flag = 0 } },
            .{ .spelling = "verbose", .target = .{ .flag = 1 } },
            .{ .spelling = "help", .target = .{ .action = .help } },
            .{ .spelling = "version", .target = .{ .action = .version } },
        } }},
        .flags = &.{
            .{ .kind = .string },
            .{ .kind = .boolean },
        },
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(
        &table,
        .{ .values = &.{ "--output=build.zig", "--verbose", "--help", "--version" } },
        &diagnostic,
    );

    switch ((try parser.next()).?) {
        .flag => |event| {
            try std.testing.expectEqual(@as(FlagId, 0), event.id);
            try std.testing.expectEqualStrings("build.zig", event.value);
            try std.testing.expectEqual(@as(u32, 0), event.arg_index);
        },
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .flag => |event| {
            try std.testing.expectEqual(@as(FlagId, 1), event.id);
            try std.testing.expectEqual(@as(u32, 1), event.arg_index);
        },
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .action => |event| {
            try std.testing.expectEqual(Action.help, event.action);
            try std.testing.expectEqual(@as(u32, 2), event.arg_index);
        },
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .action => |event| {
            try std.testing.expectEqual(Action.version, event.action);
            try std.testing.expectEqual(@as(u32, 3), event.arg_index);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try parser.next()) == null);
}

test "parser validates short clusters before emitting events" {
    const table: Table = .{
        .scopes = &.{.{ .names = &.{
            .{ .spelling = "a", .target = .{ .flag = 0 }, .kind = .short },
            .{ .spelling = "o", .target = .{ .flag = 1 }, .kind = .short },
        } }},
        .flags = &.{
            .{ .kind = .boolean },
            .{ .kind = .string },
        },
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{"-ao=result"} }, &diagnostic);

    switch ((try parser.next()).?) {
        .flag => |event| try std.testing.expectEqual(@as(FlagId, 0), event.id),
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .flag => |event| {
            try std.testing.expectEqual(@as(FlagId, 1), event.id);
            try std.testing.expectEqualStrings("result", event.value);
            try std.testing.expectEqual(@as(u32, 0), event.arg_index);
        },
        else => return error.TestUnexpectedResult,
    }

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{ "-ao", "result" } }, &diagnostic);
    switch ((try parser.next()).?) {
        .flag => |event| try std.testing.expectEqual(@as(FlagId, 0), event.id),
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .flag => |event| try std.testing.expectEqualStrings("result", event.value),
        else => return error.TestUnexpectedResult,
    }

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{"-ax"} }, &diagnostic);
    try std.testing.expectError(error.ParseFailed, parser.next());
    try std.testing.expectEqual(Diagnostic.Kind.unknown_flag, diagnostic.kind);
    try std.testing.expect((try parser.next()) == null);
}

test "parser emits no event after a syntax error" {
    const table: Table = .{
        .scopes = &.{.{ .names = &.{.{ .spelling = "help", .target = .{ .action = .help } }} }},
        .flags = &.{},
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{ "--unknown", "--help" } }, &diagnostic);

    try std.testing.expectError(error.ParseFailed, parser.next());
    try std.testing.expectEqual(Diagnostic.Kind.unknown_flag, diagnostic.kind);
    try std.testing.expect((try parser.next()) == null);
}

test "parser handles terminators and negative numeric positionals" {
    const table: Table = .{
        .scopes = &.{.{
            .names = &.{.{ .spelling = "5", .target = .{ .flag = 1 }, .kind = .short }},
            .positionals = &.{0},
        }},
        .flags = &.{
            .{ .kind = .list, .list_element = .string, .positional = true },
            .{ .kind = .boolean },
        },
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(
        &table,
        .{ .values = &.{ "-7", "-.5", "-5", "--", "--word", "-" } },
        &diagnostic,
    );

    switch ((try parser.next()).?) {
        .positional => |event| {
            try std.testing.expectEqualStrings("-7", event.value);
            try std.testing.expectEqual(@as(u32, 0), event.arg_index);
        },
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .positional => |event| {
            try std.testing.expectEqualStrings("-.5", event.value);
            try std.testing.expectEqual(@as(u32, 1), event.arg_index);
            try std.testing.expectEqual(@as(f64, -0.5), try std.fmt.parseFloat(f64, event.value));
        },
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .flag => |event| try std.testing.expectEqual(@as(FlagId, 1), event.id),
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .positional => |event| {
            try std.testing.expectEqualStrings("--word", event.value);
            try std.testing.expectEqual(@as(u32, 4), event.arg_index);
        },
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .positional => |event| try std.testing.expectEqualStrings("-", event.value),
        else => return error.TestUnexpectedResult,
    }
}

test "parser requires equals for short values" {
    const table: Table = .{
        .scopes = &.{.{ .names = &.{
            .{ .spelling = "o", .target = .{ .flag = 0 }, .kind = .short },
        } }},
        .flags = &.{.{ .kind = .string, .require_equals = true }},
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{"-ovalue"} }, &diagnostic);

    try std.testing.expectError(error.ParseFailed, parser.next());
    try std.testing.expectEqual(Diagnostic.Kind.missing_value, diagnostic.kind);
    try std.testing.expectEqual(@as(?FlagId, 0), diagnostic.binding);

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{"-o=value"} }, &diagnostic);
    switch ((try parser.next()).?) {
        .flag => |event| try std.testing.expectEqualStrings("value", event.value),
        else => return error.TestUnexpectedResult,
    }
}

test "parser rejects flag-shaped detached values and routes pass-through flags" {
    const table: Table = .{
        .scopes = &.{.{
            .names = &.{.{ .spelling = "number", .target = .{ .flag = 1 } }},
            .positionals = &.{0},
            .unknown_flags = .as_value,
        }},
        .flags = &.{
            .{ .kind = .list, .list_element = .string, .positional = true },
            .{ .kind = .signed_integer },
        },
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{ "--number", "-12" } }, &diagnostic);
    switch ((try parser.next()).?) {
        .flag => |event| {
            try std.testing.expectEqual(@as(FlagId, 1), event.id);
            try std.testing.expectEqualStrings("-12", event.value);
        },
        else => return error.TestUnexpectedResult,
    }

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{ "--number", "--unknown" } }, &diagnostic);
    try std.testing.expectError(error.ParseFailed, parser.next());
    try std.testing.expectEqual(Diagnostic.Kind.missing_value, diagnostic.kind);
    try std.testing.expectEqual(@as(u32, 0), diagnostic.arg_index);

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{"--unknown"} }, &diagnostic);
    switch ((try parser.next()).?) {
        .positional => |event| try std.testing.expectEqualStrings("--unknown", event.value),
        else => return error.TestUnexpectedResult,
    }
}

test "parser emits command transitions for canonical names and aliases" {
    const table: Table = .{
        .scopes = &.{
            .{ .commands = &.{
                .{ .spelling = "run", .id = 1 },
                .{ .spelling = "r", .id = 1 },
            } },
            .{ .positionals = &.{0} },
        },
        .flags = &.{.{ .kind = .string, .positional = true }},
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{ "run", "task" } }, &diagnostic);

    switch ((try parser.next()).?) {
        .command => |event| {
            try std.testing.expectEqual(@as(CmdId, 1), event.id);
            try std.testing.expectEqual(@as(u32, 0), event.arg_index);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(CmdId, 1), parser.scope);
    try std.testing.expectEqual(@as(usize, 0), parser.positional_index);
    switch ((try parser.next()).?) {
        .positional => |event| try std.testing.expectEqualStrings("task", event.value),
        else => return error.TestUnexpectedResult,
    }

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{"r"} }, &diagnostic);
    switch ((try parser.next()).?) {
        .command => |event| try std.testing.expectEqual(@as(CmdId, 1), event.id),
        else => return error.TestUnexpectedResult,
    }
}

test "parser stops matching commands after a positional or terminator" {
    const table: Table = .{
        .scopes = &.{
            .{
                .commands = &.{.{ .spelling = "run", .id = 1 }},
                .positionals = &.{0},
            },
            .{},
        },
        .flags = &.{.{ .kind = .list, .list_element = .string, .positional = true }},
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{ "input", "run" } }, &diagnostic);

    switch ((try parser.next()).?) {
        .positional => |event| try std.testing.expectEqualStrings("input", event.value),
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .positional => |event| try std.testing.expectEqualStrings("run", event.value),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(CmdId, 0), parser.scope);

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{ "--", "run" } }, &diagnostic);
    switch ((try parser.next()).?) {
        .positional => |event| try std.testing.expectEqualStrings("run", event.value),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(CmdId, 0), parser.scope);
}

test "parser keeps detached option values out of command matching" {
    const table: Table = .{
        .scopes = &.{
            .{
                .names = &.{.{ .spelling = "output", .target = .{ .flag = 0 } }},
                .commands = &.{.{ .spelling = "run", .id = 1 }},
            },
            .{},
        },
        .flags = &.{.{ .kind = .string }},
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{ "--output", "run" } }, &diagnostic);

    switch ((try parser.next()).?) {
        .flag => |event| {
            try std.testing.expectEqual(@as(FlagId, 0), event.id);
            try std.testing.expectEqualStrings("run", event.value);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect((try parser.next()) == null);
    try std.testing.expectEqual(@as(CmdId, 0), parser.scope);
}

test "parser distinguishes unknown child commands from leaf positionals" {
    const table: Table = .{
        .scopes = &.{
            .{ .commands = &.{.{ .spelling = "run", .id = 1 }} },
            .{},
        },
        .flags = &.{},
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{"missing"} }, &diagnostic);
    try std.testing.expectError(error.ParseFailed, parser.next());
    try std.testing.expectEqual(Diagnostic.Kind.unknown_subcommand, diagnostic.kind);
    try std.testing.expectEqual(@as(CmdId, 0), diagnostic.command);

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{ "run", "missing" } }, &diagnostic);
    switch ((try parser.next()).?) {
        .command => |event| try std.testing.expectEqual(@as(CmdId, 1), event.id),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.ParseFailed, parser.next());
    try std.testing.expectEqual(Diagnostic.Kind.unexpected_positional, diagnostic.kind);
    try std.testing.expectEqual(@as(CmdId, 1), diagnostic.command);
}

test "parser gives declared help child precedence over synthesized help" {
    const table: Table = .{
        .scopes = &.{
            .{
                .names = &.{.{ .spelling = "help", .target = .{ .action = .help } }},
                .commands = &.{
                    .{ .spelling = "help", .id = 1 },
                    .{ .spelling = "run", .id = 2 },
                },
            },
            .{},
            .{},
        },
        .flags = &.{},
    };
    var diagnostic: Diagnostic = .{};
    var parser = Parser.init(&table, .{ .values = &.{"help"} }, &diagnostic);

    switch ((try parser.next()).?) {
        .command => |event| try std.testing.expectEqual(@as(CmdId, 1), event.id),
        else => return error.TestUnexpectedResult,
    }

    diagnostic = .{};
    parser = Parser.init(&table, .{ .values = &.{ "run", "help" } }, &diagnostic);
    switch ((try parser.next()).?) {
        .command => |event| try std.testing.expectEqual(@as(CmdId, 2), event.id),
        else => return error.TestUnexpectedResult,
    }
    switch ((try parser.next()).?) {
        .action => |event| try std.testing.expectEqual(Action.help, event.action),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(CmdId, 2), parser.scope);
}
