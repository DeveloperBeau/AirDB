//! Packaging checks run by `zig build test`.
//!
//! header <source airdb.h> <install prefix>
//!     The installed include/airdb.h must match the source header.
//! paths <zig> <build root> <local cache> <global cache> <entry>...
//!     Copy only the build.zig.zon .paths entries to a fresh tree, then build
//!     it and run its tests with -Dpackaging_check=false. The nested zig uses
//!     its own absolute cache dirs under that tree, not the outer caches.
//!     After the nested test, those cache dirs must contain objects, and the
//!     outer cache must not have received the nested zig's objects.

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

const ObjectNames = struct {
    gpa: Allocator,
    names: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ObjectNames) void {
        for (self.names.items) |name| self.gpa.free(name);
        self.names.deinit(self.gpa);
    }

    fn contains(self: ObjectNames, name: []const u8) bool {
        for (self.names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return true;
        }
        return false;
    }
};

fn objectDirPath(gpa: Allocator, cache_root: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ cache_root, "o" });
}

fn listObjectNames(io: Io, gpa: Allocator, cwd: Dir, cache_root: []const u8) !ObjectNames {
    var set: ObjectNames = .{ .gpa = gpa };
    errdefer set.deinit();
    const dir_path = try objectDirPath(gpa, cache_root);
    defer gpa.free(dir_path);
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return set,
        else => return fail("cannot open {s}: {t}", .{ dir_path, err }),
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| return fail("cannot read {s}: {t}", .{ dir_path, err })) |entry| {
        const copy = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(copy);
        try set.names.append(gpa, copy);
    }
    return set;
}

fn requireNestedObjects(io: Io, gpa: Allocator, cwd: Dir, cache_root: []const u8, what: []const u8) !void {
    const dir_path = try objectDirPath(gpa, cache_root);
    defer gpa.free(dir_path);
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err|
        return fail("nested zig did not write {s} ({t}); {s}", .{ dir_path, err, what });
    defer dir.close(io);
    var it = dir.iterate();
    const first = it.next(io) catch |err| return fail("cannot read {s}: {t}", .{ dir_path, err });
    if (first == null)
        return fail("nested zig wrote no objects under {s}; {s}", .{ dir_path, what });
}

fn assertOuterDidNotGainNested(
    io: Io,
    gpa: Allocator,
    cwd: Dir,
    outer_root: []const u8,
    before: ObjectNames,
    nested_roots: []const []const u8,
) !void {
    var after = try listObjectNames(io, gpa, cwd, outer_root);
    defer after.deinit();
    for (after.names.items) |name| {
        if (before.contains(name)) continue;
        for (nested_roots) |nested_root| {
            const nested_entry = try std.fs.path.join(gpa, &.{ nested_root, "o", name });
            defer gpa.free(nested_entry);
            const nested_abs = cwd.realPathFileAlloc(io, nested_entry, gpa) catch continue;
            defer gpa.free(nested_abs);
            const outer_entry = try std.fs.path.join(gpa, &.{ outer_root, "o", name });
            defer gpa.free(outer_entry);
            const outer_abs = try absolutePath(io, gpa, cwd, outer_entry);
            defer gpa.free(outer_abs);
            if (std.mem.eql(u8, nested_abs, outer_abs))
                return fail("nested zig wrote {s} into the outer build cache at {s}", .{ name, outer_abs });
        }
    }
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

    var environ = try environ_in.clone(gpa);
    defer environ.deinit();
    try environ.put("ZIG_LOCAL_CACHE_DIR", nested_local);
    try environ.put("ZIG_GLOBAL_CACHE_DIR", nested_global);

    var source = try cwd.openDir(io, root, .{});
    defer source.close(io);
    var dest = try cwd.openDir(io, tree, .{});
    defer dest.close(io);
    for (entries) |entry| try copyTree(io, gpa, source, dest, entry);

    var before_local = try listObjectNames(io, gpa, cwd, outer_local);
    defer before_local.deinit();
    var before_global = try listObjectNames(io, gpa, cwd, outer_global);
    defer before_global.deinit();

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

    try requireNestedObjects(
        io,
        gpa,
        cwd,
        nested_local,
        "ZIG_LOCAL_CACHE_DIR must be the paths-only tree .zig-cache, not the outer cache",
    );
    try requireNestedObjects(
        io,
        gpa,
        cwd,
        nested_global,
        "ZIG_GLOBAL_CACHE_DIR must be the paths-only tree global-cache, not the outer cache",
    );

    const nested_roots = [_][]const u8{ nested_local, nested_global };
    try assertOuterDidNotGainNested(io, gpa, cwd, outer_local, before_local, &nested_roots);
    if (!std.mem.eql(u8, outer_local, outer_global))
        try assertOuterDidNotGainNested(io, gpa, cwd, outer_global, before_global, &nested_roots);
}
