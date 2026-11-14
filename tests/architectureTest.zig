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
        const imports = try ImportScanner.parse(allocator, bytes);
        for (imports) |site| {
            const resolution = try ImportScanner.resolve(allocator, path, site.argument, &RingTable.ignoredModuleNames);
            switch (resolution) {
                .file => |target| try edges.append(allocator, .{ .from = path, .to = target, .line = site.line }),
                .testFile, .ignoredModule => {},
                .escapesSource => try unresolved.append(allocator, .{
                    .from = path,
                    .line = site.line,
                    .argument = site.argument,
                    .reason = "path leaves src/",
                }),
                .unknownModule => try unresolved.append(allocator, .{
                    .from = path,
                    .line = site.line,
                    .argument = site.argument,
                    .reason = "named module is not in ignoredModuleNames",
                }),
            }
        }
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
    return if (ring) |known| @intFromEnum(known) else 0;
}

// Gate tests over the real tree.

test "every production import in src points inward under the ring table" {
    var tree = try loadSourceTree(testing.allocator);
    defer tree.deinit();

    var failures: usize = 0;
    for (tree.unresolved) |site| {
        std.debug.print("{s}:{d}: cannot check import \"{s}\": {s}\n", .{ site.from, site.line, site.argument, site.reason });
        failures += 1;
    }
    for (tree.edges) |edge| {
        const verdict = ImportScanner.classify(&RingTable.entries, &RingTable.allowedImports, edge.from, edge.to);
        switch (verdict) {
            .allowed, .allowlisted => {},
            .violation, .unranked => {
                const fromRing = ImportScanner.ringOf(&RingTable.entries, edge.from);
                const toRing = ImportScanner.ringOf(&RingTable.entries, edge.to);
                std.debug.print("{s}:{d}: {s} ({d}) imports {s} ({d}) {s}\n", .{
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
        std.debug.print("{d} import(s) break the inward-dependency rule. See tests/architecture/ringTable.zig.\n", .{failures});
        return error.InwardDependencyViolation;
    }
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
    // passing run writes to stderr, and zig build then marks the step with
    // "w" and "failed command" even when every test passed. Print only on
    // failure so a passing gate stays quiet. Repeat a failing run with --seed.
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
