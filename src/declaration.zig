//! Shared comptime reflection for command declarations.

const std = @import("std");
const schema = @import("schema.zig");

pub fn structInfo(comptime T: type) std.lang.Type.Struct {
    return switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        else => @compileError("zlap command declarations require struct types"),
    };
}

pub fn unionInfo(comptime T: type) std.lang.Type.Union {
    return switch (@typeInfo(T)) {
        .@"union" => |value| value,
        else => @compileError("zlap command fields require tagged unions"),
    };
}

/// Returns `T` or its direct optional child when it is a tagged command union.
pub fn commandUnion(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"union" => |info| if (info.tag_type != null) T else null,
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .@"union" => |info| if (info.tag_type != null) optional.child else null,
            else => null,
        },
        else => null,
    };
}

pub fn isCommandField(comptime T: type) bool {
    return commandUnion(T) != null;
}

pub fn commandFieldType(comptime T: type) ?type {
    inline for (structInfo(T).field_types) |Field| {
        if (isCommandField(Field)) return Field;
    }
    return null;
}

pub fn commandMeta(comptime T: type) schema.Meta(T) {
    if (@hasDecl(T, "meta")) return T.meta;
    return .{};
}

pub fn variantsMeta(comptime T: type) schema.VariantsMeta(T) {
    if (@hasDecl(T, "meta")) return T.meta;
    return .{};
}

pub fn kebabCase(comptime input: []const u8) []const u8 {
    const length = comptime kebabCaseLength(input);
    const output = comptime blk: {
        var buffer: [length]u8 = undefined;
        var write_index: usize = 0;
        for (input, 0..) |byte, read_index| {
            if (byte == '_') {
                buffer[write_index] = '-';
                write_index += 1;
            } else if (std.ascii.isUpper(byte)) {
                if (read_index != 0 and input[read_index - 1] != '_') {
                    buffer[write_index] = '-';
                    write_index += 1;
                }
                buffer[write_index] = std.ascii.toLower(byte);
                write_index += 1;
            } else {
                buffer[write_index] = byte;
                write_index += 1;
            }
        }
        std.debug.assert(write_index == length);
        break :blk buffer;
    };
    return &output;
}

fn kebabCaseLength(comptime input: []const u8) usize {
    var length: usize = input.len;
    for (input, 0..) |byte, index| {
        if (std.ascii.isUpper(byte) and index != 0 and input[index - 1] != '_') {
            length += 1;
        }
    }
    return length;
}
