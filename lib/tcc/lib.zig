const std = @import("std");

pub fn createModule(b: *std.Build) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = .{ .path = thisDir() ++ "/tcc.zig" },
    });
}

pub fn addModule(b: *std.Build, name: []const u8, mod: *std.Build.Module) void {
    //if (mod.owner != b) @compileError("unexpected mod owner");
    b.modules.put(b.dupe(name), mod) catch @panic("OOM");
    mod.addIncludePath(.{ .path = thisDir() ++ "/vendor" });
}

const BuildOptions = struct {
    selinux: bool = false,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn buildAndLink(b: *std.Build, step: *std.Build.Step.Compile, opts: BuildOptions) void {
    const lib = b.addStaticLibrary(.{
        .name = "tcc",
        .target = opts.target,
        .optimize = opts.optimize,
    });
    lib.addIncludePath(.{ .path = thisDir() ++ "/vendor" });
    lib.linkLibC();
    //lib.disable_sanitize_c = true;

    var c_flags = std.ArrayList([]const u8).init(b.allocator);
    if (opts.selinux) {
        c_flags.append("-DHAVE_SELINUX=1") catch @panic("error");
    }
    // c_flags.append("-D_GNU_SOURCE=1") catch @panic("error");
    //if (opts.target.query.os_tag.? == .windows) {}
    if (opts.optimize == .Debug) {
        // For debugging:
        // c_flags.append("-O0") catch @panic("error");
    }

    var sources = std.ArrayList([]const u8).init(b.allocator);
    sources.appendSlice(&.{
        "/vendor/libtcc.c",
        // "/vendor/lib/libtcc1.c",
    }) catch @panic("error");
    for (sources.items) |src| {
        lib.addCSourceFile(.{
            .file = .{ .path = b.fmt("{s}{s}", .{ thisDir(), src }) },
            .flags = c_flags.items,
        });
    }
    step.linkLibrary(lib);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse @panic("error");
}
