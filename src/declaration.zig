//! Shared comptime reflection for command declarations.

const std = @import("std");
const schema = @import("schema.zig");

pub fn structFields(comptime T: type) []const std.builtin.Type.StructField {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.fields,
        else => @compileError("zlap command declarations require struct types"),
    };
}

pub fn unionFields(comptime T: type) []const std.builtin.Type.UnionField {
    return switch (@typeInfo(T)) {
        .@"union" => |info| info.fields,
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

pub fn commandField(comptime T: type) ?std.builtin.Type.StructField {
    inline for (structFields(T)) |field| {
        if (isCommandField(field.type)) return field;
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
