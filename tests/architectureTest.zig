//! Inward-dependency architecture test (testing rule 12).
//!
//! Walks src/ at run time and checks every production import against the ring
//! table. The build runs this binary with the repo root as its working
//! directory, so "src" opens relative to the root.

const std = @import("std");
const RingTable = @import("architecture/ringTable.zig").RingTable;
const ImportScanner = @import("architecture/importScanner.zig").ImportScanner;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ring = RingTable.Ring;

/// One production import that resolved to a file under src/.
const Edge = struct { from: []const u8, to: []const u8, line: u32 };

/// One import argument that could not be resolved to a checked target.
const Unresolved = struct {
    from: []const u8,
    line: u32,
    argument: []const u8,
    reason: []const u8,
};

/// Every production file under src/ with its resolved imports. All memory lives in the arena.
const SourceTree = struct {
    arena: std.heap.ArenaAllocator,
    paths: []const []const u8,
    edges: []const Edge,
    unresolved: []const Unresolved,

    fn deinit(self: *SourceTree) void {
        self.arena.deinit();
    }
};

fn lessThanPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// Walks src/ from the working directory, then reads, parses and resolves every production file.
fn loadSourceTree(gpa: Allocator) !SourceTree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();

    var paths: std.ArrayList([]const u8) = .empty;
    {
        var sourceDirectory = try cwd.openDir(io, "src", .{ .iterate = true });
        defer sourceDirectory.close(io);
        var walker = try sourceDirectory.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!ImportScanner.isProductionPath(entry.basename)) continue;
            const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
            // Windows walks with backslashes. Keys always use "/".
            std.mem.replaceScalar(u8, path, '\\', '/');
            try paths.append(allocator, path);
        }
    }
    // Sorted so failure output reads the same on every platform.
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var edges: std.ArrayList(Edge) = .empty;
    var unresolved: std.ArrayList(Unresolved) = .empty;
    for (paths.items) |path| {
        const bytes = try cwd.readFileAlloc(io, path, allocator, .unlimited);
        try recordFile(allocator, &edges, &unresolved, path, bytes, &RingTable.ignoredModuleNames);
    }

    return .{
        .arena = arena,
        .paths = paths.items,
        .edges = edges.items,
        .unresolved = unresolved.items,
    };
}

fn ringLabel(ring: ?Ring) []const u8 {
    return if (ring) |known| @tagName(known) else "no ring";
}

fn ringNumber(ring: ?Ring) u8 {
    return if (ring) |known| @backingInt(known) else 0;
}

/// Records one resolved import as a file edge, or as a site the check must fail.
/// The real-tree gate and the fixture tests both go through here.
fn recordImport(
    allocator: Allocator,
    edges: *std.ArrayList(Edge),
    unresolved: *std.ArrayList(Unresolved),
    from: []const u8,
    site: ImportScanner.Import,
    resolution: ImportScanner.Resolution,
) Allocator.Error!void {
    const reason: []const u8 = switch (resolution) {
        .file => |target| return edges.append(allocator, .{ .from = from, .to = target, .line = site.line }),
        .ignoredModule => return,
        // Parse skips test blocks, so any test file it returns sits in production code.
        .testFile => "test file imported outside a test block",
        .escapesSource => "path leaves src/",
        .unknownModule => "named module is not in ignoredModuleNames",
    };
    try unresolved.append(allocator, .{
        .from = from,
        .line = site.line,
        .argument = site.argument,
        .reason = reason,
    });
}

/// Parses one file, resolves each import and records it. Paths and strings borrow from `bytes` and `path`.
fn recordFile(
    allocator: Allocator,
    edges: *std.ArrayList(Edge),
    unresolved: *std.ArrayList(Unresolved),
    path: []const u8,
    bytes: []const u8,
    ignoredNames: []const []const u8,
) Allocator.Error!void {
    const imports = try ImportScanner.parse(allocator, bytes);
    for (imports) |site| {
        const resolution = try ImportScanner.resolve(allocator, path, site.argument, ignoredNames);
        try recordImport(allocator, edges, unresolved, path, site, resolution);
    }
}

/// Writes one line per unresolved site and per edge that breaks the ring rule.
/// Returns InwardDependencyViolation when any line was written.
fn checkInwardDependencies(
    writer: *std.Io.Writer,
    entries: []const RingTable.Entry,
    allowed: []const RingTable.AllowedImport,
    edges: []const Edge,
    unresolved: []const Unresolved,
) (std.Io.Writer.Error || error{InwardDependencyViolation})!void {
    var failures: usize = 0;
    for (unresolved) |site| {
        try writer.print("{s}:{d}: cannot check import \"{s}\": {s}\n", .{ site.from, site.line, site.argument, site.reason });
        failures += 1;
    }
    for (edges) |edge| {
        switch (ImportScanner.classify(entries, allowed, edge.from, edge.to)) {
            .allowed, .allowlisted => {},
            .violation, .unranked => {
                const fromRing = ImportScanner.ringOf(entries, edge.from);
                const toRing = ImportScanner.ringOf(entries, edge.to);
                try writer.print("{s}:{d}: {s} ({d}) imports {s} ({d}) {s}\n", .{
                    edge.from,
                    edge.line,
                    ringLabel(fromRing),
                    ringNumber(fromRing),
                    ringLabel(toRing),
                    ringNumber(toRing),
                    edge.to,
                });
                failures += 1;
            },
        }
    }
    if (failures > 0) {
        try writer.print("{d} import(s) break the inward-dependency rule. See tests/architecture/ringTable.zig.\n", .{failures});
        return error.InwardDependencyViolation;
    }
}

// Gate tests over the real tree.

test "every production import in src points inward under the ring table" {
    var tree = try loadSourceTree(testing.allocator);
    defer tree.deinit();

    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    checkInwardDependencies(&report.writer, &RingTable.entries, &RingTable.allowedImports, tree.edges, tree.unresolved) catch |err| {
        std.debug.print("{s}", .{report.written()});
        return err;
    };
}

test "every production file in src has exactly one ring and every table path exists" {
    var tree = try loadSourceTree(testing.allocator);
    defer tree.deinit();

    var failures: usize = 0;
    for (tree.paths) |path| {
        if (ImportScanner.ringOf(&RingTable.entries, path) == null) {
            std.debug.print("{s} has no ring in tests/architecture/ringTable.zig\n", .{path});
            failures += 1;
        }
    }
    for (RingTable.entries, 0..) |entry, index| {
        var onDisk = false;
        for (tree.paths) |path| {
            if (std.mem.eql(u8, path, entry.path)) onDisk = true;
        }
        if (!onDisk) {
            std.debug.print("{s} is in the ring table but is not a production file in src/\n", .{entry.path});
            failures += 1;
        }
        for (RingTable.entries[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.path, entry.path)) {
                std.debug.print("{s} is listed more than once in the ring table\n", .{entry.path});
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "every allowlisted import still occurs in src" {
    var tree = try loadSourceTree(testing.allocator);
    defer tree.deinit();

    var failures: usize = 0;
    for (RingTable.allowedImports) |pair| {
        var occurs = false;
        for (tree.edges) |edge| {
            if (std.mem.eql(u8, edge.from, pair.from) and std.mem.eql(u8, edge.to, pair.to)) occurs = true;
        }
        if (!occurs) {
            std.debug.print("{s} -> {s} no longer occurs. Remove it from allowedImports.\n", .{ pair.from, pair.to });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

// Allowlist ratchet. The list can only shrink, and each shrink edits the list and the cap together.

test "allowlist length equals the pinned cap" {
    if (RingTable.allowedImports.len != RingTable.allowedImportCap) {
        std.debug.print("allowedImports has {d} entries but allowedImportCap is {d}. Lower the cap when an entry goes. Raise it only after review.\n", .{ RingTable.allowedImports.len, RingTable.allowedImportCap });
    }
    try testing.expectEqual(@as(usize, RingTable.allowedImportCap), RingTable.allowedImports.len);
}

test "allowlist entries are unique" {
    var failures: usize = 0;
    for (RingTable.allowedImports, 0..) |pair, index| {
        for (RingTable.allowedImports[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.from, pair.from) and std.mem.eql(u8, earlier.to, pair.to)) {
                std.debug.print("{s} -> {s} is listed more than once in allowedImports\n", .{ pair.from, pair.to });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "every allowlist entry is a real violation under classify" {
    const noAllowed = [_]RingTable.AllowedImport{};
    var failures: usize = 0;
    for (RingTable.allowedImports) |pair| {
        const bare = ImportScanner.classify(&RingTable.entries, &noAllowed, pair.from, pair.to);
        const listed = ImportScanner.classify(&RingTable.entries, &RingTable.allowedImports, pair.from, pair.to);
        if (bare != .violation or listed != .allowlisted) {
            std.debug.print("{s} -> {s} is {s} without the allowlist and {s} with it. Only a real violation may be allowlisted.\n", .{ pair.from, pair.to, @tagName(bare), @tagName(listed) });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

// Scanner unit tests on in-memory fixtures.

const fixtureEntries = [_]RingTable.Entry{
    .{ .path = "src/storage/reference.zig", .ring = .entities },
    .{ .path = "src/trees/column.zig", .ring = .domain },
    .{ .path = "src/database.zig", .ring = .domain },
    .{ .path = "src/platform.zig", .ring = .infrastructure },
    .{ .path = "src/storage/syncer.zig", .ring = .infrastructure },
    .{ .path = "src/storage/fileStore.zig", .ring = .infrastructure },
    .{ .path = "src/airdb.zig", .ring = .composition },
};

const fixtureAllowed = [_]RingTable.AllowedImport{
    .{ .from = "src/storage/fileStore.zig", .to = "src/platform.zig", .reason = "fixture" },
};

const fixtureIgnored = [_][]const u8{ "std", "builtin" };

/// Parses `bytes` as the file at `path` and returns the verdict for each resolved file edge.
fn verdictsFor(allocator: Allocator, path: []const u8, bytes: []const u8) ![]ImportScanner.Verdict {
    const imports = try ImportScanner.parse(allocator, bytes);
    defer allocator.free(imports);
    var verdicts: std.ArrayList(ImportScanner.Verdict) = .empty;
    errdefer verdicts.deinit(allocator);
    for (imports) |site| {
        const resolution = try ImportScanner.resolve(allocator, path, site.argument, &fixtureIgnored);
        switch (resolution) {
            .file => |target| {
                defer allocator.free(target);
                try verdicts.append(allocator, ImportScanner.classify(&fixtureEntries, &fixtureAllowed, path, target));
            },
            else => {},
        }
    }
    return verdicts.toOwnedSlice(allocator);
}

fn expectArguments(bytes: []const u8, expected: []const []const u8) !void {
    const imports = try ImportScanner.parse(testing.allocator, bytes);
    defer testing.allocator.free(imports);
    try testing.expectEqual(expected.len, imports.len);
    for (expected, imports) |argument, site| {
        try testing.expectEqualStrings(argument, site.argument);
    }
}

test "scanner detects an outward import from Domain to Infrastructure" {
    const verdicts = try verdictsFor(testing.allocator, "src/trees/column.zig",
        \\const std = @import("std");
        \\const reference = @import("../storage/reference.zig");
        \\const platform = @import("../platform.zig");
        \\
    );
    defer testing.allocator.free(verdicts);
    try testing.expectEqualSlices(ImportScanner.Verdict, &.{ .allowed, .violation }, verdicts);
}

test "scanner ignores an import inside a comment" {
    try expectArguments(
        \\// const platform = @import("platform.zig");
        \\/// See @import("platform.zig") for the map helpers.
        \\//! @import("platform.zig")
        \\const node = @import("node.zig"); // @import("platform.zig")
        \\
    , &.{"node.zig"});
}

test "scanner ignores an import inside a string" {
    try expectArguments(
        \\const text = "@import(\"platform.zig\") {";
        \\const quote = '"'; const brace = '{';
        \\const lines =
        \\    \\@import("platform.zig") }
        \\;
        \\const node = @import("node.zig");
        \\
    , &.{"node.zig"});
}

test "scanner ignores an import inside a test block" {
    try expectArguments(
        \\const node = @import("node.zig");
        \\test "a } in the name {" {
        \\    const platform = @import("platform.zig");
        \\    if (true) { _ = "}"; }
        \\}
        \\test {
        \\    _ = @import("platformTests.zig");
        \\}
        \\test namedDeclaration {
        \\    _ = @embedFile("platform.zig");
        \\}
        \\const Holder = struct {
        \\    const slots = @import("slots.zig");
        \\};
        \\
    , &.{ "node.zig", "slots.zig" });
}

test "scanner records the line of each import" {
    const imports = try ImportScanner.parse(testing.allocator,
        \\const std = @import("std");
        \\// @import("hidden.zig")
        \\const lines =
        \\    \\@import("hidden.zig")
        \\;
        \\const node = @import(
        \\    "node.zig",
        \\);
        \\
    );
    defer testing.allocator.free(imports);
    try testing.expectEqual(@as(usize, 2), imports.len);
    try testing.expectEqual(@as(u32, 1), imports[0].line);
    try testing.expectEqual(@as(u32, 6), imports[1].line);
}

test "scanner resolves ../ relative to the importing file" {
    const resolution = try ImportScanner.resolve(testing.allocator, "src/trees/column.zig", "../storage/./reference.zig", &fixtureIgnored);
    defer if (resolution == .file) testing.allocator.free(resolution.file);
    try testing.expectEqualStrings("src/storage/reference.zig", resolution.file);

    const sibling = try ImportScanner.resolve(testing.allocator, "src/trees/column.zig", "columnNode.zig", &fixtureIgnored);
    defer if (sibling == .file) testing.allocator.free(sibling.file);
    try testing.expectEqualStrings("src/trees/columnNode.zig", sibling.file);

    const windows = try ImportScanner.resolve(testing.allocator, "src\\trees\\column.zig", "..\\platform.zig", &fixtureIgnored);
    defer if (windows == .file) testing.allocator.free(windows.file);
    try testing.expectEqualStrings("src/platform.zig", windows.file);
}

test "scanner fails a path that escapes src" {
    const allocator = testing.allocator;
    try testing.expectEqual(ImportScanner.Resolution.escapesSource, try ImportScanner.resolve(allocator, "src/database.zig", "../build.zig", &fixtureIgnored));
    try testing.expectEqual(ImportScanner.Resolution.escapesSource, try ImportScanner.resolve(allocator, "src/trees/column.zig", "../../../outside.zig", &fixtureIgnored));
    try testing.expectEqual(ImportScanner.Resolution.escapesSource, try ImportScanner.resolve(allocator, "src/database.zig", "../tests/architectureTest.zig", &fixtureIgnored));
    try testing.expectEqual(ImportScanner.Resolution.escapesSource, try ImportScanner.resolve(allocator, "src/database.zig", "/etc/data.zon", &fixtureIgnored));
}

test "scanner fails an unknown bare module name" {
    const allocator = testing.allocator;
    try testing.expectEqual(ImportScanner.Resolution.unknownModule, try ImportScanner.resolve(allocator, "src/database.zig", "build_options", &fixtureIgnored));
    try testing.expectEqual(ImportScanner.Resolution.ignoredModule, try ImportScanner.resolve(allocator, "src/database.zig", "std", &fixtureIgnored));
    try testing.expectEqual(ImportScanner.Resolution.ignoredModule, try ImportScanner.resolve(allocator, "src/database.zig", "builtin", &fixtureIgnored));
    try testing.expectEqual(ImportScanner.Resolution.testFile, try ImportScanner.resolve(allocator, "src/database.zig", "databaseTests.zig", &fixtureIgnored));
}

test "scanner fails a sideways Infrastructure import unless allowlisted" {
    const classify = ImportScanner.classify;
    try testing.expectEqual(ImportScanner.Verdict.violation, classify(&fixtureEntries, &fixtureAllowed, "src/storage/syncer.zig", "src/platform.zig"));
    try testing.expectEqual(ImportScanner.Verdict.allowlisted, classify(&fixtureEntries, &fixtureAllowed, "src/storage/fileStore.zig", "src/platform.zig"));
    try testing.expectEqual(ImportScanner.Verdict.allowed, classify(&fixtureEntries, &fixtureAllowed, "src/platform.zig", "src/platform.zig"));

    // Same ring outside Infrastructure is allowed. Lower rings are allowed. Higher rings are not.
    try testing.expectEqual(ImportScanner.Verdict.allowed, classify(&fixtureEntries, &fixtureAllowed, "src/database.zig", "src/trees/column.zig"));
    try testing.expectEqual(ImportScanner.Verdict.allowed, classify(&fixtureEntries, &fixtureAllowed, "src/platform.zig", "src/storage/reference.zig"));
    try testing.expectEqual(ImportScanner.Verdict.allowed, classify(&fixtureEntries, &fixtureAllowed, "src/airdb.zig", "src/platform.zig"));
    try testing.expectEqual(ImportScanner.Verdict.violation, classify(&fixtureEntries, &fixtureAllowed, "src/database.zig", "src/airdb.zig"));
    try testing.expectEqual(ImportScanner.Verdict.unranked, classify(&fixtureEntries, &fixtureAllowed, "src/database.zig", "src/storage/scratch.zig"));
}

test "scanner classifies an importer missing from the table as unranked" {
    const noAllowed = [_]RingTable.AllowedImport{};
    const classify = ImportScanner.classify;
    try testing.expectEqual(ImportScanner.Verdict.unranked, classify(&fixtureEntries, &fixtureAllowed, "src/storage/scratch.zig", "src/platform.zig"));
    try testing.expectEqual(ImportScanner.Verdict.unranked, classify(&fixtureEntries, &noAllowed, "src/storage/scratch.zig", "src/platform.zig"));

    // An inward-looking target does not rescue an importer with no ring.
    const verdicts = try verdictsFor(testing.allocator, "src/storage/scratch.zig",
        \\const platform = @import("../platform.zig");
        \\const reference = @import("reference.zig");
        \\
    );
    defer testing.allocator.free(verdicts);
    try testing.expectEqualSlices(ImportScanner.Verdict, &.{ .unranked, .unranked }, verdicts);
}

test "scanner skips the body of a quoted string" {
    // An unskipped "}" would close the test block early and expose hidden.zig.
    try expectArguments(
        \\const node = @import("node.zig");
        \\test {
        \\    const text = "}";
        \\    _ = @import("hidden.zig");
        \\}
        \\
    , &.{"node.zig"});
}

// Check tests on in-memory files. They record and check through the same functions as the real-tree gate.

/// One in-memory source file, keyed by its path from the repo root.
const FixtureFile = struct { path: []const u8, bytes: []const u8 };

/// Records every fixture file, runs the shared check and returns its report. Memory lives in `arena`.
fn checkFixture(arena: *std.heap.ArenaAllocator, files: []const FixtureFile) !struct { failed: bool, report: []const u8 } {
    const allocator = arena.allocator();
    var edges: std.ArrayList(Edge) = .empty;
    var unresolved: std.ArrayList(Unresolved) = .empty;
    for (files) |file| {
        try recordFile(allocator, &edges, &unresolved, file.path, file.bytes, &fixtureIgnored);
    }
    var report: std.Io.Writer.Allocating = .init(allocator);
    checkInwardDependencies(&report.writer, &fixtureEntries, &fixtureAllowed, edges.items, unresolved.items) catch |err| switch (err) {
        error.InwardDependencyViolation => return .{ .failed = true, .report = report.written() },
        else => |other| return other,
    };
    return .{ .failed = false, .report = report.written() };
}

/// Expects the shared check to fail on `files` with a report that names `expected`.
fn expectCheckFails(files: []const FixtureFile, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try checkFixture(&arena, files);
    try testing.expect(result.failed);
    if (std.mem.indexOf(u8, result.report, expected) == null) {
        std.debug.print("expected \"{s}\" in the report:\n{s}", .{ expected, result.report });
        return error.TestExpectedReport;
    }
}

/// Expects the shared check to pass on `files` with an empty report.
fn expectCheckPasses(files: []const FixtureFile) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try checkFixture(&arena, files);
    if (result.failed) std.debug.print("unexpected report:\n{s}", .{result.report});
    try testing.expect(!result.failed);
    try testing.expectEqual(@as(usize, 0), result.report.len);
}

test "an inward fixture passes the inward-dependency check" {
    try expectCheckPasses(&.{
        .{ .path = "src/trees/column.zig", .bytes =
        \\const std = @import("std");
        \\const reference = @import("../storage/reference.zig");
        \\test {
        \\    _ = @import("columnTests.zig");
        \\}
        \\
        },
        .{ .path = "src/storage/fileStore.zig", .bytes =
        \\const platform = @import("../platform.zig");
        \\
        },
    });
}

test "an import that leaves src fails the inward-dependency check" {
    try expectCheckFails(&.{.{ .path = "src/database.zig", .bytes =
        \\const build = @import("../build.zig");
        \\
    }}, "src/database.zig:1: cannot check import \"../build.zig\": path leaves src/");
}

test "an unknown module name in a scanned file fails the inward-dependency check" {
    try expectCheckFails(&.{.{ .path = "src/database.zig", .bytes =
        \\const std = @import("std");
        \\const options = @import("build_options");
        \\
    }}, "src/database.zig:2: cannot check import \"build_options\": named module is not in ignoredModuleNames");
}

test "an unranked importer fails the inward-dependency check" {
    try expectCheckFails(&.{.{ .path = "src/storage/scratch.zig", .bytes =
        \\const platform = @import("../platform.zig");
        \\
    }}, "src/storage/scratch.zig:1: no ring (0) imports infrastructure (3) src/platform.zig");
}

test "an outward fixture import fails the inward-dependency check" {
    try expectCheckFails(&.{.{ .path = "src/trees/column.zig", .bytes =
        \\const platform = @import("../platform.zig");
        \\
    }}, "src/trees/column.zig:1: domain (2) imports infrastructure (3) src/platform.zig");
}

test "a production file importing a Tests.zig file outside a test block is flagged" {
    try expectCheckFails(&.{.{ .path = "src/trees/column.zig", .bytes =
        \\const tests = @import("columnTests.zig");
        \\
    }}, "src/trees/column.zig:1: cannot check import \"columnTests.zig\": test file imported outside a test block");

    // The same import inside a test block is how production files pull in their tests.
    try expectCheckPasses(&.{.{ .path = "src/trees/column.zig", .bytes =
        \\test {
        \\    _ = @import("columnTests.zig");
        \\}
        \\
    }});
}

// Seeded fuzz test over generated files.

/// One generated source fragment. Each "#" becomes a unique number.
const Fragment = struct {
    text: []const u8,
    /// Suffix of the one real import in the fragment, or null if every import in it is hidden.
    realSuffix: ?[]const u8,
};

const fragments = [_]Fragment{
    .{ .text = "const real# = @import(\"real#.zig\");\n", .realSuffix = ".zig" },
    .{ .text = "const real# = @embedFile( \"real#.zon\" );\n", .realSuffix = ".zon" },
    .{ .text = "pub const Holder# = struct {\n    const inner = @import(\"real#.zig\");\n};\n", .realSuffix = ".zig" },
    .{ .text = "const text# = \"{ }}\"; const real# = @import(\"real#.zig\");\n", .realSuffix = ".zig" },
    .{ .text = "const brace# = '{'; const real# = @import(\"real#.zig\");\n", .realSuffix = ".zig" },
    .{ .text = "fn helper#() void {\n    const latest = @import(\"real#.zig\");\n    _ = latest;\n}\n", .realSuffix = ".zig" },
    .{ .text = "// const hidden = @import(\"hidden#.zig\");\n", .realSuffix = null },
    .{ .text = "/// @import(\"hidden#.zig\") {\n", .realSuffix = null },
    .{ .text = "const lines# =\n    \\\\@import(\"hidden#.zig\") }\n;\n", .realSuffix = null },
    .{ .text = "test \"name # {\" {\n    const hidden = @import(\"hidden#.zig\");\n    if (true) { _ = \"}\"; }\n}\n", .realSuffix = null },
    .{ .text = "test name# {\n    _ = @import(\"hidden#.zig\");\n}\n", .realSuffix = null },
    .{ .text = "test {\n    _ = @embedFile(\"hidden#.zig\");\n    { { } }\n}\n", .realSuffix = null },
    .{ .text = "const quote# = '\"'; // @import(\"hidden#.zig\")\n", .realSuffix = null },
};

/// Pieces of a random string literal body. Braces and escaped quotes must not leak out.
const stringPieces = [_][]const u8{ "{", "}", "{{", "}}", " ", "'", "\\\"", "\\\\", "@import(\\\"hidden.zig\\\")", "//" };

const ExpectedImport = struct { line: u32, argument: []const u8 };

fn appendTemplate(allocator: Allocator, out: *std.ArrayList(u8), template: []const u8, number: usize) !void {
    for (template) |char| {
        if (char == '#') {
            try out.print(allocator, "{d}", .{number});
        } else {
            try out.append(allocator, char);
        }
    }
}

test "scanner fuzz finds every real import and no hidden one" {
    const seed: u64 = testing.random_seed;
    // The test runner also passes this value as --seed. Printing it on a
    // passing run writes to stderr. On Zig 0.17.1, zig build then can show a
    // "failed command" line even though every test passed and the exit code
    // is 0. Print only on failure so a passing gate stays quiet. Repeat a
    // failing run with --seed.
    errdefer std.debug.print("import scanner fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var iteration: usize = 0;
    while (iteration < 300) : (iteration += 1) {
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();

        var source: std.ArrayList(u8) = .empty;
        var expected: std.ArrayList(ExpectedImport) = .empty;
        var line: u32 = 1;
        var number: usize = 0;
        const fragmentCount = 1 + random.uintLessThan(usize, 30);
        for (0..fragmentCount) |_| {
            number += 1;
            if (random.uintLessThan(u8, 4) == 0) {
                // A random string literal with braces that must not move the depth.
                try source.appendSlice(allocator, "const noise = \"");
                for (0..random.uintLessThan(usize, 8)) |_| {
                    try source.appendSlice(allocator, stringPieces[random.uintLessThan(usize, stringPieces.len)]);
                }
                try source.appendSlice(allocator, "\";\n");
                line += 1;
                continue;
            }
            const fragment = fragments[random.uintLessThan(usize, fragments.len)];
            const start = source.items.len;
            try appendTemplate(allocator, &source, fragment.text, number);
            const text = source.items[start..];
            if (fragment.realSuffix) |suffix| {
                const argument = try std.fmt.allocPrint(allocator, "real{d}{s}", .{ number, suffix });
                const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{argument});
                const offset = std.mem.indexOf(u8, text, quoted).?;
                const lineOffset: u32 = @intCast(std.mem.countScalar(u8, text[0..offset], '\n'));
                try expected.append(allocator, .{ .line = line + lineOffset, .argument = argument });
            }
            line += @intCast(std.mem.countScalar(u8, text, '\n'));
        }

        const found = try ImportScanner.parse(allocator, source.items);
        var mismatch = false;
        for (found) |site| {
            var wanted = false;
            for (expected.items) |want| {
                if (want.line == site.line and std.mem.eql(u8, want.argument, site.argument)) wanted = true;
            }
            if (!wanted) {
                std.debug.print("false positive at line {d}: \"{s}\"\n", .{ site.line, site.argument });
                mismatch = true;
            }
        }
        for (expected.items) |want| {
            var seen = false;
            for (found) |site| {
                if (want.line == site.line and std.mem.eql(u8, want.argument, site.argument)) seen = true;
            }
            if (!seen) {
                std.debug.print("false negative at line {d}: \"{s}\"\n", .{ want.line, want.argument });
                mismatch = true;
            }
        }
        if (mismatch) {
            std.debug.print("iteration {d}, source:\n{s}\n", .{ iteration, source.items });
            return error.ScannerFuzzMismatch;
        }
    }
}

// Seeded fuzz tests over classify and resolve.

/// Returns true when the pair appears in `allowed`. Kept apart from isAllowlisted so the fuzz does not trust it.
fn pairListed(allowed: []const RingTable.AllowedImport, from: []const u8, to: []const u8) bool {
    for (allowed) |pair| {
        if (std.mem.eql(u8, pair.from, from) and std.mem.eql(u8, pair.to, to)) return true;
    }
    return false;
}

/// True when the rule lets `from` import `to`, read straight from the Ring doc comment.
fn pointsInward(from: RingTable.Entry, to: RingTable.Entry) bool {
    const fromLevel = @backingInt(from.ring);
    const toLevel = @backingInt(to.ring);
    if (toLevel < fromLevel) return true;
    if (toLevel > fromLevel) return false;
    return from.ring != .infrastructure or std.mem.eql(u8, from.path, to.path);
}

/// Picks a random table entry that `from` may import when `inward` is true, or one it may not when false.
fn pickTarget(random: std.Random, from: RingTable.Entry, inward: bool) ?RingTable.Entry {
    var candidates: [RingTable.entries.len]RingTable.Entry = undefined;
    var count: usize = 0;
    for (RingTable.entries) |entry| {
        if (pointsInward(from, entry) == inward) {
            candidates[count] = entry;
            count += 1;
        }
    }
    if (count == 0) return null;
    return candidates[random.uintLessThan(usize, count)];
}

/// Writes 1 to 6 random lowercase letters. Lowercase alone can never spell a Tests.zig suffix.
fn appendName(allocator: Allocator, out: *std.ArrayList(u8), random: std.Random) !void {
    const length = 1 + random.uintLessThan(usize, 6);
    for (0..length) |_| try out.append(allocator, 'a' + random.uintLessThan(u8, 26));
}

fn appendSeparator(allocator: Allocator, out: *std.ArrayList(u8), random: std.Random) !void {
    try out.append(allocator, if (random.uintLessThan(u8, 4) == 0) '\\' else '/');
}

test "classify fuzz allows every inward edge and flags every outward or sideways Infrastructure edge" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("classify fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const entries = &RingTable.entries;
    const allowed = &RingTable.allowedImports;
    const noAllowed = [_]RingTable.AllowedImport{};
    var unrankedBuffer: [64]u8 = undefined;

    var iteration: usize = 0;
    while (iteration < 400) : (iteration += 1) {
        const from = entries[random.uintLessThan(usize, entries.len)];
        switch (random.uintLessThan(u8, 3)) {
            0 => {
                // Every file can at least import itself, so an inward target always exists.
                const to = pickTarget(random, from, true).?;
                try testing.expectEqual(ImportScanner.Verdict.allowed, ImportScanner.classify(entries, &noAllowed, from.path, to.path));
                try testing.expectEqual(ImportScanner.Verdict.allowed, ImportScanner.classify(entries, allowed, from.path, to.path));
            },
            1 => {
                // Composition has nothing above it, so it has no outward target.
                const to = pickTarget(random, from, false) orelse continue;
                try testing.expectEqual(ImportScanner.Verdict.violation, ImportScanner.classify(entries, &noAllowed, from.path, to.path));
                const expected: ImportScanner.Verdict = if (pairListed(allowed, from.path, to.path)) .allowlisted else .violation;
                try testing.expectEqual(expected, ImportScanner.classify(entries, allowed, from.path, to.path));
            },
            else => {
                const unranked = try std.fmt.bufPrint(&unrankedBuffer, "src/unranked/file{d}.zig", .{random.int(u32)});
                const pairs = [_][2][]const u8{
                    .{ unranked, from.path },
                    .{ from.path, unranked },
                    .{ unranked, unranked },
                };
                for (pairs) |pair| {
                    try testing.expectEqual(ImportScanner.Verdict.unranked, ImportScanner.classify(entries, &noAllowed, pair[0], pair[1]));
                    try testing.expectEqual(ImportScanner.Verdict.unranked, ImportScanner.classify(entries, allowed, pair[0], pair[1]));
                }
            },
        }
    }
}

test "resolve fuzz normalises paths under src and rejects every other target" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("resolve fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ignored = &RingTable.ignoredModuleNames;

    var iteration: usize = 0;
    while (iteration < 400) : (iteration += 1) {
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();

        const importer = RingTable.entries[random.uintLessThan(usize, RingTable.entries.len)].path;
        var directory: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.tokenizeScalar(u8, importer, '/');
        while (parts.next()) |part| try directory.append(allocator, part);
        // Drop the file name. What is left starts with "src".
        _ = directory.pop();
        const depth = directory.items.len;

        var argument: std.ArrayList(u8) = .empty;
        const kind = random.uintLessThan(u8, 5);
        switch (kind) {
            0, 1 => {
                // Climb at most to src, or to the root and back into src, then descend to a new file.
                var expected: std.ArrayList(u8) = .empty;
                const climbToRoot = random.uintLessThan(u8, 4) == 0;
                const ups = if (climbToRoot) depth else random.uintLessThan(usize, depth);
                for (0..ups) |_| {
                    if (random.uintLessThan(u8, 4) == 0) {
                        try argument.append(allocator, '.');
                        try appendSeparator(allocator, &argument, random);
                    }
                    try argument.appendSlice(allocator, "..");
                    try appendSeparator(allocator, &argument, random);
                }
                if (climbToRoot) {
                    try argument.appendSlice(allocator, "src");
                    try appendSeparator(allocator, &argument, random);
                    try expected.appendSlice(allocator, "src");
                } else {
                    for (directory.items[0 .. depth - ups], 0..) |part, index| {
                        if (index > 0) try expected.append(allocator, '/');
                        try expected.appendSlice(allocator, part);
                    }
                }
                for (0..random.uintLessThan(usize, 3)) |_| {
                    const start = argument.items.len;
                    try appendName(allocator, &argument, random);
                    try expected.append(allocator, '/');
                    try expected.appendSlice(allocator, argument.items[start..]);
                    try appendSeparator(allocator, &argument, random);
                }
                const start = argument.items.len;
                try appendName(allocator, &argument, random);
                const testTarget = kind == 1;
                try argument.appendSlice(allocator, if (testTarget) "Tests.zig" else ".zig");
                try expected.append(allocator, '/');
                try expected.appendSlice(allocator, argument.items[start..]);

                const resolution = try ImportScanner.resolve(allocator, importer, argument.items, ignored);
                if (testTarget) {
                    try testing.expectEqual(ImportScanner.Resolution.testFile, resolution);
                } else {
                    if (resolution != .file) {
                        std.debug.print("{s} imports \"{s}\": expected a file, got {s}\n", .{ importer, argument.items, @tagName(resolution) });
                        return error.TestUnexpectedResolution;
                    }
                    try testing.expectEqualStrings(expected.items, resolution.file);
                }
            },
            2 => {
                switch (random.uintLessThan(u8, 4)) {
                    0 => {
                        // More ".." than the importer has directories.
                        for (0..depth + 1 + random.uintLessThan(usize, 3)) |_| {
                            try argument.appendSlice(allocator, "..");
                            try appendSeparator(allocator, &argument, random);
                        }
                    },
                    1 => {
                        // Up to the repo root, then into a sibling of src.
                        for (0..depth) |_| {
                            try argument.appendSlice(allocator, "..");
                            try appendSeparator(allocator, &argument, random);
                        }
                        if (random.boolean()) {
                            try argument.appendSlice(allocator, "out");
                            try appendName(allocator, &argument, random);
                            try appendSeparator(allocator, &argument, random);
                        }
                    },
                    2 => try appendSeparator(allocator, &argument, random),
                    else => try argument.appendSlice(allocator, "C:/"),
                }
                try appendName(allocator, &argument, random);
                try argument.appendSlice(allocator, if (random.boolean()) ".zig" else ".zon");
                const resolution = try ImportScanner.resolve(allocator, importer, argument.items, ignored);
                if (resolution != .escapesSource) {
                    std.debug.print("{s} imports \"{s}\": expected escapesSource, got {s}\n", .{ importer, argument.items, @tagName(resolution) });
                    return error.TestUnexpectedResolution;
                }
            },
            3 => {
                const name = ignored[random.uintLessThan(usize, ignored.len)];
                try testing.expectEqual(ImportScanner.Resolution.ignoredModule, try ImportScanner.resolve(allocator, importer, name, ignored));
            },
            else => {
                try appendName(allocator, &argument, random);
                if (random.boolean()) try argument.append(allocator, '_');
                // A random name may spell an ignored one, so a suffix keeps it unknown.
                for (ignored) |name| {
                    if (std.mem.eql(u8, name, argument.items)) try argument.appendSlice(allocator, "_x");
                }
                const resolution = try ImportScanner.resolve(allocator, importer, argument.items, ignored);
                if (resolution != .unknownModule) {
                    std.debug.print("{s} imports \"{s}\": expected unknownModule, got {s}\n", .{ importer, argument.items, @tagName(resolution) });
                    return error.TestUnexpectedResolution;
                }
            },
        }
    }
}
