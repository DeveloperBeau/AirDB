const std = @import("std");

// Out-of-tree consumer of the airdb package. `zig build` (the default install
// step) only evaluates this file, so the check stays a configure-time
// assertion and does not compile the library. The exported-module set must be
// exactly {"airdb"}.
pub fn build(b: *std.Build) void {
    const dep = b.dependency("airdb", .{});

    var count: usize = 0;
    var has_airdb = false;
    var keys: std.ArrayList(u8) = .empty;
    for (dep.builder.modules.keys()) |name| {
        count += 1;
        if (std.mem.eql(u8, name, "airdb")) has_airdb = true;
        if (keys.items.len != 0) keys.appendSlice(b.allocator, ", ") catch @panic("OOM");
        keys.appendSlice(b.allocator, name) catch @panic("OOM");
    }
    if (!has_airdb or count != 1) {
        std.debug.print(
            "airdb must export exactly {{\"airdb\"}}; exported modules: {{{s}}}\n",
            .{keys.items},
        );
        std.process.exit(1);
    }

    // Proves the public module is retrievable under the name "airdb".
    const airdb_mod = dep.module("airdb");
    // Kept as a compile step, not the default, so a full consumer build remains
    // available without slowing `zig build test`.
    const exe = b.addExecutable(.{
        .name = "exportedModules",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "airdb", .module = airdb_mod }},
        }),
    });
    const compile_step = b.step("compile", "Compile a trivial consumer of airdb");
    compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
}
