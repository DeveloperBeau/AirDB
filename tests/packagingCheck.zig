//! Packaging checks run by `zig build test`.
//!
//! header <source airdb.h> <install prefix>
//!     The installed include/airdb.h must match the source header.
//! paths <zig> <build root> <local cache> <global cache> <entry>...
//!     Copy only the build.zig.zon .paths entries to a fresh tree, then build
//!     it and run its tests with -Dpackaging_check=false. The nested zig uses
//!     its own absolute cache dirs under that tree, not the outer caches.

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;

const max_header_bytes = 1 << 20;

fn fail(comptime fmt: []const u8, args: anytype) error{PackagingCheckFailed} {
    std.debug.print("packaging check: " ++ fmt ++ "\n", args);
    return error.PackagingCheckFailed;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 4 and std.mem.eql(u8, args[1], "header")) {
        return checkHeader(init.io, init.gpa, args[2], args[3]);
    }
    if (args.len >= 6 and std.mem.eql(u8, args[1], "paths")) {
        return checkPaths(init.io, init.gpa, init.environ_map, args[2], args[3], args[4], args[5], args[6..]);
    }
    return fail("bad arguments", .{});
}

fn checkHeader(io: Io, gpa: Allocator, source: []const u8, prefix: []const u8) !void {
    const cwd = Dir.cwd();
    const expected = cwd.readFileAlloc(io, source, gpa, .limited(max_header_bytes)) catch |err|
        return fail("cannot read source header {s}: {t}", .{ source, err });
    defer gpa.free(expected);

    const installed_path = try std.fs.path.join(gpa, &.{ prefix, "include", "airdb.h" });
    defer gpa.free(installed_path);
    const installed = cwd.readFileAlloc(io, installed_path, gpa, .limited(max_header_bytes)) catch
        return fail("installed header missing (expected include/airdb.h under the install prefix)", .{});
    defer gpa.free(installed);

    if (!std.mem.eql(u8, expected, installed))
        return fail("installed header does not match include/airdb.h", .{});
}

fn copyTree(io: Io, gpa: Allocator, from: Dir, to: Dir, entry: []const u8) !void {
    const stat = from.statFile(io, entry, .{}) catch |err|
        return fail("missing .paths entry {s}: {t}", .{ entry, err });
    if (std.fs.path.dirname(entry)) |parent| try to.createDirPath(io, parent);
    if (stat.kind != .directory) {
        from.copyFile(entry, to, entry, io, .{}) catch |err|
            return fail("cannot copy {s}: {t}", .{ entry, err });
        return;
    }
    try to.createDirPath(io, entry);
    var source = try from.openDir(io, entry, .{ .iterate = true });
    defer source.close(io);
    var walker = try source.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |item| {
        const dest = try std.fs.path.join(gpa, &.{ entry, item.path });
        defer gpa.free(dest);
        switch (item.kind) {
            .directory => try to.createDirPath(io, dest),
            .file => {
                const src = try std.fs.path.join(gpa, &.{ entry, item.path });
                defer gpa.free(src);
                from.copyFile(src, to, dest, io, .{}) catch |err|
                    return fail("cannot copy {s}: {t}", .{ src, err });
            },
            else => {},
        }
    }
}

fn absolutePath(io: Io, gpa: Allocator, cwd: Dir, rel: []const u8) ![:0]u8 {
    return cwd.realPathFileAlloc(io, rel, gpa) catch |err|
        return fail("cannot resolve path {s}: {t}", .{ rel, err });
}

fn runZig(io: Io, gpa: Allocator, environ: *const std.process.Environ.Map, tree: []const u8, argv: []const []const u8, what: []const u8) !void {
    const result = std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .path = tree }, .environ_map = environ }) catch |err|
        return fail("cannot start {s}: {t}", .{ what, err });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return fail("nested {s} failed:\n{s}", .{ what, result.stderr });
}

fn checkPaths(
    io: Io,
    gpa: Allocator,
    environ_in: *const std.process.Environ.Map,
    zig: []const u8,
    root: []const u8,
    local_cache: []const u8,
    global_cache: []const u8,
    entries: []const [:0]const u8,
) !void {
    const cwd = Dir.cwd();
    const tree = try std.fs.path.join(gpa, &.{ local_cache, "packaging-check" });
    defer gpa.free(tree);

    try cwd.deleteTree(io, tree);
    try cwd.createDirPath(io, tree);

    // The nested zig must not inherit the outer ZIG_LOCAL_CACHE_DIR or share
    // the outer global cache: both point at the repo .zig-cache in CI, and a
    // concurrent compile then fails on Windows with AccessDenied.
    const nested_local_rel = try std.fs.path.join(gpa, &.{ tree, ".zig-cache" });
    defer gpa.free(nested_local_rel);
    const nested_global_rel = try std.fs.path.join(gpa, &.{ tree, "global-cache" });
    defer gpa.free(nested_global_rel);
    try cwd.createDirPath(io, nested_local_rel);
    try cwd.createDirPath(io, nested_global_rel);

    const nested_local = try absolutePath(io, gpa, cwd, nested_local_rel);
    defer gpa.free(nested_local);
    const nested_global = try absolutePath(io, gpa, cwd, nested_global_rel);
    defer gpa.free(nested_global);
    const outer_local = try absolutePath(io, gpa, cwd, local_cache);
    defer gpa.free(outer_local);
    const outer_global = try absolutePath(io, gpa, cwd, global_cache);
    defer gpa.free(outer_global);
    if (std.mem.eql(u8, nested_local, outer_local) or std.mem.eql(u8, nested_local, outer_global) or
        std.mem.eql(u8, nested_global, outer_local) or std.mem.eql(u8, nested_global, outer_global))
        return fail("nested cache path must differ from the outer build cache", .{});

    var environ = try environ_in.clone(gpa);
    defer environ.deinit();
    try environ.put("ZIG_LOCAL_CACHE_DIR", nested_local);
    try environ.put("ZIG_GLOBAL_CACHE_DIR", nested_global);

    var source = try cwd.openDir(io, root, .{});
    defer source.close(io);
    var dest = try cwd.openDir(io, tree, .{});
    defer dest.close(io);
    for (entries) |entry| try copyTree(io, gpa, source, dest, entry);

    try runZig(io, gpa, &environ, tree, &.{ zig, "build", "-Dpackaging_check=false" }, "build");

    const copied = dest.readFileAlloc(io, "include/airdb.h", gpa, .limited(max_header_bytes)) catch
        return fail("copied tree has no include/airdb.h", .{});
    defer gpa.free(copied);
    const built = dest.readFileAlloc(io, "zig-out/include/airdb.h", gpa, .limited(max_header_bytes)) catch
        return fail("nested build did not install zig-out/include/airdb.h", .{});
    defer gpa.free(built);
    if (!std.mem.eql(u8, copied, built))
        return fail("nested installed header does not match include/airdb.h", .{});

    const start = Io.Timestamp.now(io, .awake);
    try runZig(io, gpa, &environ, tree, &.{ zig, "build", "test", "-Dpackaging_check=false" }, "test step");
    const elapsed = start.durationTo(Io.Timestamp.now(io, .awake));
    std.debug.print("packaging check: paths-only test step took {d}ms\n", .{elapsed.toMilliseconds()});
}
