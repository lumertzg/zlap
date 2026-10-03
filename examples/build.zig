const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zlap = b.dependency("zlap", .{
        .target = target,
        .optimize = optimize,
    });

    const basic = addExample(b, zlap, target, optimize, "basic", "basic/main.zig");
    const command = addExample(b, zlap, target, optimize, "command", "nested/main.zig");

    b.installArtifact(basic);
    b.installArtifact(command);

    addRunStep(b, basic, "run-basic", "Run the basic flags and positional example");
    addRunStep(b, command, "run-command", "Run the nested command example");

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{
        .paths = &.{ b.path("basic"), b.path("nested"), b.path("build.zig"), b.path("build.zig.zon") },
        .check = true,
    });
    fmt_step.dependOn(&fmt_check.step);
}

fn addExample(
    b: *std.Build,
    zlap: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    name: []const u8,
    source_path: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source_path),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zlap", zlap.module("zlap"));
    return exe;
}

fn addRunStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    name: []const u8,
    description: []const u8,
) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();

    const run_step = b.step(name, description);
    run_step.dependOn(&run_cmd.step);
}
