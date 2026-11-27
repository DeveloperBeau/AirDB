//! Every public query terminal, instantiated with a `*ReadTransaction`.
//!
//! The terminals are generic over the transaction type and the rest of the
//! query suites drive them with a `WriteTransaction`, so their bodies are never
//! compiled against the production read path. Each test here commits a small
//! fixture, opens a real read transaction and asserts a hand-written answer.
//!
//! Fixture, type 0 "Item": primaryKey, score (indexed), bucket (unindexed).
//!   objectKey 0: (1, 30, 1)
//!   objectKey 1: (2, 10, 2)
//!   objectKey 2: (3, 20, 1)
//!   objectKey 3: (4, 10, 2)
//!   objectKey 4: (5, 40, 1)
//! Type 1 "Note": primaryKey, link to an Item. Note objectKey 0 links Item 2.

const std = @import("std");
const testing = std.testing;
const query = @import("query.zig");
const catalog = @import("schema/catalog.zig");
const typeDirectory = @import("schema/typeDirectory.zig");
const typeRouting = @import("schema/typeRouting.zig");
const Reference = @import("storage/reference.zig").Reference;
const Database = @import("database.zig").Database;
const ReadTransaction = @import("transactions/readTransaction.zig").ReadTransaction;

const Predicate = query.Predicate;
const Operator = query.Operator;
const Group = query.Group;

const itemType: u16 = 0;
const noteType: u16 = 1;
const scoreProperty: usize = 1;
const bucketProperty: usize = 2;
const noteLinkProperty: usize = 1;

fn tmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..length], name });
}

fn scoreIs(operator: Operator, value: u64) Predicate {
    return .{ .comparison = .{ .property = scoreProperty, .operator = operator, .value = .{ .int = value } } };
}

const everything: Predicate = .{ .conjunction = &.{} };

/// Commits the fixture. The caller then opens a read transaction on `database`.
fn commitFixture(database: *Database) !void {
    var writeTransaction = try database.beginWrite();
    const itemDefinitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .int, .indexed = true }, .{ .kind = .int } };
    const noteDefinitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = itemType } };
    var directoryReference = try typeDirectory.createWithDefinitions(&writeTransaction, &.{ &itemDefinitions, &noteDefinitions });
    const items = [_][3]u64{ .{ 1, 30, 1 }, .{ 2, 10, 2 }, .{ 3, 20, 1 }, .{ 4, 10, 2 }, .{ 5, 40, 1 } };
    var itemKeys: [items.len]u64 = undefined;
    for (items, 0..) |item, position| {
        const inserted = try typeRouting.insert(&writeTransaction, directoryReference, itemType, &.{ .{ .int = item[0] }, .{ .int = item[1] }, .{ .int = item[2] } });
        directoryReference = inserted.directoryReference;
        itemKeys[position] = inserted.objectKey;
    }
    const note = try typeRouting.insert(&writeTransaction, directoryReference, noteType, &.{ .{ .int = 1 }, .{ .link = itemKeys[2] } });
    directoryReference = note.directoryReference;
    writeTransaction.setRoot(directoryReference, .typeDirectory);
    _ = try writeTransaction.commit();
}

fn itemCatalog(readTransaction: *ReadTransaction) !Reference {
    return typeDirectory.catalogReference(readTransaction, readTransaction.root(), itemType);
}

test "where compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_where.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();

    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try query.where(&readTransaction, try itemCatalog(&readTransaction), .{ .predicate = scoreIs(.ge, 20) }, &out, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ 0, 2, 4 }, out.items);
}

test "countWhere compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_count.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();

    try testing.expectEqual(@as(u64, 2), try query.countWhere(&readTransaction, try itemCatalog(&readTransaction), scoreIs(.eq, 10), testing.allocator));
}

test "aggregateInt compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_aggregate.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();

    const aggregate = try query.aggregateInt(&readTransaction, try itemCatalog(&readTransaction), scoreProperty, everything, testing.allocator);
    try testing.expectEqual(@as(u64, 5), aggregate.count);
    try testing.expectEqual(@as(u64, 110), aggregate.sum);
    try testing.expectEqual(@as(?u64, 10), aggregate.min);
    try testing.expectEqual(@as(?u64, 40), aggregate.max);
}

test "distinct compiles and runs against a ReadTransaction, indexed and unindexed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_distinct.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try itemCatalog(&readTransaction);

    // Indexed score: 10 (lowest key 1), 20 (key 2), 30 (key 0), 40 (key 4).
    var indexed = std.ArrayList(u64).empty;
    defer indexed.deinit(testing.allocator);
    try query.distinct(&readTransaction, catalogReference, scoreProperty, everything, .{}, &indexed, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 0, 4 }, indexed.items);

    // Unindexed bucket: 1 (lowest key 0), 2 (lowest key 1).
    var unindexed = std.ArrayList(u64).empty;
    defer unindexed.deinit(testing.allocator);
    try query.distinct(&readTransaction, catalogReference, bucketProperty, everything, .{}, &unindexed, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, unindexed.items);
}

test "groupBy compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_group.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();

    var out = std.ArrayList(Group).empty;
    defer out.deinit(testing.allocator);
    try query.groupBy(&readTransaction, try itemCatalog(&readTransaction), .{ .groupProperty = bucketProperty, .aggregateProperty = scoreProperty }, everything, &out, testing.allocator);
    const expected = [_]Group{
        .{ .value = 1, .aggregate = .{ .count = 3, .sum = 90, .min = 20, .max = 40 } },
        .{ .value = 2, .aggregate = .{ .count = 2, .sum = 20, .min = 10, .max = 10 } },
    };
    try testing.expectEqualSlices(Group, &expected, out.items);
}

test "minimum compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_minimum.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try itemCatalog(&readTransaction);

    try testing.expectEqual(@as(?u64, 10), try query.minimum(&readTransaction, catalogReference, scoreProperty, testing.allocator));
    try testing.expectEqual(@as(?u64, 1), try query.minimum(&readTransaction, catalogReference, bucketProperty, testing.allocator));
}

test "maximum compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_maximum.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try itemCatalog(&readTransaction);

    try testing.expectEqual(@as(?u64, 40), try query.maximum(&readTransaction, catalogReference, scoreProperty, testing.allocator));
    try testing.expectEqual(@as(?u64, 2), try query.maximum(&readTransaction, catalogReference, bucketProperty, testing.allocator));
}

test "rangeInclusive compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_range.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();

    var out = std.ArrayList(u64).empty;
    defer out.deinit(testing.allocator);
    try query.rangeInclusive(&readTransaction, try itemCatalog(&readTransaction), scoreProperty, 15, 30, &out, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ 0, 2 }, out.items);
}

test "first compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_first.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try itemCatalog(&readTransaction);

    // Lowest score is 10, held by keys 1 and 3. The tie breaks to the lower key.
    const byScore: query.Request = .{ .ordering = .{ .sortKey = .{ .property = scoreProperty } } };
    try testing.expectEqual(@as(?u64, 1), try query.first(&readTransaction, catalogReference, byScore, testing.allocator));
    try testing.expectEqual(@as(?u64, null), try query.first(&readTransaction, catalogReference, .{ .predicate = scoreIs(.eq, 99) }, testing.allocator));
}

test "exists compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_exists.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try itemCatalog(&readTransaction);

    try testing.expect(try query.exists(&readTransaction, catalogReference, .{ .predicate = scoreIs(.eq, 40) }, testing.allocator));
    try testing.expect(!try query.exists(&readTransaction, catalogReference, .{ .predicate = scoreIs(.eq, 99) }, testing.allocator));
}

test "cursorAfter compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_cursor.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    const catalogReference = try itemCatalog(&readTransaction);

    // Item key 2 has score 20.
    const resumePoint = try query.cursorAfter(&readTransaction, catalogReference, .{ .sortKey = .{ .property = scoreProperty } }, 2);
    try testing.expectEqual(@as(u64, 20), resumePoint.lastValue);
    try testing.expectEqual(@as(u64, 2), resumePoint.lastObjectKey);
}

test "sortByProperty compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_sort.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();

    var keys = [_]u64{ 0, 1, 2, 3, 4 };
    try query.sortByProperty(&readTransaction, try itemCatalog(&readTransaction), &keys, scoreProperty, .ascending, testing.allocator);
    try testing.expectEqualSlices(u64, &.{ 1, 3, 2, 0, 4 }, &keys);
}

test "materializePage compiles and runs against a ReadTransaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "rt_materialize.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitFixture(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const roots = try query.materializePage(
        &readTransaction,
        readTransaction.root(),
        noteType,
        .{},
        .{ .linkProperties = &.{noteLinkProperty}, .depth = 1 },
        arena.allocator(),
    );
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqual(@as(u64, 0), roots[0].objectKey);
    try testing.expectEqual(query.PropertyValue{ .int = 1 }, roots[0].values[0]);
    try testing.expectEqual(query.PropertyValue{ .link = 2 }, roots[0].values[noteLinkProperty]);
    try testing.expectEqual(@as(usize, 1), roots[0].included.len);
    const included = switch (roots[0].included[0].target) {
        .object => |object| object,
        else => return error.TestExpectedEqual,
    };
    try testing.expectEqual(@as(u64, 2), included.objectKey);
    try testing.expectEqual(query.PropertyValue{ .int = 20 }, included.values[scoreProperty]);
}
