const std = @import("std");
const builtin = @import("builtin");
const config = @import("src/config.zig");
//const mimalloc_lib = @import("lib/mimalloc/lib.zig");
const tcc_lib = @import("lib/tcc/lib.zig");

// FIND: v0.4
const Version = "0.4";

var optMalloc: ?config.Allocator = undefined;
var selinux: bool = undefined;
var vmEngine: config.Engine = undefined;
var testFilter: ?[]const u8 = undefined;
var testBackend: config.TestBackend = undefined;
var trace: bool = undefined;
var optFFI: ?bool = undefined;
var optStatic: ?bool = undefined;
var optJIT: ?bool = undefined;
var optRT: ?config.Runtime = undefined;

var stdx: *std.Build.Module = undefined;
var tcc: *std.Build.Module = undefined;
var linenoise: *std.Build.Module = undefined;
//var mimalloc: *std.Build.Module = undefined;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    selinux = b.option(bool, "selinux", "Whether you are building on linux distro with selinux. eg. Fedora.") orelse false;
    testFilter = b.option([]const u8, "test-filter", "Test filter.");
    testBackend = b.option(config.TestBackend, "test-backend", "Test compiler backend.") orelse .vm;
    vmEngine = b.option(config.Engine, "vm", "Build with `zig` or `c` VM.") orelse .c;
    optMalloc = b.option(config.Allocator, "malloc", "Override default allocator: `malloc`, `mimalloc`, `zig`");
    optFFI = b.option(bool, "ffi", "Override default FFI: true, false");
    optStatic = b.option(bool, "static", "Override default lib build type: true=static, false=dynamic");
    trace = b.option(bool, "trace", "Enable tracing features.") orelse (optimize == .Debug);
    optJIT = b.option(bool, "jit", "Build with JIT.");
    optRT = b.option(config.Runtime, "rt", "Runtime.");

    stdx = b.createModule(.{
        .root_source_file = .{ .path = thisDir() ++ "/src/stdx/stdx.zig" },
    });
    tcc = tcc_lib.createModule(b);
    //mimalloc = mimalloc_lib.createModule(b);
    linenoise = createLinenoiseModule(b);

    {
        const step = b.step("cli", "Build main cli.");

        var opts = getDefaultOptions(target.query, optimize);
        opts.applyOverrides();

        const exe = b.addExecutable(.{
            .name = "cyber",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });

        if (opts.optimize != .Debug) {
            // Sometimes there are issues with strip for ReleaseFast + wasi.
            if (opts.target.os_tag != .wasi) {
                exe.dead_strip_dylibs = true;
            }
        }
        exe.addIncludePath(.{ .path = thisDir() ++ "/src" });

        // Allow dynamic libraries to be loaded by filename in the cwd.
        if (target.query.os_tag == .linux) {
            exe.addRPath(.{ .path = ":$ORIGIN" });
            if (target.query.cpu_arch == .x86_64) {
                exe.addRPath(.{ .path = "/usr/lib/x86_64-linux-gnu" });
            }
        } else if (target.query.os_tag == .macos) {
            exe.addRPath(.{ .path = "@loader_path" });
        }

        // Allow exported symbols in exe to be visible to dlopen.
        exe.rdynamic = true;

        // step.dependOn(&b.addInstallFileWithDir(
        //     exe.getEmittedAsm(), .prefix, "cyber.s",
        // ).step);
        try buildAndLinkDeps(exe, opts);
        step.dependOn(&exe.step);
        step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    {
        const step = b.step("vm-lib", "Build vm as a library.");

        const opts = getDefaultOptions(target, optimize);
        const obj = try buildCVM(b, opts);

        const lib = b.addStaticLibrary(.{
            .name = "vm",
            .target = target,
            .optimize = optimize,
        });
        lib.addObject(obj);

        step.dependOn(&lib.step);
        step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    }

    {
        const step = b.step("rt", "Build runtime for AOT.");

        var opts = getDefaultOptions(target, optimize);
        opts.ffi = false;
        opts.malloc = if (target.cpu_arch.isWasm()) .zig else .malloc;
        opts.cli = false;
        opts.rt = .pm;
        opts.applyOverrides();

        const lib = b.addStaticLibrary(.{
            .name = "rt",
            .root_source_file = .{ .path = "src/runtime_static.zig" },
            .target = target,
            .optimize = optimize,
        });
        if (lib.optimize != .Debug) {
            lib.strip = true;
        }
        lib.addIncludePath(.{ .path = thisDir() ++ "/src" });

        try buildAndLinkDeps(lib, opts);
        step.dependOn(&lib.step);
        step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    }

    {
        const step = b.step("lib", "Build as a library.");

        var opts = getDefaultOptions(target, optimize);
        opts.ffi = false;
        opts.malloc = if (target.cpu_arch.isWasm()) .zig else .malloc;
        opts.cli = false;
        opts.applyOverrides();

        const lib = try buildLib(b, opts);
        step.dependOn(&lib.step);
        step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    }

    {
        const step = b.step("web-lib", "Build wasm lib for web.");

        var opts = getDefaultOptions(target, optimize);
        opts.ffi = false;
        opts.malloc = if (target.cpu_arch.isWasm()) .zig else .malloc;
        opts.cli = false;
        opts.applyOverrides();

        const lib = b.addSharedLibrary(.{
            .name = "cyber-web",
            .root_source_file = .{ .path = "src/web.zig" },
            .target = target,
            .optimize = optimize,
        });
        if (lib.optimize != .Debug) {
            lib.strip = true;
        }
        lib.addIncludePath(.{ .path = thisDir() ++ "/src" });

        if (target.cpu_arch.isWasm()) {
            // Export table so non-exported functions can still be invoked from:
            // `instance.exports.__indirect_function_table`
            lib.export_table = true;
        }
        lib.rdynamic = true;

        try buildAndLinkDeps(lib, opts);
        step.dependOn(&lib.step);
        step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    }

    {
        const mainStep = b.step("build-test", "Build test.");

        var opts = getDefaultOptions(target, optimize);
        opts.trackGlobalRc = true;
        opts.applyOverrides();

        var step = b.addTest(.{
            .root_source_file = .{ .path = "./test/main_test.zig" },
            .target = target,
            .optimize = optimize,
            .filter = testFilter,
            .main_pkg_path = .{ .path = "." },
        });
        step.addIncludePath(.{ .path = thisDir() ++ "/src" });
        step.rdynamic = true;

        try buildAndLinkDeps(step, opts);
        mainStep.dependOn(&b.addInstallArtifact(step, .{}).step);

        step = try addTraceTest(b, opts);
        mainStep.dependOn(&b.addInstallArtifact(step, .{}).step);
    }

    {
        const mainStep = b.step("build-link-test", "Build link test.");

        var opts = getDefaultOptions(target, optimize);
        opts.trackGlobalRc = true;
        opts.ffi = false;
        opts.link_test = true;
        opts.applyOverrides();

        var step = b.addTest(.{
            // Lib test includes main tests.
            .root_source_file = .{ .path = "./test/behavior_test.zig" },
            .target = target,
            .optimize = optimize,
            .filter = testFilter,
            .main_pkg_path = .{ .path = "." },
        });
        step.addIncludePath(.{ .path = thisDir() ++ "/src" });
        step.rdynamic = true;

        try addBuildOptions(b, step, opts);
        // Is this even needed?
        //step.addModule("stdx", stdx);
        step.addAnonymousModule("tcc", .{
            .root_source_file = .{ .path = thisDir() ++ "/src/tcc_stub.zig" },
        });

        opts = getDefaultOptions(target, optimize);
        opts.trackGlobalRc = true;
        opts.cli = true;
        opts.applyOverrides();
        const lib = try buildLib(b, opts);
        step.linkLibrary(lib);
        mainStep.dependOn(&b.addInstallArtifact(step, .{}).step);
    }

    {
        const mainStep = b.step("test", "Run tests.");

        var opts = getDefaultOptions(target, optimize);
        opts.trackGlobalRc = true;
        opts.applyOverrides();

        var step = b.addTest(.{
            .root_source_file = .{ .path = "./test/main_test.zig" },
            .target = target,
            .optimize = optimize,
            .filter = testFilter,
            .main_pkg_path = .{ .path = "." },
        });
        step.addIncludePath(.{ .path = thisDir() ++ "/src" });
        step.rdynamic = true;

        try buildAndLinkDeps(step, opts);
        mainStep.dependOn(&b.addRunArtifact(step).step);

        step = try addTraceTest(b, opts);
        mainStep.dependOn(&b.addRunArtifact(step).step);
    }

    {
        // Just trace test.
        const mainStep = b.step("test-trace", "Run trace tests.");
        var opts = getDefaultOptions(target, optimize);
        opts.trackGlobalRc = true;
        opts.applyOverrides();

        const step = try addTraceTest(b, opts);
        mainStep.dependOn(&b.addRunArtifact(step).step);
    }

    const printStep = b.allocator.create(PrintStep) catch unreachable;
    printStep.* = PrintStep.init(b, Version);
    b.step("version", "Get the short version.").dependOn(&printStep.step);
}

pub fn buildAndLinkDeps(step: *std.Build.Step.Compile, opts: Options) !void {
    const b = step.step.owner;

    try addBuildOptions(b, step, opts);
    //b.addModule("stdx", stdx);

    step.linkLibC();

    //if (opts.malloc == .mimalloc) {
    //    mimalloc_lib.addModule(step, "mimalloc", mimalloc);
    //    mimalloc_lib.buildAndLink(b, step, .{});
    //}

    if (vmEngine == .c) {
        const lib = try buildCVM(b, opts);
        if (opts.target.cpu_arch.isWasm()) {
            lib.stack_protector = false;
        }
        step.addObject(lib);
    }

    if (opts.ffi) {
        tcc_lib.addModule(step, "tcc", tcc);
        tcc_lib.buildAndLink(b, step, .{
            .selinux = selinux,
        });
    } else {
        step.addAnonymousModule("tcc", .{
            .root_source_file = .{ .path = thisDir() ++ "/src/tcc_stub.zig" },
        });
        // Disable stack protector since the compiler isn't linking __stack_chk_guard/__stack_chk_fail.
        step.stack_protector = false;
    }

    if (opts.cli and opts.target.os_tag != .windows and opts.target.os_tag != .wasi) {
        addLinenoiseModule(step, "linenoise", linenoise);
        buildAndLinkLinenoise(b, step);
    } else {
        step.addAnonymousModule("linenoise", .{
            .root_source_file = .{ .path = thisDir() ++ "/src/ln_stub.zig" },
        });
    }

    if (opts.jit) {
        // step.addIncludePath(.{ .path = "/opt/homebrew/Cellar/llvm/17.0.1/include" });
        // step.addLibraryPath(.{ .path = "/opt/homebrew/Cellar/llvm/17.0.1/lib" });
        // step.linkSystemLibrary("LLVM-17");
    }
}

pub const Options = struct {
    selinux: bool,
    trackGlobalRc: bool,
    trace: bool,
    target: std.zig.CrossTarget,
    optimize: std.builtin.OptimizeMode,
    malloc: config.Allocator,
    static: bool,
    gc: bool,
    ffi: bool,
    cli: bool,
    jit: bool,
    rt: config.Runtime,
    link_test: bool,

    fn applyOverrides(self: *Options) void {
        if (optMalloc) |malloc| {
            self.malloc = malloc;
        }
        if (optFFI) |ffi| {
            self.ffi = ffi;
        }
        if (optStatic) |static| {
            self.static = static;
        }
        if (optJIT) |jit| {
            self.jit = jit;
        }
    }
};

// deps: struct {
//     tcc: *std.Build.Module,
// },

fn getDefaultOptions(target: std.zig.CrossTarget, optimize: std.builtin.OptimizeMode) Options {
    var malloc: config.Allocator = undefined;
    // Use mimalloc for fast builds.
    if (target.cpu_arch.?.isWasm()) {
        malloc = .zig;
    } else {
        //if (optimize != .Debug) {
        //    malloc = .mimalloc;
        //} else {
        malloc = .zig;
        //}
    }
    return .{
        .selinux = selinux,
        .trackGlobalRc = optimize == .Debug,
        .trace = trace,
        .target = target,
        .optimize = optimize,
        .gc = true,
        .malloc = malloc,
        .static = !target.cpu_arch.?.isWasm(),
        .ffi = !target.cpu_arch.?.isWasm(),
        .cli = !target.cpu_arch.?.isWasm(),
        .jit = false,
        .rt = .vm,
        .link_test = false,
    };
}

fn createBuildOptions(b: *std.Build, opts: Options) !*std.Build.Step.Options {
    const buildTag = std.process.getEnvVarOwned(b.allocator, "BUILD") catch |err| b: {
        if (err == error.EnvironmentVariableNotFound) {
            break :b "0";
        } else {
            return err;
        }
    };
    const commitTag = std.process.getEnvVarOwned(b.allocator, "COMMIT") catch |err| b: {
        if (err == error.EnvironmentVariableNotFound) {
            break :b "local";
        } else {
            return err;
        }
    };
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", Version);
    build_options.addOption([]const u8, "build", buildTag);
    build_options.addOption([]const u8, "commit", commitTag);
    build_options.addOption(config.Allocator, "malloc", opts.malloc);
    build_options.addOption(config.Engine, "vmEngine", vmEngine);
    build_options.addOption(bool, "trace", opts.trace);
    build_options.addOption(bool, "trackGlobalRC", opts.trackGlobalRc);
    build_options.addOption(bool, "is32Bit", is32Bit(opts.target));
    build_options.addOption(bool, "gc", opts.gc);
    build_options.addOption(bool, "ffi", opts.ffi);
    build_options.addOption(bool, "cli", opts.cli);
    build_options.addOption(bool, "jit", opts.jit);
    build_options.addOption(config.TestBackend, "testBackend", testBackend);
    build_options.addOption(config.Runtime, "rt", opts.rt);
    build_options.addOption(bool, "link_test", opts.link_test);
    build_options.addOption([]const u8, "full_version", b.fmt("Cyber {s} build-{s}-{s}", .{ Version, buildTag, commitTag }));
    return build_options;
}

fn addBuildOptions(b: *std.Build, step: *std.Build.Step.Compile, opts: Options) !void {
    const build_options = try createBuildOptions(b, opts);
    step.root_module.addOptions("build_options", build_options);
}

fn addTraceTest(b: *std.Build, opts: Options) !*std.build.LibExeObjStep {
    const step = b.addTest(.{
        .name = "trace_test",
        .root_source_file = .{ .path = "./test/trace_test.zig" },
        .optimize = opts.optimize,
        .target = opts.target,
        .filter = testFilter,
        .main_pkg_path = .{ .path = "." },
    });
    step.addIncludePath(.{ .path = thisDir() ++ "/src" });

    var newOpts = opts;
    newOpts.trace = true;
    newOpts.applyOverrides();

    // Include all deps since it contains tests that depend on Zig source.
    try buildAndLinkDeps(step, newOpts);
    return step;
}

fn is32Bit(target: std.zig.CrossTarget) bool {
    switch (target.cpu_arch.?) {
        .wasm32, .x86 => return true,
        else => return false,
    }
}

const stdxPkg = std.build.Pkg{
    .name = "stdx",
    .source = .{ .path = thisDir() ++ "/src/stdx/stdx.zig" },
};

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse unreachable;
}

pub const PrintStep = struct {
    step: std.build.Step,
    build: *std.Build,
    str: []const u8,

    pub fn init(build_: *std.Build, str: []const u8) PrintStep {
        return PrintStep{
            .build = build_,
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "print",
                .owner = build_,
                .makeFn = make,
            }),
            .str = build_.dupe(str),
        };
    }

    fn make(step: *std.build.Step, _: *std.Progress.Node) anyerror!void {
        const self: *PrintStep = @fieldParentPtr("step", step);
        std.io.getStdOut().writer().writeAll(self.str) catch unreachable;
    }
};

pub fn buildCVM(b: *std.Build, opts: Options) !*std.Build.Step.Compile {
    const lib = b.addObject(.{
        .name = "vm",
        .target = opts.target,
        .optimize = opts.optimize,
    });
    lib.linkLibC();
    if (lib.optimize != .Debug) {
        lib.strip = true;
    }

    var cflags = std.ArrayList([]const u8).init(b.allocator);
    if (opts.optimize == .Debug) {
        try cflags.append("-DDEBUG=1");
    } else {
        try cflags.append("-DDEBUG=0");
    }
    try cflags.append("-DCGOTO=1");
    if (opts.trackGlobalRc) {
        try cflags.append("-DTRACK_GLOBAL_RC=1");
    }
    if (opts.trace) {
        try cflags.append("-DTRACE=1");
    } else {
        try cflags.append("-DTRACE=0");
    }
    if (is32Bit(opts.target)) {
        try cflags.append("-DIS_32BIT=1");
    } else {
        try cflags.append("-DIS_32BIT=0");
    }
    if (opts.gc) {
        try cflags.append("-DHAS_GC=1");
    } else {
        try cflags.append("-DHAS_GC=0");
    }

    // Disable traps for arithmetic/bitshift overflows.
    // Note that changing this alone doesn't clear the build cache.
    lib.disable_sanitize_c = true;

    lib.addIncludePath(.{ .path = thisDir() ++ "/src" });
    lib.addCSourceFile(.{ .file = .{ .path = thisDir() ++ "/src/vm.c" }, .flags = cflags.items });
    return lib;
}

fn buildLib(b: *std.Build, opts: Options) !*std.Build.Step.Compile {
    var lib: *std.Build.Step.Compile = undefined;
    if (opts.static) {
        lib = b.addStaticLibrary(.{
            .name = "cyber",
            .root_source_file = .{ .path = "src/lib.zig" },
            .target = opts.target,
            .optimize = opts.optimize,
        });
    } else {
        lib = b.addSharedLibrary(.{
            .name = "cyber",
            .root_source_file = .{ .path = "src/lib.zig" },
            .target = opts.target,
            .optimize = opts.optimize,
        });
    }
    if (lib.optimize != .Debug) {
        lib.strip = true;
    }
    lib.addIncludePath(.{ .path = thisDir() ++ "/src" });

    if (opts.target.cpu_arch.isWasm()) {
        // Export table so non-exported functions can still be invoked from:
        // `instance.exports.__indirect_function_table`
        lib.export_table = true;
    }

    if (opts.cli) {
        if (opts.target.os_tag == .windows) {
            lib.linkSystemLibrary("ole32");
            lib.linkSystemLibrary("crypt32");
            lib.linkSystemLibrary("ws2_32");

            if (opts.target.getAbi() == .msvc) {
                lib.linkSystemLibrary("advapi32");
                lib.linkSystemLibrary("shell32");
            }
        }
    }

    // Allow exported symbols to be visible to dlopen.
    // Also needed to export symbols in wasm lib.
    lib.rdynamic = true;

    try buildAndLinkDeps(lib, opts);
    return lib;
}

pub fn createLinenoiseModule(b: *std.Build) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = .{ .path = thisDir() ++ "/lib/linenoise/linenoise.zig" },
    });
}

pub fn addLinenoiseModule(step: *std.Build.Step.Compile, name: []const u8, mod: *std.Build.Module) void {
    step.addModule(name, mod);
    step.addIncludePath(.{ .path = thisDir() ++ "/lib/linenoise" });
}

pub fn buildAndLinkLinenoise(b: *std.Build, step: *std.build.CompileStep) void {
    const lib = b.addStaticLibrary(.{
        .name = "linenoise",
        .target = step.target,
        .optimize = step.optimize,
    });
    lib.addIncludePath(.{ .path = thisDir() ++ "/lib/linenoise" });
    lib.linkLibC();
    // lib.disable_sanitize_c = true;

    const c_flags = std.ArrayList([]const u8).init(b.allocator);

    var sources = std.ArrayList([]const u8).init(b.allocator);
    sources.appendSlice(&.{
        "/lib/linenoise/linenoise.c",
    }) catch @panic("error");
    for (sources.items) |src| {
        lib.addCSourceFile(.{
            .file = .{ .path = b.fmt("{s}{s}", .{ thisDir(), src }) },
            .flags = c_flags.items,
        });
    }
    step.linkLibrary(lib);
}
