//! A consumer of zecs, built the way any other project would build it.
//!
//! This is a worked example and an integration test at once. Nothing inside the package
//! can prove that the package is *usable* from outside it — that the module resolves,
//! that the C library links, that the installed header is where the build says it is.
//! Only a separate project with its own build graph proves that, so CI builds and runs
//! this one.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zecs = b.dependency("zecs", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "zecs-example-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zecs", .module = zecs.module("zecs") }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the example").dependOn(&run.step);
}
