//! Query terminals over a relocated row, with the abandoned slot poisoned.
//!
//! On a fresh catalog the object key equals the physical row, so a terminal
//! that reads a property through the key instead of the row passes every
//! ordinary test. Each test here relocates one row and reads it back through a
//! terminal. The slot the row left holds the poison value, so a read through
//! the wrong index returns a value no hand-written answer contains.
//!
//! Fixture, properties primaryKey and value (indexed only where a test says so). After the throwaway is
//! deleted and B is relocated into its slot:
//!   key 1 row 1: A, value 30
//!   key 2 row 0: B, value 40 (row 2 is poisoned)
//!   key 3 row 3: C, value 40

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const rows = @import("records/rows.zig");
const typeDirectory = @import("schema/typeDirectory.zig");
const typeRouting = @import("schema/typeRouting.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const WriteTransaction = @import("database.zig").WriteTransaction;
const relocationFixture = @import("storage/relocationFixtureTests.zig").RelocationFixtureTests;

const valueProperty: usize = 1;
const everything: query.Predicate = .{ .conjunction = &.{} };

fn tmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..length], name });
}

const Fixture = struct {
    catalogReference: Reference,
    keyA: u64,
    keyB: u64,
    keyC: u64,
};

fn seedRelocated(transaction: *WriteTransaction, indexed: bool) !Fixture {
    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .int, .indexed = indexed } };
    var catalogReference = try catalog.createFromDefinitions(transaction, &definitions);
    const throwaway = try rows.insert(transaction, catalogReference, &.{ 1, 99 });
    catalogReference = throwaway.catalogReference;
    const a = try rows.insert(transaction, catalogReference, &.{ 2, 30 });
    catalogReference = a.catalogReference;
    const b = try rows.insert(transaction, catalogReference, &.{ 3, 40 });
    catalogReference = b.catalogReference;
    const c = try rows.insert(transaction, catalogReference, &.{ 4, 40 });
    catalogReference = c.catalogReference;

    const deadRow = (try catalog.objectKeyToRow(transaction, catalogReference, throwaway.objectKey)).?;
    var cells: [2]u64 = undefined;
    const version = (try rows.getByPrimaryKey(transaction, catalogReference, 1, &cells)).?;
    catalogReference = (try rows.delete(transaction, catalogReference, 1, version)).ok;
    const relocated = try relocationFixture.relocateAndPoison(transaction, catalogReference, b.objectKey, deadRow);
    // The divergence this suite relies on: B's key names the slot it left.
    try testing.expectEqual(@as(?u64, b.objectKey), relocated.abandonedRow);
    try testing.expect(deadRow != b.objectKey);
    return .{ .catalogReference = relocated.catalogReference, .keyA = a.objectKey, .keyB = b.objectKey, .keyC = c.objectKey };
}

test "aggregateInt reads each value at the row the key resolves to, after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "reloc_aggregate.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seedRelocated(&transaction, false);

    const aggregate = try query.aggregateInt(&transaction, fixture.catalogReference, valueProperty, everything, testing.allocator);
    try testing.expectEqual(@as(u64, 3), aggregate.count);
    try testing.expectEqual(@as(u64, 110), aggregate.sum);
    try testing.expectEqual(@as(?u64, 30), aggregate.min);
    try testing.expectEqual(@as(?u64, 40), aggregate.max);
}

test "cursorAfter reads the sort value at the row the key resolves to, after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "reloc_cursor.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seedRelocated(&transaction, false);

    const resumePoint = try query.cursorAfter(&transaction, fixture.catalogReference, .{ .sortKey = .{ .property = valueProperty } }, fixture.keyB);
    try testing.expectEqual(@as(u64, 40), resumePoint.lastValue);
    try testing.expectEqual(fixture.keyB, resumePoint.lastObjectKey);
}

test "sortByProperty reads each value at the row the key resolves to, after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "reloc_sort.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seedRelocated(&transaction, false);

    // B and C tie at 40 and break by key. A poisoned B would sort last instead.
    var keys = [_]u64{ fixture.keyC, fixture.keyB, fixture.keyA };
    try query.sortByProperty(&transaction, fixture.catalogReference, &keys, valueProperty, .ascending, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ fixture.keyA, fixture.keyB, fixture.keyC }, &keys);
}

test "where ordered by an unindexed property reads each value at the resolved row, after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "reloc_where_order.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seedRelocated(&transaction, false);

    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try query.where(&transaction, fixture.catalogReference, .{ .ordering = .{ .sortKey = .{ .property = valueProperty } } }, &out, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ fixture.keyA, fixture.keyB, fixture.keyC }, out.items);
}

test "where ordered by an indexed property keeps a relocated row, after relocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "reloc_where_indexed.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seedRelocated(&transaction, true);

    // The index yields keys and the walk resolves each to its row. Resolving B
    // through its key would land on the dead abandoned slot and drop it.
    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try query.where(&transaction, fixture.catalogReference, .{ .ordering = .{ .sortKey = .{ .property = valueProperty } } }, &out, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ fixture.keyA, fixture.keyB, fixture.keyC }, out.items);
}

test "where over an index candidate set keeps a relocated row in both directions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "reloc_where_candidates.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seedRelocated(&transaction, true);

    const equalsForty: query.Predicate = .{ .comparison = .{ .property = valueProperty, .operator = .eq, .value = .{ .int = 40 } } };
    var ascending = std.ArrayList(u64).empty;
    defer ascending.deinit(testing.allocator);
    try query.where(&transaction, fixture.catalogReference, .{ .predicate = equalsForty }, &ascending, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ fixture.keyB, fixture.keyC }, ascending.items);

    var descending = std.ArrayList(u64).empty;
    defer descending.deinit(testing.allocator);
    try query.where(&transaction, fixture.catalogReference, .{ .predicate = equalsForty, .ordering = .{ .order = .descending } }, &descending, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ fixture.keyC, fixture.keyB }, descending.items);
}

test "materializePage reads a relocated root's liveness, version and values at the resolved row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "reloc_materialize.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();

    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .int } };
    var directoryReference = try typeDirectory.createWithDefinitions(&transaction, &.{&definitions});
    const throwaway = try typeRouting.insert(&transaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .int = 99 } });
    directoryReference = throwaway.directoryReference;
    const target = try typeRouting.insert(&transaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .int = 40 } });
    directoryReference = target.directoryReference;

    var values: [2]catalog.Value = undefined;
    const targetVersion = (try typeRouting.get(&transaction, directoryReference, 0, 2, &values)).?;
    const throwawayVersion = (try typeRouting.get(&transaction, directoryReference, 0, 1, &values)).?;
    const deadRow = (try catalog.objectKeyToRow(&transaction, try typeDirectory.catalogReference(&transaction, directoryReference, 0), throwaway.objectKey)).?;
    directoryReference = (try typeRouting.delete(&transaction, directoryReference, 0, 1, throwawayVersion)).ok;

    const catalogReference = try typeDirectory.catalogReference(&transaction, directoryReference, 0);
    const relocated = try relocationFixture.relocateAndPoison(&transaction, catalogReference, target.objectKey, deadRow);
    try testing.expectEqual(@as(?u64, target.objectKey), relocated.abandonedRow);
    directoryReference = try typeDirectory.setCatalogReference(&transaction, directoryReference, 0, relocated.catalogReference);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const roots = try query.materializePage(&transaction, directoryReference, 0, .{}, .{}, arena.allocator());
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(target.objectKey, roots[0].objectKey);
    try testing.expectEqual(targetVersion, roots[0].version);
    try testing.expectEqual(query.PropertyValue{ .int = 2 }, roots[0].values[0]);
    try testing.expectEqual(query.PropertyValue{ .int = 40 }, roots[0].values[1]);
}
