const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zat = b.dependency("zat", .{
        .target = target,
        .optimize = optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "zat", .module = zat.module("zat") },
        .{ .name = "zqlite", .module = zqlite.module("zqlite") },
    };

    const exe = b.addExecutable(.{
        .name = "pollz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // tests
    const test_step = b.step("test", "Run unit tests");
    const test_files = .{
        "src/oauth.zig",
    };
    inline for (test_files) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
