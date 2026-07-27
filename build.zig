const std = @import("std");

const default_version = "1.0.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option(
        []const u8,
        "version",
        "Version reported by --version",
    ) orelse default_version;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const os = target.result.os.tag;

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root.addOptions("build_options", options);

    const miniaudio = b.dependency("miniaudio", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(miniaudio.path("."));
    translate_c.addIncludePath(b.path("src"));
    root.addImport("c", translate_c.createModule());

    root.addIncludePath(miniaudio.path("."));
    root.addIncludePath(b.path("src"));
    root.addCSourceFile(.{
        .file = b.path("src/miniaudio.c"),
        .flags = &.{"-std=c99"},
    });

    switch (os) {
        .windows => {
            root.linkSystemLibrary("ws2_32", .{});
            root.linkSystemLibrary("rpcrt4", .{});
            root.linkSystemLibrary("user32", .{});
            root.linkSystemLibrary("advapi32", .{});
            root.linkSystemLibrary("ole32", .{});
        },
        .macos => {
            root.linkFramework("CoreFoundation", .{});
            root.linkFramework("CoreAudio", .{});
            root.linkFramework("AudioToolbox", .{});
        },
        else => {
            root.linkSystemLibrary("m", .{});
            root.linkSystemLibrary("dl", .{});
            root.linkSystemLibrary("pthread", .{});
        },
    }

    const exe = b.addExecutable(.{
        .name = "http_player",
        .root_module = root,
    });

    if (os == .windows) exe.subsystem = .Windows;

    b.installArtifact(exe);

    b.installDirectory(.{
        .source_dir = b.path("sounds"),
        .install_dir = .bin,
        .install_subdir = "sounds",
    });
    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("config.json"), "config.json").step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run http_player").dependOn(&run_cmd.step);
}
