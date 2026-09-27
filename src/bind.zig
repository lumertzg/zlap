//! Typed binding for compiled command trees.

const std = @import("std");
const compile = @import("compile.zig");
const declaration = @import("declaration.zig");
const render = @import("render.zig");
const schema = @import("schema.zig");
const spec_module = @import("spec.zig");

const ConversionError = error{InvalidValue};
const BindingError = ConversionError || error{ OutOfMemory, Conflict };

/// Initializes declared defaults. Count fields start at zero even when required, while
/// the seen set still decides whether they satisfy the required-field check.
pub fn defaults(comptime T: type) T {
    var value: T = undefined;
    inline for (comptime structFields(T)) |field| {
        if (field.defaultValue()) |default_value| {
            @field(value, field.name) = default_value;
        } else if (comptime isCountField(T, field.name)) {
            @field(value, field.name) = 0;
        }
    }
    return value;
}

/// Parses argv into a freshly default-initialized value.
///
/// String fields borrow argv. Lists allocate from `allocator`, and callers free each
/// populated list with the same allocator after a successful parse.
pub fn parseFrom(
    comptime T: type,
    allocator: std.mem.Allocator,
    argv: schema.Argv,
    options: schema.Options,
) schema.Error!T {
    var value = defaults(T);
    var active_lists: ActiveLists = .{};
    defer active_lists.deinit(allocator);
    errdefer releaseActiveLists(allocator, &active_lists);

    try fillWithLists(T, allocator, &value, argv, options, &active_lists);
    return value;
}

/// Applies argv bindings to an existing value without consulting environment values or
/// field defaults. A list mentioned by argv is replaced, while an omitted list is
/// retained. Repeating the active command merges it. Selecting another command starts
/// that variant from its defaults and requires its required fields in this argv.
///
/// On success, this function frees list allocations displaced by this update with
/// `allocator`. Declared list defaults are borrowed and are never freed. All other
/// populated lists must have been allocated with `allocator` by `parseFrom` or a prior
/// successful `updateFrom`. Ownership transfers to this call when it replaces a list or
/// command variant. On failure, list and command-variant changes made by this call are
/// restored and their original allocations remain owned by `value`. Scalar changes made
/// before the error remain, matching `fill`.
pub fn updateFrom(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: *T,
    argv: schema.Argv,
    options: schema.Options,
) schema.Error!void {
    var active_lists: ActiveLists = .{};
    defer active_lists.deinit(allocator);

    var active_commands: ActiveCommands = .{};
    defer active_commands.deinit(allocator);
    errdefer restoreActiveCommands(allocator, &active_commands);
    errdefer releaseActiveLists(allocator, &active_lists);

    try updateWithLists(T, allocator, value, argv, options, &active_lists, &active_commands);
}

/// Applies argv to `value`, which must have been initialized with `defaults(T)`.
///
/// Scalar and command changes made before an error remain. Lists touched by this call
/// are restored before their temporary storage is released, so no failed fill leaves a
/// dangling list slice in `value`.
pub fn fill(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: *T,
    argv: schema.Argv,
    options: schema.Options,
) schema.Error!void {
    var active_lists: ActiveLists = .{};
    defer active_lists.deinit(allocator);
    errdefer releaseActiveLists(allocator, &active_lists);
    try fillWithLists(T, allocator, value, argv, options, &active_lists);
}

fn fillWithLists(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: *T,
    argv: schema.Argv,
    options: schema.Options,
    active_lists: *ActiveLists,
) schema.Error!void {
    const compiled = compile.Compiled(T);
    std.debug.assert(compiled.table.flags.len == compiled.bindings.len);

    var local_diagnostic: schema.Diagnostic = .{};
    const diagnostic = options.diagnostic orelse &local_diagnostic;
    diagnostic.* = .{};

    var context: FillContext(T) = .{
        .allocator = allocator,
        .value = value,
        .active_lists = active_lists,
    };
    var parser = schema.Parser.init(&compiled.table, argv, diagnostic);

    try driveEvents(T, value, &context, &parser, diagnostic, .fill);
    try finalizeFill(T, allocator, value, argv, options.env, active_lists, &context, diagnostic);
}

fn updateWithLists(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: *T,
    argv: schema.Argv,
    options: schema.Options,
    active_lists: *ActiveLists,
    active_commands: *ActiveCommands,
) schema.Error!void {
    const compiled = compile.Compiled(T);
    std.debug.assert(compiled.table.flags.len == compiled.bindings.len);

    var local_diagnostic: schema.Diagnostic = .{};
    const diagnostic = options.diagnostic orelse &local_diagnostic;
    diagnostic.* = .{};

    var context: FillContext(T) = .{
        .allocator = allocator,
        .value = value,
        .active_lists = active_lists,
    };
    var new_commands: NewCommands(T) = NewCommands(T).initEmpty();
    var parser = schema.Parser.init(&compiled.table, argv, diagnostic);

    const mode: ParseMode(T) = .{ .update = .{
        .allocator = allocator,
        .new_commands = &new_commands,
        .active_commands = active_commands,
    } };
    try driveEvents(T, value, &context, &parser, diagnostic, mode);
    try finalizeUpdate(
        T,
        allocator,
        value,
        argv,
        active_lists,
        active_commands,
        &context,
        new_commands,
        diagnostic,
    );
}

fn ParseMode(comptime T: type) type {
    return union(enum) {
        fill,
        update: struct {
            allocator: std.mem.Allocator,
            new_commands: *NewCommands(T),
            active_commands: *ActiveCommands,
        },

        const Self = @This();

        fn activate(
            self: Self,
            value: *T,
            path: *ActivePath(T),
            target: schema.CmdId,
        ) schema.Error!void {
            switch (self) {
                .fill => try activateCommand(T, value, path, target),
                .update => |update| try updateCommand(
                    T,
                    update.allocator,
                    value,
                    path,
                    update.new_commands,
                    update.active_commands,
                    target,
                ),
            }
        }
    };
}

fn driveEvents(
    comptime T: type,
    value: *T,
    context: *FillContext(T),
    parser: *schema.Parser,
    diagnostic: *schema.Diagnostic,
    mode: ParseMode(T),
) schema.Error!void {
    var events_remaining = eventCountMax(parser.argv);
    while (events_remaining > 0) : (events_remaining -= 1) {
        const event = parser.next() catch |err| return context.handleParserError(diagnostic, err);
        try handleEvent(T, value, context, parser, diagnostic, mode, event orelse return);
    }
    std.debug.assert(false);
    return error.ParseFailed;
}

fn eventCountMax(argv: schema.Argv) usize {
    // A default subcommand emits one activation before replaying its triggering word.
    var count: usize = 2;
    for (argv.values) |argument| {
        count +|= @max(argument.len, 1);
    }
    return count;
}

fn handleEvent(
    comptime T: type,
    value: *T,
    context: *FillContext(T),
    parser: *const schema.Parser,
    diagnostic: *schema.Diagnostic,
    mode: ParseMode(T),
    event: schema.Event,
) schema.Error!void {
    if (bindingInput(event)) |input| {
        context.bind(input) catch |err| try context.recordBindingError(parser, input, err);
        return;
    }

    switch (event) {
        .action => |action| return reportAction(
            diagnostic,
            parser.scope,
            action.action,
            action.arg_index,
        ),
        .command => |command| try mode.activate(value, &context.path, command.id),
        .external => |external| {
            try mode.activate(value, &context.path, external.id);
            try context.captureExternal(external.id, parser.argv, external.arg_index);
        },
        .flag, .positional => unreachable,
    }
}

fn reportAction(
    diagnostic: *schema.Diagnostic,
    command: schema.CmdId,
    action: schema.Action,
    arg_index: u32,
) schema.Error {
    diagnostic.* = .{
        .kind = switch (action) {
            .help => .help,
            .version => .version,
        },
        .arg_index = arg_index,
        .command = command,
    };
    return switch (action) {
        .help => error.HelpRequested,
        .version => error.VersionRequested,
    };
}

fn finalizeFill(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: *T,
    argv: schema.Argv,
    env: schema.Env,
    active_lists: *ActiveLists,
    context: *FillContext(T),
    diagnostic: *schema.Diagnostic,
) schema.Error!void {
    try context.failIfRecorded(diagnostic);
    try applyEnvironment(T, T, value, context, env, argv, 0, 0);
    try context.failIfRecorded(diagnostic);
    try checkRequired(T, &context.path, context.seen, diagnostic, argv);
    try finishActivePath(T, T, value, &context.path, context.seen, diagnostic, argv, 0, 0);
    try finishActiveLists(allocator, active_lists);
}

fn finalizeUpdate(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: *T,
    argv: schema.Argv,
    active_lists: *ActiveLists,
    active_commands: *ActiveCommands,
    context: *FillContext(T),
    new_commands: NewCommands(T),
    diagnostic: *schema.Diagnostic,
) schema.Error!void {
    try context.failIfRecorded(diagnostic);
    try checkNewRequired(T, value, &context.path, context.seen, new_commands, diagnostic, argv);
    try finishActivePath(T, T, value, &context.path, context.seen, diagnostic, argv, 0, 0);
    try finishActiveLists(allocator, active_lists);
    commitActiveLists(allocator, active_lists);
    active_commands.commit(allocator);
}

fn applyEnvironment(
    comptime Root: type,
    comptime Current: type,
    value: *Current,
    context: *FillContext(Root),
    env: schema.Env,
    argv: schema.Argv,
    comptime current: schema.CmdId,
    comptime depth: usize,
) schema.Error!void {
    const meta = comptime commandMeta(Current);
    inline for (comptime structFields(Current)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const options = comptime @field(meta.fields, field.name);
        if (comptime options.env) |name| {
            const id = bindingId(Root, current, field.name);
            if (!context.seen.isSet(id)) {
                if (environmentValue(env, name)) |text| {
                    context.bind(.{
                        .id = id,
                        .text = text,
                        .arg_index = @intCast(argv.len()),
                        .negated = false,
                        .is_flag = false,
                    }) catch |err| {
                        if (err == error.InvalidValue) {
                            if (context.first_conversion == null) {
                                context.first_conversion = invalidValueDiagnostic(
                                    current,
                                    id,
                                    text,
                                    @intCast(argv.len()),
                                    compile.Compiled(Root).bindings[id].parse_arg_expected,
                                );
                            }
                            return;
                        }
                        return error.OutOfMemory;
                    };
                }
            }
        }
    }

    if (depth == context.path.depth) return;
    const command = commandField(Current) orelse unreachable;
    const Union = commandUnion(command.type);
    const selected = context.path.ids[depth + 1];
    if (comptime isOptionalCommand(command.type)) {
        if (@field(value.*, command.name)) |*selected_value| {
            return applyEnvironmentInVariant(
                Root,
                Union,
                selected_value,
                context,
                env,
                argv,
                current,
                depth,
                selected,
            );
        }
        unreachable;
    }
    return applyEnvironmentInVariant(
        Root,
        Union,
        &@field(value.*, command.name),
        context,
        env,
        argv,
        current,
        depth,
        selected,
    );
}

fn applyEnvironmentInVariant(
    comptime Root: type,
    comptime Union: type,
    active: *Union,
    context: *FillContext(Root),
    env: schema.Env,
    argv: schema.Argv,
    comptime current: schema.CmdId,
    comptime depth: usize,
    selected: schema.CmdId,
) schema.Error!void {
    switch (active.*) {
        inline else => |*payload, tag| {
            const child = comptime nodeIdForVariant(Root, current, @tagName(tag));
            std.debug.assert(child == selected);
            return applyEnvironment(
                Root,
                @TypeOf(payload.*),
                payload,
                context,
                env,
                argv,
                child,
                depth + 1,
            );
        },
    }
}

fn environmentValue(env: schema.Env, name: []const u8) ?[]const u8 {
    return switch (env) {
        .none => null,
        .map => |map| map.get(name),
    };
}

const BindingInput = struct {
    id: schema.FlagId,
    text: []const u8,
    arg_index: u32,
    negated: bool,
    is_flag: bool,
};

fn bindingInput(event: schema.Event) ?BindingInput {
    return switch (event) {
        .flag => |flag| .{
            .id = flag.id,
            .text = flag.value,
            .arg_index = flag.arg_index,
            .negated = flag.negated,
            .is_flag = true,
        },
        .positional => |positional| .{
            .id = positional.id,
            .text = positional.value,
            .arg_index = positional.arg_index,
            .negated = false,
            .is_flag = false,
        },
        else => null,
    };
}

fn FillContext(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        value: *T,
        seen: Seen(T) = Seen(T).initEmpty(),
        path: ActivePath(T) = ActivePath(T).init(),
        active_lists: *ActiveLists,
        first_conversion: ?schema.Diagnostic = null,
        first_conflict: ?schema.Diagnostic = null,

        fn bind(self: *Self, input: BindingInput) BindingError!void {
            const compiled = compile.Compiled(T);
            std.debug.assert(input.id < compiled.bindings.len);

            inline for (compiled.bindings, 0..) |binding, index| {
                if (input.id == index) {
                    if (compiled.table.flags[index].one_of_flags and self.seen.isSet(index)) {
                        return error.Conflict;
                    }
                    const options: BindingOptions = .{
                        .input = input,
                        .is_count = compiled.table.flags[index].kind == .count,
                        .replace_list = !self.seen.isSet(index),
                        .list_max = compiled.table.flags[index].max,
                    };
                    try bindInActiveCommand(
                        T,
                        T,
                        self.value,
                        self,
                        binding.command,
                        binding.field,
                        options,
                        0,
                        0,
                    );
                    self.seen.set(index);
                    return;
                }
            }
            unreachable;
        }

        fn captureExternal(
            self: *Self,
            target: schema.CmdId,
            argv: schema.Argv,
            arg_index: u32,
        ) error{OutOfMemory}!void {
            try captureExternalInActiveCommand(
                T,
                T,
                self.value,
                self,
                target,
                argv,
                arg_index,
                0,
                0,
            );
        }

        fn recordBindingError(
            self: *Self,
            parser: *const schema.Parser,
            input: BindingInput,
            err: BindingError,
        ) error{OutOfMemory}!void {
            if (err == error.InvalidValue) {
                if (self.first_conversion == null) {
                    self.first_conversion = invalidValueDiagnostic(
                        parser.scope,
                        input.id,
                        input.text,
                        input.arg_index,
                        parseArgExpectedForBinding(T, input.id),
                    );
                }
                return;
            }
            if (err == error.Conflict) {
                if (self.first_conflict == null) {
                    self.first_conflict = .{
                        .kind = .conflict,
                        .arg_index = input.arg_index,
                        .command = parser.scope,
                        .binding = input.id,
                        .token = input.text,
                    };
                }
                return;
            }
            return error.OutOfMemory;
        }

        fn handleParserError(
            self: *const Self,
            diagnostic: *schema.Diagnostic,
            err: schema.Error,
        ) schema.Error!void {
            if (self.first_conversion) |conversion| {
                diagnostic.* = conversion;
                return error.ParseFailed;
            }
            return err;
        }

        fn failIfRecorded(
            self: *const Self,
            diagnostic: *schema.Diagnostic,
        ) schema.Error!void {
            if (self.first_conversion) |conversion| {
                diagnostic.* = conversion;
                return error.ParseFailed;
            }
            if (self.first_conflict) |conflict| {
                diagnostic.* = conflict;
                return error.ParseFailed;
            }
        }
    };
}

const BindingOptions = struct {
    input: BindingInput,
    is_count: bool,
    replace_list: bool,
    list_max: ?u32,
};

fn bindInActiveCommand(
    comptime Root: type,
    comptime Current: type,
    current_value: *Current,
    context: *FillContext(Root),
    target: schema.CmdId,
    comptime field_name: []const u8,
    options: BindingOptions,
    comptime current: schema.CmdId,
    comptime depth: usize,
) BindingError!void {
    // The declaration tree cannot recurse by value, and this descent is bounded by max_depth.
    if (target == current) {
        inline for (comptime structFields(Current)) |field| {
            if (comptime std.mem.eql(u8, field.name, field_name)) {
                std.debug.assert(!isCommandField(field.type));
                return bindField(
                    field.type,
                    context.allocator,
                    &@field(current_value.*, field.name),
                    field.default_value_ptr,
                    context.active_lists,
                    options.input.id,
                    options.input.text,
                    options.input.negated,
                    options.input.is_flag,
                    options.is_count,
                    options.replace_list,
                    options.list_max,
                );
            }
        }
        unreachable;
    }

    std.debug.assert(depth < context.path.depth);
    const command = commandField(Current) orelse unreachable;
    const Union = commandUnion(command.type);
    if (comptime isOptionalCommand(command.type)) {
        if (@field(current_value.*, command.name)) |*selected| {
            return bindInSelectedVariant(
                Root,
                Union,
                selected,
                context,
                target,
                field_name,
                options,
                current,
                depth,
            );
        }
        unreachable;
    }
    return bindInSelectedVariant(
        Root,
        Union,
        &@field(current_value.*, command.name),
        context,
        target,
        field_name,
        options,
        current,
        depth,
    );
}

fn bindInSelectedVariant(
    comptime Root: type,
    comptime Union: type,
    selected: *Union,
    context: *FillContext(Root),
    target: schema.CmdId,
    comptime field_name: []const u8,
    options: BindingOptions,
    comptime current: schema.CmdId,
    comptime depth: usize,
) BindingError!void {
    switch (selected.*) {
        inline else => |*payload, tag| {
            const child = comptime nodeIdForVariant(Root, current, @tagName(tag));
            if (context.path.ids[depth + 1] == child) {
                return bindInActiveCommand(
                    Root,
                    @TypeOf(payload.*),
                    payload,
                    context,
                    target,
                    field_name,
                    options,
                    child,
                    depth + 1,
                );
            }
            unreachable;
        },
    }
}

fn activateCommand(
    comptime T: type,
    value: *T,
    path: *ActivePath(T),
    target: schema.CmdId,
) schema.Error!void {
    const compiled = compile.Compiled(T);
    std.debug.assert(target < compiled.nodes.len);
    std.debug.assert(path.depth + 1 < path.ids.len);
    std.debug.assert(compiled.nodes[target].parent != null);
    std.debug.assert(compiled.nodes[target].parent.? == path.ids[path.depth]);

    try activateInActiveCommand(T, T, value, path, target, 0, 0);
    path.depth += 1;
    path.ids[path.depth] = target;
}

fn updateCommand(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: *T,
    path: *ActivePath(T),
    new_commands: *NewCommands(T),
    active_commands: *ActiveCommands,
    target: schema.CmdId,
) schema.Error!void {
    const compiled = compile.Compiled(T);
    std.debug.assert(target < compiled.nodes.len);
    std.debug.assert(path.depth + 1 < path.ids.len);
    std.debug.assert(compiled.nodes[target].parent != null);
    std.debug.assert(compiled.nodes[target].parent.? == path.ids[path.depth]);

    try updateInActiveCommand(
        T,
        T,
        allocator,
        value,
        path,
        new_commands,
        active_commands,
        target,
        0,
        0,
    );
    path.depth += 1;
    path.ids[path.depth] = target;
}

fn updateInActiveCommand(
    comptime Root: type,
    comptime Current: type,
    allocator: std.mem.Allocator,
    value: *Current,
    path: *const ActivePath(Root),
    new_commands: *NewCommands(Root),
    active_commands: *ActiveCommands,
    target: schema.CmdId,
    comptime current: schema.CmdId,
    comptime depth: usize,
) schema.Error!void {
    if (depth == path.depth) {
        std.debug.assert(current == path.ids[depth]);
        const command = commandField(Current) orelse unreachable;
        const Union = commandUnion(command.type);
        inline for (comptime unionFields(Union)) |variant| {
            const child = comptime nodeIdForVariant(Root, current, variant.name);
            if (target == child) {
                if (!new_commands.isSet(current) and commandHasVariant(
                    command.type,
                    @field(value.*, command.name),
                    Union,
                    variant.name,
                )) return;

                if (!new_commands.isSet(current)) {
                    try active_commands.capture(
                        allocator,
                        command.type,
                        &@field(value.*, command.name),
                    );
                }
                @field(value.*, command.name) = @unionInit(
                    Union,
                    variant.name,
                    defaults(variant.type),
                );
                new_commands.set(child);
                return;
            }
        }
        unreachable;
    }

    const command = commandField(Current) orelse unreachable;
    const Union = commandUnion(command.type);
    if (comptime isOptionalCommand(command.type)) {
        if (@field(value.*, command.name)) |*selected| {
            return updateInSelectedVariant(
                Root,
                Union,
                allocator,
                selected,
                path,
                new_commands,
                active_commands,
                target,
                current,
                depth,
            );
        }
        unreachable;
    }
    return updateInSelectedVariant(
        Root,
        Union,
        allocator,
        &@field(value.*, command.name),
        path,
        new_commands,
        active_commands,
        target,
        current,
        depth,
    );
}

fn updateInSelectedVariant(
    comptime Root: type,
    comptime Union: type,
    allocator: std.mem.Allocator,
    selected: *Union,
    path: *const ActivePath(Root),
    new_commands: *NewCommands(Root),
    active_commands: *ActiveCommands,
    target: schema.CmdId,
    comptime current: schema.CmdId,
    comptime depth: usize,
) schema.Error!void {
    switch (selected.*) {
        inline else => |*payload, tag| {
            const child = comptime nodeIdForVariant(Root, current, @tagName(tag));
            if (path.ids[depth + 1] == child) {
                return updateInActiveCommand(
                    Root,
                    @TypeOf(payload.*),
                    allocator,
                    payload,
                    path,
                    new_commands,
                    active_commands,
                    target,
                    child,
                    depth + 1,
                );
            }
            unreachable;
        },
    }
}

fn commandHasVariant(
    comptime Command: type,
    command: Command,
    comptime Union: type,
    comptime variant_name: []const u8,
) bool {
    const tag = @field(std.meta.Tag(Union), variant_name);
    if (comptime isOptionalCommand(Command)) {
        if (command) |selected| return std.meta.activeTag(selected) == tag;
        return false;
    }
    return std.meta.activeTag(command) == tag;
}

fn activateInActiveCommand(
    comptime Root: type,
    comptime Current: type,
    value: *Current,
    path: *const ActivePath(Root),
    target: schema.CmdId,
    comptime current: schema.CmdId,
    comptime depth: usize,
) schema.Error!void {
    if (depth == path.depth) {
        std.debug.assert(current == path.ids[depth]);
        const command = commandField(Current) orelse unreachable;
        const Union = commandUnion(command.type);
        inline for (comptime unionFields(Union)) |variant| {
            const child = comptime nodeIdForVariant(Root, current, variant.name);
            if (target == child) {
                const selected = @unionInit(Union, variant.name, defaults(variant.type));
                @field(value.*, command.name) = selected;
                return;
            }
        }
        unreachable;
    }

    const command = commandField(Current) orelse unreachable;
    const Union = commandUnion(command.type);
    if (comptime isOptionalCommand(command.type)) {
        if (@field(value.*, command.name)) |*selected| {
            return activateInSelectedVariant(
                Root,
                Union,
                selected,
                path,
                target,
                current,
                depth,
            );
        }
        unreachable;
    }
    return activateInSelectedVariant(
        Root,
        Union,
        &@field(value.*, command.name),
        path,
        target,
        current,
        depth,
    );
}

fn activateInSelectedVariant(
    comptime Root: type,
    comptime Union: type,
    selected: *Union,
    path: *const ActivePath(Root),
    target: schema.CmdId,
    comptime current: schema.CmdId,
    comptime depth: usize,
) schema.Error!void {
    switch (selected.*) {
        inline else => |*payload, tag| {
            const child = comptime nodeIdForVariant(Root, current, @tagName(tag));
            if (path.ids[depth + 1] == child) {
                return activateInActiveCommand(
                    Root,
                    @TypeOf(payload.*),
                    payload,
                    path,
                    target,
                    child,
                    depth + 1,
                );
            }
            unreachable;
        },
    }
}

fn captureExternalInActiveCommand(
    comptime Root: type,
    comptime Current: type,
    value: *Current,
    context: *FillContext(Root),
    target: schema.CmdId,
    argv: schema.Argv,
    arg_index: u32,
    comptime current: schema.CmdId,
    comptime depth: usize,
) error{OutOfMemory}!void {
    if (current == target) {
        if (comptime Current != schema.ExternalCommand) unreachable;
        const index: usize = @intCast(arg_index);
        std.debug.assert(index < argv.len());
        for (argv.values[index..], 0..) |argument, argument_index| {
            appendList(
                []const []const u8,
                context.allocator,
                &value.args,
                structFields(schema.ExternalCommand)[0].default_value_ptr,
                context.active_lists,
                null,
                argument,
                argument_index == 0,
                null,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidValue => unreachable,
            };
        }
        return;
    }

    std.debug.assert(depth < context.path.depth);
    const command = commandField(Current) orelse unreachable;
    const Union = commandUnion(command.type);
    if (comptime isOptionalCommand(command.type)) {
        if (@field(value.*, command.name)) |*selected| {
            return captureExternalInSelectedVariant(
                Root,
                Union,
                selected,
                context,
                target,
                argv,
                arg_index,
                current,
                depth,
            );
        }
        unreachable;
    }
    return captureExternalInSelectedVariant(
        Root,
        Union,
        &@field(value.*, command.name),
        context,
        target,
        argv,
        arg_index,
        current,
        depth,
    );
}

fn captureExternalInSelectedVariant(
    comptime Root: type,
    comptime Union: type,
    selected: *Union,
    context: *FillContext(Root),
    target: schema.CmdId,
    argv: schema.Argv,
    arg_index: u32,
    comptime current: schema.CmdId,
    comptime depth: usize,
) error{OutOfMemory}!void {
    switch (selected.*) {
        inline else => |*payload, tag| {
            const child = comptime nodeIdForVariant(Root, current, @tagName(tag));
            if (context.path.ids[depth + 1] == child) {
                return captureExternalInActiveCommand(
                    Root,
                    @TypeOf(payload.*),
                    payload,
                    context,
                    target,
                    argv,
                    arg_index,
                    child,
                    depth + 1,
                );
            }
            unreachable;
        },
    }
}

fn bindField(
    comptime T: type,
    allocator: std.mem.Allocator,
    slot: *T,
    default_value_ptr: ?*const anyopaque,
    active_lists: *ActiveLists,
    id: schema.FlagId,
    text: []const u8,
    negated: bool,
    is_flag: bool,
    is_count: bool,
    replace_list: bool,
    list_max: ?u32,
) (ConversionError || error{OutOfMemory})!void {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            var parsed: optional.child = undefined;
            try bindScalar(optional.child, &parsed, text, negated, is_flag, is_count);
            slot.* = parsed;
        },
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.is_const and pointer.child != u8) {
                return appendList(
                    T,
                    allocator,
                    slot,
                    default_value_ptr,
                    active_lists,
                    id,
                    text,
                    replace_list,
                    list_max,
                );
            }
            try bindScalar(T, slot, text, negated, is_flag, is_count);
        },
        else => try bindScalar(T, slot, text, negated, is_flag, is_count),
    }
}

fn bindScalar(
    comptime T: type,
    slot: *T,
    text: []const u8,
    negated: bool,
    is_flag: bool,
    is_count: bool,
) ConversionError!void {
    switch (@typeInfo(T)) {
        .bool => {
            if (is_flag) {
                slot.* = !negated;
                return;
            }
            if (std.mem.eql(u8, text, "true")) {
                slot.* = true;
                return;
            }
            if (std.mem.eql(u8, text, "false")) {
                slot.* = false;
                return;
            }
            return error.InvalidValue;
        },
        .int => {
            if (is_count) {
                const maximum = std.math.maxInt(T);
                if (slot.* != maximum) slot.* += 1;
                return;
            }
            if (std.mem.indexOfScalar(u8, text, '_') != null) return error.InvalidValue;
            slot.* = std.fmt.parseInt(T, text, 10) catch return error.InvalidValue;
        },
        .float => {
            const number = std.fmt.parseFloat(T, text) catch return error.InvalidValue;
            if (!std.math.isFinite(number)) return error.InvalidValue;
            slot.* = number;
        },
        .@"enum" => slot.* = enumFromKebab(T, text) orelse return error.InvalidValue,
        .pointer => |pointer| {
            if (pointer.size != .slice or !pointer.is_const or pointer.child != u8) {
                return error.InvalidValue;
            }
            slot.* = text;
        },
        else => {
            if (hasParseArg(T)) {
                slot.* = T.parseArg(text) catch return error.InvalidValue;
                return;
            }
            return error.InvalidValue;
        },
    }
}

fn appendList(
    comptime T: type,
    allocator: std.mem.Allocator,
    slot: *T,
    default_value_ptr: ?*const anyopaque,
    active_lists: *ActiveLists,
    id: ?schema.FlagId,
    text: []const u8,
    replace_list: bool,
    max: ?u32,
) (ConversionError || error{OutOfMemory})!void {
    const pointer = @typeInfo(T).pointer;
    const Element = pointer.child;
    const list = try active_lists.getOrCreate(
        allocator,
        id,
        T,
        slot,
        isDefaultList(T, slot.*, default_value_ptr),
    );
    if (replace_list) list.len = 0;
    if (max) |limit| {
        if (list.len >= limit) return error.InvalidValue;
    }

    if (list.len == list.capacity) {
        const values = activeValues(Element, list);
        const grown = try allocator.realloc(values, list.capacity * 2);
        list.values = @ptrCast(grown.ptr);
        list.capacity = grown.len;
    }

    const values = activeValues(Element, list);
    try bindScalar(Element, &values[list.len], text, false, false, false);
    list.len += 1;
    slot.* = values[0..list.len];
}

const ActiveList = struct {
    id: ?schema.FlagId,
    slot: *anyopaque,
    original_values: ?*const anyopaque = null,
    original_len: usize = 0,
    original_owned: bool = false,
    values: ?*anyopaque = null,
    len: usize = 0,
    capacity: usize = 0,
    finish: *const fn (std.mem.Allocator, *ActiveList) error{OutOfMemory}!void,
    commit: *const fn (std.mem.Allocator, *ActiveList) void,
    restore: *const fn (*ActiveList) void,
    release: *const fn (std.mem.Allocator, *ActiveList) void,
};

const ActiveLists = struct {
    entries: std.ArrayList(ActiveList) = .empty,

    fn deinit(self: *ActiveLists, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    fn getOrCreate(
        self: *ActiveLists,
        allocator: std.mem.Allocator,
        id: ?schema.FlagId,
        comptime T: type,
        slot: *T,
        original_is_default: bool,
    ) error{OutOfMemory}!*ActiveList {
        const Element = @typeInfo(T).pointer.child;
        const opaque_slot: *anyopaque = @ptrCast(slot);
        for (self.entries.items) |*entry| {
            if (entry.id == id) {
                std.debug.assert(entry.values != null);
                std.debug.assert(entry.slot == opaque_slot);
                return entry;
            }
        }

        const values = try allocator.alloc(Element, 4);
        errdefer allocator.free(values);
        try self.entries.append(allocator, .{
            .id = id,
            .slot = opaque_slot,
            .original_values = if (slot.*.len == 0) null else @ptrCast(slot.*.ptr),
            .original_len = slot.*.len,
            .original_owned = slot.*.len > 0 and !original_is_default,
            .values = @ptrCast(values.ptr),
            .capacity = values.len,
            .finish = finishTypedList(T),
            .commit = commitTypedList(T),
            .restore = restoreTypedList(T),
            .release = releaseTypedList(T),
        });
        return &self.entries.items[self.entries.items.len - 1];
    }
};

const ActiveCommand = struct {
    slot: *anyopaque,
    snapshot: *anyopaque,
    restore: *const fn (*ActiveCommand) void,
    discard: *const fn (std.mem.Allocator, *ActiveCommand) void,
    commit: *const fn (std.mem.Allocator, *ActiveCommand) void,
};

const ActiveCommands = struct {
    entries: std.ArrayList(ActiveCommand) = .empty,

    fn deinit(self: *ActiveCommands, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.discard(allocator, entry);
        self.entries.deinit(allocator);
    }

    fn commit(self: *ActiveCommands, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.commit(allocator, entry);
        self.entries.deinit(allocator);
        self.entries = .empty;
    }

    fn capture(
        self: *ActiveCommands,
        allocator: std.mem.Allocator,
        comptime T: type,
        slot: *T,
    ) error{OutOfMemory}!void {
        const opaque_slot: *anyopaque = @ptrCast(slot);
        for (self.entries.items) |entry| {
            if (entry.slot == opaque_slot) return;
        }

        const snapshot = try allocator.create(T);
        errdefer allocator.destroy(snapshot);
        snapshot.* = slot.*;
        try self.entries.append(allocator, .{
            .slot = opaque_slot,
            .snapshot = @ptrCast(snapshot),
            .restore = restoreTypedCommand(T),
            .discard = discardTypedCommand(T),
            .commit = commitTypedCommand(T),
        });
    }
};

fn restoreActiveCommands(allocator: std.mem.Allocator, active_commands: *ActiveCommands) void {
    for (active_commands.entries.items) |*entry| entry.restore(entry);
    active_commands.deinit(allocator);
    active_commands.entries = .empty;
}

fn restoreTypedCommand(comptime T: type) *const fn (*ActiveCommand) void {
    return struct {
        fn restore(command: *ActiveCommand) void {
            const slot: *T = @ptrCast(@alignCast(command.slot));
            const snapshot: *T = @ptrCast(@alignCast(command.snapshot));
            slot.* = snapshot.*;
        }
    }.restore;
}

fn discardTypedCommand(comptime T: type) *const fn (std.mem.Allocator, *ActiveCommand) void {
    return struct {
        fn discard(allocator: std.mem.Allocator, command: *ActiveCommand) void {
            const snapshot: *T = @ptrCast(@alignCast(command.snapshot));
            allocator.destroy(snapshot);
        }
    }.discard;
}

fn commitTypedCommand(comptime T: type) *const fn (std.mem.Allocator, *ActiveCommand) void {
    return struct {
        fn commit(allocator: std.mem.Allocator, command: *ActiveCommand) void {
            const snapshot: *T = @ptrCast(@alignCast(command.snapshot));
            releaseOwnedLists(T, allocator, snapshot);
            allocator.destroy(snapshot);
        }
    }.commit;
}

fn activeValues(comptime Element: type, list: *const ActiveList) []Element {
    std.debug.assert(list.values != null);
    std.debug.assert(list.capacity > 0);
    const pointer: [*]Element = @ptrCast(@alignCast(list.values.?));
    return pointer[0..list.capacity];
}

fn finishActiveLists(
    allocator: std.mem.Allocator,
    active_lists: *ActiveLists,
) error{OutOfMemory}!void {
    for (active_lists.entries.items) |*list| {
        try list.finish(allocator, list);
    }
}

fn releaseActiveLists(allocator: std.mem.Allocator, active_lists: *ActiveLists) void {
    for (active_lists.entries.items) |*list| {
        list.release(allocator, list);
    }
}

fn commitActiveLists(allocator: std.mem.Allocator, active_lists: *ActiveLists) void {
    for (active_lists.entries.items) |*list| {
        list.commit(allocator, list);
    }
}

fn finishTypedList(
    comptime T: type,
) *const fn (std.mem.Allocator, *ActiveList) error{OutOfMemory}!void {
    return struct {
        fn finish(allocator: std.mem.Allocator, list: *ActiveList) error{OutOfMemory}!void {
            const Element = @typeInfo(T).pointer.child;
            const values = activeValues(Element, list);
            if (list.len == 0) {
                allocator.free(values);
                list.values = null;
                list.capacity = 0;
                return;
            }
            const exact = try allocator.realloc(values, list.len);
            list.values = @ptrCast(exact.ptr);
            list.capacity = exact.len;
            const slot: *T = @ptrCast(@alignCast(list.slot));
            slot.* = exact;
        }
    }.finish;
}

fn releaseTypedList(comptime T: type) *const fn (std.mem.Allocator, *ActiveList) void {
    return struct {
        fn release(allocator: std.mem.Allocator, list: *ActiveList) void {
            if (list.values == null) return;
            const Element = @typeInfo(T).pointer.child;
            list.restore(list);
            allocator.free(activeValues(Element, list));
            list.values = null;
            list.capacity = 0;
        }
    }.release;
}

fn commitTypedList(comptime T: type) *const fn (std.mem.Allocator, *ActiveList) void {
    return struct {
        fn commit(allocator: std.mem.Allocator, list: *ActiveList) void {
            if (!list.original_owned) return;
            std.debug.assert(list.original_values != null);
            std.debug.assert(list.original_len > 0);
            const Element = @typeInfo(T).pointer.child;
            const pointer: [*]const Element = @ptrCast(@alignCast(list.original_values.?));
            allocator.free(pointer[0..list.original_len]);
            list.original_values = null;
            list.original_len = 0;
            list.original_owned = false;
        }
    }.commit;
}

fn restoreTypedList(comptime T: type) *const fn (*ActiveList) void {
    return struct {
        fn restore(list: *ActiveList) void {
            const Element = @typeInfo(T).pointer.child;
            const slot: *T = @ptrCast(@alignCast(list.slot));
            if (list.original_values) |values| {
                const pointer: [*]const Element = @ptrCast(@alignCast(values));
                slot.* = pointer[0..list.original_len];
                return;
            }
            slot.* = &.{};
        }
    }.restore;
}

fn isDefaultList(
    comptime T: type,
    values: T,
    default_value_ptr: ?*const anyopaque,
) bool {
    const default_value = default_value_ptr orelse return false;
    const default_values: *const T = @ptrCast(@alignCast(default_value));
    return values.ptr == default_values.*.ptr and values.len == default_values.*.len;
}

fn releaseOwnedLists(comptime T: type, allocator: std.mem.Allocator, value: *const T) void {
    switch (@typeInfo(T)) {
        .@"struct" => inline for (comptime structFields(T)) |field| {
            if (comptime isList(field.type)) {
                releaseOwnedList(
                    field.type,
                    allocator,
                    @field(value.*, field.name),
                    field.default_value_ptr,
                );
                continue;
            }
            if (comptime isCommandField(field.type)) {
                releaseOwnedLists(field.type, allocator, &@field(value.*, field.name));
            }
        },
        .@"union" => releaseOwnedVariantLists(T, allocator, value),
        .optional => |optional| {
            if (value.*) |*selected| releaseOwnedVariantLists(optional.child, allocator, selected);
        },
        else => unreachable,
    }
}

fn releaseOwnedList(
    comptime T: type,
    allocator: std.mem.Allocator,
    values: T,
    default_value_ptr: ?*const anyopaque,
) void {
    if (values.len == 0) return;
    if (isDefaultList(T, values, default_value_ptr)) return;
    allocator.free(values);
}

fn releaseOwnedVariantLists(
    comptime Union: type,
    allocator: std.mem.Allocator,
    selected: *const Union,
) void {
    switch (selected.*) {
        inline else => |*payload| releaseOwnedLists(@TypeOf(payload.*), allocator, payload),
    }
}

fn isList(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and pointer.is_const and pointer.child != u8,
        else => false,
    };
}

fn finishActivePath(
    comptime Root: type,
    comptime Current: type,
    value: *const Current,
    path: *const ActivePath(Root),
    seen: Seen(Root),
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
    comptime current: schema.CmdId,
    comptime depth: usize,
) schema.Error!void {
    if (comptime Current == schema.ExternalCommand) return;
    try checkListMinimums(Root, Current, value, diagnostic, argv, current);
    try checkRelationships(Root, Current, seen, diagnostic, argv, current);
    if (@hasDecl(Current, "validate")) try Current.validate(value, diagnostic);

    if (depth == path.depth) return;
    const command = commandField(Current) orelse unreachable;
    const Union = commandUnion(command.type);
    const selected = path.ids[depth + 1];
    if (comptime isOptionalCommand(command.type)) {
        if (@field(value.*, command.name)) |*active| {
            return finishActivePathInVariant(
                Root,
                Union,
                active,
                path,
                seen,
                diagnostic,
                argv,
                current,
                depth,
                selected,
            );
        }
        unreachable;
    }
    return finishActivePathInVariant(
        Root,
        Union,
        &@field(value.*, command.name),
        path,
        seen,
        diagnostic,
        argv,
        current,
        depth,
        selected,
    );
}

fn finishActivePathInVariant(
    comptime Root: type,
    comptime Union: type,
    active: *const Union,
    path: *const ActivePath(Root),
    seen: Seen(Root),
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
    comptime current: schema.CmdId,
    comptime depth: usize,
    selected: schema.CmdId,
) schema.Error!void {
    switch (active.*) {
        inline else => |*payload, tag| {
            const child = comptime nodeIdForVariant(Root, current, @tagName(tag));
            std.debug.assert(child == selected);
            return finishActivePath(
                Root,
                @TypeOf(payload.*),
                payload,
                path,
                seen,
                diagnostic,
                argv,
                child,
                depth + 1,
            );
        },
    }
}

fn checkListMinimums(
    comptime Root: type,
    comptime Current: type,
    value: *const Current,
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
    comptime current: schema.CmdId,
) schema.Error!void {
    const meta = comptime commandMeta(Current);
    inline for (comptime structFields(Current)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const options = comptime @field(meta.fields, field.name);
        if (comptime options.min) |min| {
            const values = @field(value.*, field.name);
            if (values.len < min) {
                diagnostic.* = .{
                    .kind = .missing_required,
                    .arg_index = @intCast(argv.len()),
                    .command = current,
                    .binding = bindingId(Root, current, field.name),
                };
                return error.ParseFailed;
            }
        }
    }
}

fn checkRelationships(
    comptime Root: type,
    comptime Current: type,
    seen: Seen(Root),
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
    comptime current: schema.CmdId,
) schema.Error!void {
    const meta = comptime commandMeta(Current);
    inline for (comptime structFields(Current)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const id = bindingId(Root, current, field.name);
        if (seen.isSet(id)) {
            const options = comptime @field(meta.fields, field.name);
            inline for (options.conflicts) |target| {
                const target_name = @tagName(target);
                if (seen.isSet(bindingId(Root, current, target_name))) {
                    diagnostic.* = .{
                        .kind = .conflict,
                        .arg_index = @intCast(argv.len()),
                        .command = current,
                        .binding = id,
                        .expected = target_name,
                    };
                    return error.ParseFailed;
                }
            }
            inline for (options.requires) |target| {
                const target_name = @tagName(target);
                if (!seen.isSet(bindingId(Root, current, target_name))) {
                    diagnostic.* = .{
                        .kind = .missing_requirement,
                        .arg_index = @intCast(argv.len()),
                        .command = current,
                        .binding = id,
                        .expected = target_name,
                    };
                    return error.ParseFailed;
                }
            }
        }
    }
}

fn checkRequired(
    comptime T: type,
    path: *const ActivePath(T),
    seen: Seen(T),
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
) schema.Error!void {
    return checkRequiredInCommand(T, T, path, seen, diagnostic, argv, 0, 0);
}

fn NewCommands(comptime T: type) type {
    return std.StaticBitSet(compile.Compiled(T).nodes.len);
}

fn checkNewRequired(
    comptime T: type,
    value: *const T,
    path: *const ActivePath(T),
    seen: Seen(T),
    new_commands: NewCommands(T),
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
) schema.Error!void {
    return checkNewRequiredInCommand(T, T, value, path, seen, new_commands, diagnostic, argv, 0, 0);
}

fn checkNewRequiredInCommand(
    comptime Root: type,
    comptime Current: type,
    value: *const Current,
    path: *const ActivePath(Root),
    seen: Seen(Root),
    new_commands: NewCommands(Root),
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
    comptime current: schema.CmdId,
    comptime depth: usize,
) schema.Error!void {
    if (comptime Current == schema.ExternalCommand) return;
    if (new_commands.isSet(current)) {
        inline for (comptime structFields(Current)) |field| {
            if (comptime !isCommandField(field.type)) {
                if (field.defaultValue() == null) {
                    if (!seen.isSet(bindingId(Root, current, field.name))) {
                        diagnostic.* = .{
                            .kind = .missing_required,
                            .arg_index = @intCast(argv.len()),
                            .command = current,
                            .binding = bindingId(Root, current, field.name),
                        };
                        return error.ParseFailed;
                    }
                }
            }
        }
    }

    const command = commandField(Current) orelse return;
    if (depth == path.depth) {
        if (new_commands.isSet(current) and !isOptionalCommand(command.type)) {
            diagnostic.* = .{
                .kind = .missing_subcommand,
                .arg_index = @intCast(argv.len()),
                .command = current,
            };
            return error.ParseFailed;
        }
        return;
    }

    const Union = commandUnion(command.type);
    const selected = path.ids[depth + 1];
    if (comptime isOptionalCommand(command.type)) {
        if (@field(value.*, command.name)) |*active| {
            return checkNewRequiredInVariant(
                Root,
                Union,
                active,
                path,
                seen,
                new_commands,
                diagnostic,
                argv,
                current,
                depth,
                selected,
            );
        }
        unreachable;
    }
    return checkNewRequiredInVariant(
        Root,
        Union,
        &@field(value.*, command.name),
        path,
        seen,
        new_commands,
        diagnostic,
        argv,
        current,
        depth,
        selected,
    );
}

fn checkNewRequiredInVariant(
    comptime Root: type,
    comptime Union: type,
    active: *const Union,
    path: *const ActivePath(Root),
    seen: Seen(Root),
    new_commands: NewCommands(Root),
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
    comptime current: schema.CmdId,
    comptime depth: usize,
    selected: schema.CmdId,
) schema.Error!void {
    switch (active.*) {
        inline else => |*payload, tag| {
            const child = comptime nodeIdForVariant(Root, current, @tagName(tag));
            std.debug.assert(child == selected);
            return checkNewRequiredInCommand(
                Root,
                @TypeOf(payload.*),
                payload,
                path,
                seen,
                new_commands,
                diagnostic,
                argv,
                child,
                depth + 1,
            );
        },
    }
}

fn checkRequiredInCommand(
    comptime Root: type,
    comptime Current: type,
    path: *const ActivePath(Root),
    seen: Seen(Root),
    diagnostic: *schema.Diagnostic,
    argv: schema.Argv,
    comptime current: schema.CmdId,
    comptime depth: usize,
) schema.Error!void {
    if (comptime Current == schema.ExternalCommand) return;
    inline for (comptime structFields(Current)) |field| {
        if (comptime isCommandField(field.type)) continue;
        const id = bindingId(Root, current, field.name);
        if (field.defaultValue() == null and !seen.isSet(id)) {
            diagnostic.* = .{
                .kind = .missing_required,
                .arg_index = @intCast(argv.len()),
                .command = current,
                .binding = id,
            };
            return error.ParseFailed;
        }
    }

    const command = commandField(Current) orelse return;
    if (depth == path.depth) {
        if (!isOptionalCommand(command.type)) {
            diagnostic.* = .{
                .kind = .missing_subcommand,
                .arg_index = @intCast(argv.len()),
                .command = current,
            };
            return error.ParseFailed;
        }
        return;
    }

    const Union = commandUnion(command.type);
    const selected = path.ids[depth + 1];
    inline for (comptime unionFields(Union)) |variant| {
        const child = comptime nodeIdForVariant(Root, current, variant.name);
        if (selected == child) {
            return checkRequiredInCommand(
                Root,
                variant.type,
                path,
                seen,
                diagnostic,
                argv,
                child,
                depth + 1,
            );
        }
    }
    unreachable;
}

fn isCountField(comptime T: type, comptime field_name: []const u8) bool {
    const compiled = compile.Compiled(T);
    inline for (compiled.bindings, 0..) |binding, index| {
        if (binding.command != compiled.table.root) continue;
        if (comptime std.mem.eql(u8, binding.field, field_name)) {
            return compiled.table.flags[index].kind == .count;
        }
    }
    return false;
}

fn bindingId(
    comptime Root: type,
    comptime command: schema.CmdId,
    comptime field_name: []const u8,
) schema.FlagId {
    inline for (compile.Compiled(Root).bindings, 0..) |binding, index| {
        if (binding.command != command) continue;
        if (comptime std.mem.eql(u8, binding.field, field_name)) return @intCast(index);
    }
    @compileError("zlap binding field is missing from the compiled tree");
}

fn parseArgExpectedForBinding(comptime T: type, id: schema.FlagId) ?[]const u8 {
    inline for (compile.Compiled(T).bindings, 0..) |binding, index| {
        if (id == index) return binding.parse_arg_expected;
    }
    unreachable;
}

fn nodeIdForVariant(
    comptime Root: type,
    comptime parent: schema.CmdId,
    comptime variant_name: []const u8,
) schema.CmdId {
    inline for (compile.Compiled(Root).nodes, 0..) |node, index| {
        if (node.parent) |node_parent| {
            if (node_parent != parent) continue;
            if (node.variant) |node_variant| {
                if (comptime std.mem.eql(u8, node_variant, variant_name)) return @intCast(index);
            }
        }
    }
    @compileError("zlap command variant is missing from the compiled tree");
}

fn commandField(comptime T: type) ?std.builtin.Type.StructField {
    return declaration.commandField(T);
}

fn commandMeta(comptime T: type) schema.Meta(T) {
    return declaration.commandMeta(T);
}

fn isCommandField(comptime T: type) bool {
    return declaration.isCommandField(T);
}

fn isOptionalCommand(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn commandUnion(comptime T: type) type {
    return declaration.commandUnion(T) orelse
        @compileError("zlap command fields must be tagged unions");
}

fn unionFields(comptime T: type) []const std.builtin.Type.UnionField {
    return declaration.unionFields(T);
}

fn invalidValueDiagnostic(
    command: schema.CmdId,
    binding: schema.FlagId,
    token: []const u8,
    arg_index: u32,
    expected: ?[]const u8,
) schema.Diagnostic {
    return .{
        .kind = .invalid_value,
        .arg_index = arg_index,
        .command = command,
        .binding = binding,
        .token = token,
        .expected = expected,
    };
}

fn enumFromKebab(comptime T: type, text: []const u8) ?T {
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (kebabCaseEql(field.name, text)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

fn hasParseArg(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "parseArg"),
        .@"union" => @hasDecl(T, "parseArg"),
        .@"enum" => @hasDecl(T, "parseArg"),
        .@"opaque" => @hasDecl(T, "parseArg"),
        else => false,
    };
}

fn kebabCaseEql(name: []const u8, text: []const u8) bool {
    var text_index: usize = 0;
    for (name, 0..) |byte, name_index| {
        if (byte == '_') {
            if (text_index == text.len or text[text_index] != '-') return false;
            text_index += 1;
            continue;
        }
        if (std.ascii.isUpper(byte) and name_index != 0 and name[name_index - 1] != '_') {
            if (text_index == text.len or text[text_index] != '-') return false;
            text_index += 1;
        }
        if (text_index == text.len or text[text_index] != std.ascii.toLower(byte)) return false;
        text_index += 1;
    }
    return text_index == text.len;
}

fn structFields(comptime T: type) []const std.builtin.Type.StructField {
    return declaration.structFields(T);
}

fn ActivePath(comptime T: type) type {
    return struct {
        const Self = @This();

        ids: [compile.Compiled(T).max_depth + 1]schema.CmdId = undefined,
        depth: usize = 0,

        fn init() Self {
            var path: Self = .{};
            path.ids[0] = compile.Compiled(T).table.root;
            return path;
        }
    };
}

fn Seen(comptime T: type) type {
    @setEvalBranchQuota(1_000_000);
    return std.StaticBitSet(compile.Compiled(T).bindings.len);
}

test "parseFrom binds a bare struct" {
    const Command = struct {
        dry_run: bool = false,
        output: []const u8 = "stdout",
    };
    const argv: schema.Argv = .{ .values = &.{ "--dry-run", "--output", "log.txt" } };
    const parsed = try parseFrom(Command, std.testing.allocator, argv, .{});
    try std.testing.expect(parsed.dry_run);
    try std.testing.expectEqualStrings("log.txt", parsed.output);
}

test "parseFrom reports parser syntax and required fields" {
    const Command = struct {
        input: []const u8,
    };
    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{"--unknown"} },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.unknown_flag, diagnostic.kind);

    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(Command, std.testing.allocator, .{}, .{ .diagnostic = &diagnostic }),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.missing_required, diagnostic.kind);
    try std.testing.expectEqual(@as(?schema.FlagId, 0), diagnostic.binding);
}

test "parseFrom validates scalar values" {
    const Format = enum { json_output, plain };
    const Command = struct {
        integer: i8 = 0,
        ratio: f32 = 0,
        format: Format = .plain,
    };
    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{
                "--integer",
                "1_0",
                "--ratio",
                "nan",
                "--format",
                "json-output",
            } },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.invalid_value, diagnostic.kind);
    try std.testing.expectEqualStrings("1_0", diagnostic.token);
}

test "parseFrom saturates counts and collects typed lists" {
    const Format = enum { json_output, plain };
    const Command = struct {
        verbose: u2 = 0,
        numbers: []const i16 = &.{},
        formats: []const Format = &.{},
        names: []const []const u8 = &.{},

        pub const meta: schema.Meta(@This()) = .{
            .fields = .{
                .verbose = .{ .count = true, .short = 'v' },
                .numbers = .{ .short = 'n' },
                .formats = .{ .short = 'f' },
                .names = .{ .short = 'N' },
            },
        };
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try parseFrom(Command, arena.allocator(), .{ .values = &.{
        "-vvvvv",
        "-n",
        "-2",
        "--numbers=4",
        "-fjson-output",
        "--formats",
        "plain",
        "-Nfirst",
        "--names",
        "second",
    } }, .{});
    try std.testing.expectEqual(@as(u2, 3), parsed.verbose);
    try std.testing.expectEqualSlices(i16, &.{ -2, 4 }, parsed.numbers);
    try std.testing.expectEqualSlices(Format, &.{ .json_output, .plain }, parsed.formats);
    try std.testing.expectEqual(@as(usize, 2), parsed.names.len);
    try std.testing.expectEqualStrings("first", parsed.names[0]);
    try std.testing.expectEqualStrings("second", parsed.names[1]);
}

test "parseFrom initializes a required count before incrementing it" {
    const Command = struct {
        verbose: u8,

        pub const meta: schema.Meta(@This()) = .{
            .fields = .{ .verbose = .{ .count = true, .short = 'v' } },
        };
    };
    const parsed = try parseFrom(
        Command,
        std.testing.allocator,
        .{ .values = &.{"-vv"} },
        .{},
    );
    try std.testing.expectEqual(@as(u8, 2), parsed.verbose);
}

test "parseFrom list storage has an allocator cleanup contract" {
    const Command = struct {
        values: []const u16 = &.{},
    };
    const parsed = try parseFrom(
        Command,
        std.testing.allocator,
        .{ .values = &.{
            "--values=1",
            "--values=2",
            "--values=3",
            "--values=4",
            "--values=5",
        } },
        .{},
    );
    defer std.testing.allocator.free(parsed.values);

    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4, 5 }, parsed.values);

    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{ "--values=1", "--unknown" } },
            .{},
        ),
    );
}

test "fill releases active lists after failure" {
    const Command = struct {
        values: []const u16 = &.{9},
    };
    var value = defaults(Command);

    try std.testing.expectError(
        error.ParseFailed,
        fill(
            Command,
            std.testing.allocator,
            &value,
            .{ .values = &.{ "--values=1", "--unknown" } },
            .{},
        ),
    );
    try std.testing.expectEqualSlices(u16, &.{9}, value.values);
}

test "actions override an earlier conversion error" {
    const Command = struct {
        value: u8 = 0,

        pub const meta: schema.Meta(@This()) = .{ .version = "1.0.0" };
    };
    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.HelpRequested,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{ "--value", "bad", "--help" } },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.help, diagnostic.kind);

    try std.testing.expectError(
        error.VersionRequested,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{"--version"} },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.version, diagnostic.kind);
}

test "an earlier conversion diagnostic wins over a later syntax error" {
    const Command = struct {
        value: u8 = 0,
    };
    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{ "--value=bad", "--unknown" } },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.invalid_value, diagnostic.kind);
    try std.testing.expectEqualStrings("bad", diagnostic.token);
}

test "parseFrom applies environment fallback after argv on the active path" {
    const First = struct {
        value: []const u8 = "",

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .value = .{ .env = "ZLAP_FIRST_VALUE" },
        } };
    };
    const Second = struct {
        number: u8 = 0,

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .number = .{ .env = "ZLAP_SECOND_NUMBER" },
        } };
    };
    const Commands = union(enum) {
        first: First,
        second: Second,
    };
    const App = struct {
        address: []const u8 = "",
        command: Commands,

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .address = .{ .env = "ZLAP_ADDRESS" },
        } };
    };

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZLAP_ADDRESS", "from-env");
    try env.put("ZLAP_FIRST_VALUE", "first-env");
    try env.put("ZLAP_SECOND_NUMBER", "not-a-number");

    const parsed = try parseFrom(App, std.testing.allocator, .{ .values = &.{
        "--address=from-argv",
        "first",
    } }, .{ .env = .{ .map = &env } });
    try std.testing.expectEqualStrings("from-argv", parsed.address);
    switch (parsed.command) {
        .first => |first| try std.testing.expectEqualStrings("first-env", first.value),
        .second => unreachable,
    }
}

test "parseFrom enforces list bounds for named and positional lists" {
    const Named = struct {
        values: []const u16 = &.{},

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .values = .{ .min = 1, .max = 2 },
        } };
    };
    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(Named, std.testing.allocator, .{}, .{ .diagnostic = &diagnostic }),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.missing_required, diagnostic.kind);

    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(Named, std.testing.allocator, .{ .values = &.{
            "--values=1",
            "--values=2",
            "--values=3",
        } }, .{ .diagnostic = &diagnostic }),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.invalid_value, diagnostic.kind);

    const Positional = struct {
        inputs: []const []const u8 = &.{},
        output: []const u8 = "",

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .inputs = .{ .positional = true, .min = 2, .max = 2 },
            .output = .{ .positional = true },
        } };
    };
    const parsed = try parseFrom(
        Positional,
        std.testing.allocator,
        .{ .values = &.{ "one", "two", "result" } },
        .{},
    );
    defer std.testing.allocator.free(parsed.inputs);
    try std.testing.expectEqual(@as(usize, 2), parsed.inputs.len);
    try std.testing.expectEqualStrings("result", parsed.output);
}

test "parseFrom enforces active command relationships and validation hooks" {
    const Command = struct {
        quiet: bool = false,
        verbose: bool = false,
        output: bool = false,

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .quiet = .{ .conflicts = &.{.verbose} },
            .output = .{ .requires = &.{.verbose} },
        } };
    };
    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{ "--quiet", "--verbose" } },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.conflict, diagnostic.kind);
    try std.testing.expectEqualStrings("verbose", diagnostic.expected.?);

    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{"--output"} },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.missing_requirement, diagnostic.kind);
    try std.testing.expectEqualStrings("verbose", diagnostic.expected.?);

    const Validated = struct {
        enabled: bool = false,

        pub fn validate(self: *const @This(), diag: *schema.Diagnostic) error{ParseFailed}!void {
            if (!self.enabled) return;
            diag.* = .{ .kind = .invalid_value };
            return error.ParseFailed;
        }
    };
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            Validated,
            std.testing.allocator,
            .{ .values = &.{"--enabled"} },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.invalid_value, diagnostic.kind);
}

test "parseFrom accepts an empty command" {
    const Empty = struct {};
    const parsed = try parseFrom(Empty, std.testing.allocator, .{}, .{});
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(parsed)));
}

test "parseFrom binds nested aliases, reused payloads, and inherited globals" {
    const Reused = struct {
        name: []const u8,
    };
    const Targets = union(enum) {
        publish: Reused,
        inspect: Reused,

        pub const meta: schema.VariantsMeta(@This()) = .{ .variants = .{
            .publish = .{ .aliases = &.{"p"} },
            .inspect = .{},
        } };
    };
    const Release = struct {
        command: ?Targets = null,
    };
    const Commands = union(enum) {
        release: Release,

        pub const meta: schema.VariantsMeta(@This()) = .{ .variants = .{
            .release = .{ .aliases = &.{"r"} },
        } };
    };
    const App = struct {
        verbose: u8 = 0,
        command: ?Commands = null,

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .verbose = .{ .count = true, .global = true, .short = 'v' },
        } };
    };

    const parsed = try parseFrom(App, std.testing.allocator, .{ .values = &.{
        "-v",
        "r",
        "--verbose",
        "p",
        "--name",
        "release.tar",
    } }, .{});
    try std.testing.expectEqual(@as(u8, 2), parsed.verbose);
    const release = parsed.command orelse unreachable;
    switch (release) {
        .release => |payload| {
            const target = payload.command orelse unreachable;
            switch (target) {
                .publish => |publish| {
                    try std.testing.expectEqualStrings("release.tar", publish.name);
                },
                .inspect => unreachable,
            }
        },
    }
}

test "parseFrom ignores inactive required sibling fields" {
    const First = struct { input: []const u8 };
    const Second = struct { output: []const u8 };
    const Commands = union(enum) {
        first: First,
        second: Second,
    };
    const App = struct { command: ?Commands = null };

    const parsed = try parseFrom(
        App,
        std.testing.allocator,
        .{ .values = &.{ "first", "--input", "source" } },
        .{},
    );
    const command = parsed.command orelse unreachable;
    switch (command) {
        .first => |first| try std.testing.expectEqualStrings("source", first.input),
        .second => unreachable,
    }
}

test "parseFrom reports a missing required subcommand" {
    const Commands = union(enum) {
        run: struct {},
    };
    const App = struct { command: Commands };
    var diagnostic: schema.Diagnostic = .{};

    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(App, std.testing.allocator, .{}, .{ .diagnostic = &diagnostic }),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.missing_subcommand, diagnostic.kind);
    try std.testing.expectEqual(@as(schema.CmdId, 0), diagnostic.command);
}

test "parseFrom binds optional and custom scalar fields on the active path" {
    const Duration = struct {
        seconds: u16,

        pub const parse_arg_expected = "a duration in seconds";

        pub fn parseArg(text: []const u8) error{InvalidValue}!@This() {
            return .{ .seconds = std.fmt.parseInt(u16, text, 10) catch return error.InvalidValue };
        }
    };
    const Child = struct {
        timeout: ?Duration = null,
        retries: ?u8 = null,
    };
    const Commands = union(enum) { run: Child };
    const App = struct {
        delay: ?Duration = null,
        command: ?Commands = null,
    };

    const empty = try parseFrom(App, std.testing.allocator, .{}, .{});
    try std.testing.expect(empty.delay == null);
    try std.testing.expect(empty.command == null);

    const parsed = try parseFrom(
        App,
        std.testing.allocator,
        .{ .values = &.{ "--delay", "5", "run", "--timeout=12", "--retries", "3" } },
        .{},
    );
    try std.testing.expectEqual(@as(?Duration, .{ .seconds = 5 }), parsed.delay);
    const command = parsed.command orelse unreachable;
    switch (command) {
        .run => |child| {
            try std.testing.expectEqual(@as(?Duration, .{ .seconds = 12 }), child.timeout);
            try std.testing.expectEqual(@as(?u8, 3), child.retries);
        },
    }

    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            App,
            std.testing.allocator,
            .{ .values = &.{ "run", "--timeout", "invalid" } },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.invalid_value, diagnostic.kind);
    try std.testing.expectEqualStrings("a duration in seconds", diagnostic.expected.?);
}

test "untagged unions with parseArg remain custom scalar fields" {
    const Duration = union {
        seconds: u16,

        pub fn parseArg(text: []const u8) error{InvalidValue}!@This() {
            return .{ .seconds = std.fmt.parseInt(u16, text, 10) catch return error.InvalidValue };
        }
    };
    const Command = struct {
        timeout: Duration,
    };

    const parsed = try parseFrom(
        Command,
        std.testing.allocator,
        .{ .values = &.{ "--timeout", "5" } },
        .{},
    );
    try std.testing.expectEqual(@as(u16, 5), parsed.timeout.seconds);

    var help: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer help.deinit();
    try render.writeHelp(Command, 0, &help.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, help.written(), "--timeout") != null);

    const result = comptime spec_module.spec(Command);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"long\":\"timeout\"") != null);
}

test "parseFrom binds one_of_flags enum switches and rejects multiple selections" {
    const Format = enum { table, json_output, yaml };
    const Command = struct {
        format: Format,

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .format = .{ .one_of_flags = true },
        } };
    };

    const parsed = try parseFrom(
        Command,
        std.testing.allocator,
        .{ .values = &.{"--json-output"} },
        .{},
    );
    try std.testing.expectEqual(Format.json_output, parsed.format);

    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(Command, std.testing.allocator, .{}, .{ .diagnostic = &diagnostic }),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.missing_required, diagnostic.kind);

    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            Command,
            std.testing.allocator,
            .{ .values = &.{ "--table", "--yaml" } },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.conflict, diagnostic.kind);
}

test "updateFrom overwrites scalars and replaces mentioned lists" {
    const Command = struct {
        output: []const u8 = "stdout",
        values: []const u16 = &.{ 1, 2 },
    };
    var value = defaults(Command);

    try updateFrom(
        Command,
        std.testing.allocator,
        &value,
        .{ .values = &.{ "--output", "log.txt", "--values=3", "--values=4" } },
        .{},
    );
    defer std.testing.allocator.free(value.values);

    try std.testing.expectEqualStrings("log.txt", value.output);
    try std.testing.expectEqualSlices(u16, &.{ 3, 4 }, value.values);
}

test "updateFrom releases replaced parsed list storage" {
    const Command = struct {
        values: []const u16 = &.{},
    };
    var value = try parseFrom(
        Command,
        std.testing.allocator,
        .{ .values = &.{ "--values=1", "--values=2" } },
        .{},
    );

    try updateFrom(
        Command,
        std.testing.allocator,
        &value,
        .{ .values = &.{ "--values=3", "--values=4" } },
        .{},
    );
    defer std.testing.allocator.free(value.values);

    try std.testing.expectEqualSlices(u16, &.{ 3, 4 }, value.values);
}

test "updateFrom releases discarded command list storage" {
    const First = struct { values: []const u16 = &.{} };
    const Second = struct { values: []const u16 = &.{} };
    const Commands = union(enum) {
        first: First,
        second: Second,
    };
    const App = struct { command: Commands };
    var value = try parseFrom(
        App,
        std.testing.allocator,
        .{ .values = &.{ "first", "--values=1" } },
        .{},
    );

    try updateFrom(
        App,
        std.testing.allocator,
        &value,
        .{ .values = &.{ "second", "--values=2" } },
        .{},
    );
    const final_values = switch (value.command) {
        .first => unreachable,
        .second => |second| second.values,
    };
    defer std.testing.allocator.free(final_values);

    try std.testing.expectEqualSlices(u16, &.{2}, final_values);
}

test "updateFrom retains lists after replacement failures" {
    const Command = struct {
        values: []const u16 = &.{},
    };
    var direct = try parseFrom(
        Command,
        std.testing.allocator,
        .{ .values = &.{ "--values=1", "--values=2" } },
        .{},
    );
    defer std.testing.allocator.free(direct.values);

    try std.testing.expectError(
        error.ParseFailed,
        updateFrom(
            Command,
            std.testing.allocator,
            &direct,
            .{ .values = &.{ "--values=3", "--unknown" } },
            .{},
        ),
    );
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, direct.values);

    const First = struct { values: []const u16 = &.{} };
    const Second = struct { values: []const u16 };
    const Commands = union(enum) {
        first: First,
        second: Second,
    };
    const App = struct { command: Commands };
    var nested = try parseFrom(
        App,
        std.testing.allocator,
        .{ .values = &.{ "first", "--values=4" } },
        .{},
    );
    const original_values = switch (nested.command) {
        .first => |first| first.values,
        .second => unreachable,
    };
    defer std.testing.allocator.free(original_values);

    try std.testing.expectError(
        error.ParseFailed,
        updateFrom(
            App,
            std.testing.allocator,
            &nested,
            .{ .values = &.{"second"} },
            .{},
        ),
    );
    switch (nested.command) {
        .first => |first| try std.testing.expectEqualSlices(u16, &.{4}, first.values),
        .second => unreachable,
    }
}

test "updateFrom merges matching nested commands and replaces different variants" {
    const Serve = struct { port: u16 = 3000 };
    const Test = struct { name: []const u8 = "default" };
    const Tasks = union(enum) {
        serve: Serve,
        @"test": Test,
    };
    const Run = struct {
        task: Tasks = .{ .serve = .{} },
    };
    const Commands = union(enum) { run: Run };
    const App = struct {
        command: Commands = .{ .run = .{ .task = .{ .serve = .{ .port = 9000 } } } },
    };
    var value = defaults(App);

    try updateFrom(
        App,
        std.testing.allocator,
        &value,
        .{ .values = &.{ "run", "serve", "--port", "4000" } },
        .{},
    );
    switch (value.command) {
        .run => |run| switch (run.task) {
            .serve => |serve| try std.testing.expectEqual(@as(u16, 4000), serve.port),
            .@"test" => unreachable,
        },
    }

    try updateFrom(
        App,
        std.testing.allocator,
        &value,
        .{ .values = &.{ "run", "test", "--name", "smoke" } },
        .{},
    );
    switch (value.command) {
        .run => |run| switch (run.task) {
            .serve => unreachable,
            .@"test" => |test_case| try std.testing.expectEqualStrings("smoke", test_case.name),
        },
    }
}

test "updateFrom checks required fields only for a newly selected command" {
    const Run = struct { port: u16 = 3000 };
    const Publish = struct { input: []const u8 };
    const Commands = union(enum) {
        run: Run,
        publish: Publish,
    };
    const App = struct {
        command: Commands = .{ .run = .{} },
    };
    var value = defaults(App);
    var diagnostic: schema.Diagnostic = .{};

    try std.testing.expectError(
        error.ParseFailed,
        updateFrom(
            App,
            std.testing.allocator,
            &value,
            .{ .values = &.{"publish"} },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.missing_required, diagnostic.kind);
    switch (value.command) {
        .run => |run| try std.testing.expectEqual(@as(u16, 3000), run.port),
        .publish => unreachable,
    }

    try updateFrom(
        App,
        std.testing.allocator,
        &value,
        .{ .values = &.{ "publish", "--input", "release.tar" } },
        .{},
    );
    switch (value.command) {
        .run => unreachable,
        .publish => |publish| try std.testing.expectEqualStrings("release.tar", publish.input),
    }
}

test "updateFrom does not apply environment fallback" {
    const Command = struct {
        output: []const u8 = "existing",
        verbose: u8 = 0,

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .output = .{ .env = "ZLAP_OUTPUT" },
            .verbose = .{ .count = true },
        } };
    };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZLAP_OUTPUT", "from-env");

    var value = defaults(Command);
    try updateFrom(
        Command,
        std.testing.allocator,
        &value,
        .{ .values = &.{"--verbose"} },
        .{ .env = .{ .map = &env } },
    );
    try std.testing.expectEqualStrings("existing", value.output);
    try std.testing.expectEqual(@as(u8, 1), value.verbose);
}

test "default and external subcommands preserve routing precedence" {
    const Run = struct {
        input: []const u8 = "",

        pub const meta: schema.Meta(@This()) = .{ .fields = .{
            .input = .{ .positional = true },
        } };
    };
    const Inspect = struct {};
    const Defaults = union(enum) {
        run: Run,
        inspect: Inspect,
    };
    const DefaultApp = struct {
        command: ?Defaults = null,

        pub const meta: schema.Meta(@This()) = .{
            .default_subcommand = .run,
        };
    };

    const defaulted = try parseFrom(
        DefaultApp,
        std.testing.allocator,
        .{ .values = &.{"source.zig"} },
        .{},
    );
    switch (defaulted.command orelse unreachable) {
        .run => |run| try std.testing.expectEqualStrings("source.zig", run.input),
        .inspect => unreachable,
    }

    const explicit = try parseFrom(
        DefaultApp,
        std.testing.allocator,
        .{ .values = &.{"inspect"} },
        .{},
    );
    switch (explicit.command orelse unreachable) {
        .run => unreachable,
        .inspect => {},
    }

    var diagnostic: schema.Diagnostic = .{};
    try std.testing.expectError(
        error.HelpRequested,
        parseFrom(
            DefaultApp,
            std.testing.allocator,
            .{ .values = &.{"help"} },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.help, diagnostic.kind);
    try std.testing.expectError(
        error.ParseFailed,
        parseFrom(
            DefaultApp,
            std.testing.allocator,
            .{ .values = &.{"--unknown"} },
            .{ .diagnostic = &diagnostic },
        ),
    );
    try std.testing.expectEqual(schema.Diagnostic.Kind.unknown_flag, diagnostic.kind);

    const ExternalCommands = union(enum) {
        run: Run,
        external: schema.ExternalCommand,
    };
    const ExternalApp = struct {
        command: ExternalCommands,

        pub const meta: schema.Meta(@This()) = .{
            .external_subcommand = true,
        };
    };
    var captured = try parseFrom(
        ExternalApp,
        std.testing.allocator,
        .{ .values = &.{ "cargo", "--version", "--", "-3" } },
        .{},
    );
    defer switch (captured.command) {
        .external => |external| std.testing.allocator.free(external.args),
        .run => unreachable,
    };
    switch (captured.command) {
        .external => |external| try std.testing.expectEqualStrings("cargo", external.args[0]),
        .run => unreachable,
    }
    switch (captured.command) {
        .external => |external| try std.testing.expectEqualSlices(
            []const u8,
            &.{ "cargo", "--version", "--", "-3" },
            external.args,
        ),
        .run => unreachable,
    }

    try updateFrom(
        ExternalApp,
        std.testing.allocator,
        &captured,
        .{ .values = &.{ "git", "status" } },
        .{},
    );
    switch (captured.command) {
        .external => |external| try std.testing.expectEqualSlices(
            []const u8,
            &.{ "git", "status" },
            external.args,
        ),
        .run => unreachable,
    }
}
