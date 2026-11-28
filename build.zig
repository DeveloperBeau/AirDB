const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const mod = b.addModule("airdb", .{
        .root_source_file = b.path("src/airdb.zig"),
        .target = target,
        .optimize = optimize,
        // The storage engine calls libc directly for durability and
        // multi-process coordination: fcntl(F_FULLFSYNC) on Darwin, plus
        // flock/getpid. macOS links libc implicitly; Linux requires it to be
        // requested explicitly.
        .link_libc = true,
    });

    // Test and bench helpers. createModule keeps it out of the package's
    // exported modules. A compilation imports this or `airdb`, never both.
    const internal_mod = b.createModule(.{
        .root_source_file = b.path("src/airdb_internal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib_tests = b.addTest(.{
        .root_module = mod,
    });

    const int_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/storageTest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "airdb_internal", .module = internal_mod },
        },
    });
    const int_tests = b.addTest(.{
        .root_module = int_test_mod,
    });

    // Public surface test: observes the real package module.
    const public_api_mod = b.createModule(.{
        .root_source_file = b.path("tests/publicApi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "airdb", .module = mod },
        },
    });
    const public_api_tests = b.addTest(.{ .root_module = public_api_mod });
    const run_public_api = b.addRunArtifact(public_api_tests);

    const run_lib = b.addRunArtifact(lib_tests);
    const run_int = b.addRunArtifact(int_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib.step);
    test_step.dependOn(&run_int.step);
    test_step.dependOn(&run_public_api.step);

    // Inward-dependency architecture test. It reads src/ at run time, so it runs
    // from the repo root and is never cached.
    const arch_mod = b.createModule(.{
        .root_source_file = b.path("tests/architectureTest.zig"),
        .target = target,
        .optimize = optimize,
    });
    const arch_tests = b.addTest(.{ .root_module = arch_mod });
    const run_arch = b.addRunArtifact(arch_tests);
    run_arch.setCwd(b.path("."));
    run_arch.has_side_effects = true;
    test_step.dependOn(&run_arch.step);

    // Standalone performance harness. Not part of `test` so CI stays fast.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{.{ .name = "airdb_internal", .module = internal_mod }},
    });
    const bench_exe = b.addExecutable(.{ .name = "airdb-bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Run the performance benchmark suite");
    bench_step.dependOn(&run_bench.step);

    // Static library exposing the C ABI for language bindings. The library's
    // root is cApi.zig so its top-level `export fn` symbols are emitted (they
    // would be tree-shaken if reached only through a re-export).
    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/cApi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = "airdb",
        .root_module = ffi_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // C smoke test: compile tests/cApiSmoke.c against include/airdb.h, link the
    // static library, and run it. Proves the C ABI is callable end to end. Its
    // fixed "/tmp/..." path is POSIX-only, so the run is skipped on Windows (the
    // ABI logic it exercises is platform-neutral).
    if (target.result.os.tag != .windows) {
        const c_smoke_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        c_smoke_mod.addCSourceFile(.{ .file = b.path("tests/cApiSmoke.c") });
        c_smoke_mod.addIncludePath(b.path("include"));
        c_smoke_mod.linkLibrary(lib);
        const c_smoke = b.addExecutable(.{
            .name = "cApiSmoke",
            .root_module = c_smoke_mod,
        });
        const run_c_smoke = b.addRunArtifact(c_smoke);
        test_step.dependOn(&run_c_smoke.step);
    }
}
