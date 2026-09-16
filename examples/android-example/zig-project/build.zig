const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android } });
    const optimize = b.standardOptimizeOption(.{});

    const android_include_path = b.option(std.Build.LazyPath, "android_include_path", "NDK sysroot/usr/include (default: derived from -Dandroid_ndk)") orelse ndkIncludePath(b);

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        .android_include_path = android_include_path,
    });
    const dvui = dvui_dep.module("dvui_sdl3");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // linked into the app's JNI shared lib
        .pic = true,
    });
    mod.addImport("dvui", dvui);

    {
        const sdl_hello_lib = b.addLibrary(.{
            .name = "sdl_hello",
            .root_module = mod,
        });

        const android_abi = switch (target.result.cpu.arch) {
            .aarch64 => "arm64-v8a",
            .x86_64 => "x86_64",
            else => @panic("unsupported android arch"),
        };
        // zig's static-lib output doesn't bundle linked static libs; flatten SDL3 in so the NDK link sees one archive
        const merge = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "qcL" });
        const merged = merge.addOutputFileArg("libsdl_hello.a");
        merge.addFileArg(sdl_hello_lib.getEmittedBin());
        merge.addFileArg(dvui_dep.artifact("SDL3").getEmittedBin());
        // zig-out/../../android-project: drops the lib where the gradle CMake build expects it
        const install = b.addInstallFileWithDir(merged, .{
            .custom = b.fmt("../../android-project/app/src/main/c/prebuilt/{s}", .{android_abi}),
        }, "libsdl_hello.a");
        b.step("lib", "Build the lib into android-project").dependOn(&install.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "sdl_hello",
            .root_module = mod,
        });

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        b.step("run", "Run the app").dependOn(&run_cmd.step);
    }
}

fn ndkIncludePath(b: *std.Build) std.Build.LazyPath {
    const ndk_root = b.option([]const u8, "android_ndk", "NDK root (default: $ANDROID_NDK_HOME or $ANDROID_NDK_ROOT)") orelse
        b.graph.environ_map.get("ANDROID_NDK_HOME") orelse
        b.graph.environ_map.get("ANDROID_NDK_ROOT") orelse
        @panic("set ANDROID_NDK_HOME or pass -Dandroid_ndk=<sdk>/ndk/<version>");
    // NDK ships x86_64 host toolchains only; macOS's is a universal binary
    const host_tag = switch (builtin.os.tag) {
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
    return .{ .cwd_relative = b.pathJoin(&.{ ndk_root, "toolchains", "llvm", "prebuilt", host_tag, "sysroot", "usr", "include" }) };
}
