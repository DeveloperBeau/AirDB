//! Test support: relocate a row and poison the slot it leaves behind.
//!
//! `relocateRow` clears the abandoned slot's live bit but leaves its property
//! and version cells holding an unmodified copy of the moved row. A read routed
//! through the wrong index (the object key where the physical row belongs) would
//! therefore still return the right value and a test would pass by coincidence.
//! `relocateAndPoison` overwrites every one of those cells with `poison`, so such
//! a read returns an unmistakably wrong value or fails to dereference.
//!
//! Poison is one value for every kind, references included. That is safe because
//! no production code dereferences a dead slot's cells: delete only clears the
//! live bit, backfill writes 0 into dead rows, the integrity audits and the
//! compaction passes gate every row on the live column, and freeing a column
//! walks tree nodes and never the references stored in its cells. The value lies
//! far beyond any file the tests create, so reading it as a reference errors out
//! instead of landing on a real node.

const std = @import("std");
const Reference = @import("reference.zig").Reference;
const WriteTransaction = @import("../transactions/writeTransaction.zig").WriteTransaction;
const Column = @import("../trees/column.zig");
const catalog = @import("../schema/catalog.zig");
const relocation = @import("relocation.zig");

/// Relocates a row for a test and poisons the abandoned slot.
pub const RelocationFixtureTests = struct {
    /// What a poisoned cell holds. No fixture uses this value.
    pub const poison: u64 = 0xDEAD_BEEF_BAD0_C0DE;

    /// The catalog after the move and the slot the row left, or null when nothing moved.
    pub const Outcome = struct {
        catalogReference: Reference,
        abandonedRow: ?u64,
    };

    /// Moves `objectKey` into the dead slot `newRow`, then sets every property cell and
    /// the version cell of the slot it left to `poison`. The live bit stays 0.
    /// An unknown key or a move onto the row it already occupies changes nothing, as
    /// with `relocateRow`, and reports a null `abandonedRow`.
    pub fn relocateAndPoison(
        transaction: *WriteTransaction,
        catalogReference: Reference,
        objectKey: u64,
        newRow: u64,
    ) !Outcome {
        const oldRow = (try catalog.objectKeyToRow(transaction, catalogReference, objectKey)) orelse
            return .{ .catalogReference = catalogReference, .abandonedRow = null };
        if (oldRow == newRow) return .{ .catalogReference = catalogReference, .abandonedRow = null };

        const moved = try relocation.relocateRow(transaction, catalogReference, objectKey, newRow);

        var snapshot = try catalog.CatalogSnapshot.load(transaction, moved);
        var propertyIndex: usize = 0;
        while (propertyIndex < snapshot.propertyCount) : (propertyIndex += 1) {
            snapshot.properties[propertyIndex].column = try Column.set(transaction, snapshot.properties[propertyIndex].column, oldRow, poison);
        }
        snapshot.versionColumnReference = try Column.set(transaction, snapshot.versionColumnReference, oldRow, poison);
        return .{ .catalogReference = try snapshot.replace(transaction), .abandonedRow = oldRow };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Database = @import("../database.zig").Database;
const rows = @import("../records/rows.zig");
const blob = @import("../records/blob.zig");
const verification = @import("../verification.zig");
const typeDirectory = @import("../schema/typeDirectory.zig");
const typeRouting = @import("../schema/typeRouting.zig");

fn tmpPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..length], name });
}

/// Rows (primaryKey, price) = (1, 11) deleted, (2, 22), (3, 33). Key 1 and row 0 are free.
const Fixture = struct {
    catalogReference: Reference,
    deadRow: u64,
    keyTwo: u64,
    keyThree: u64,
};

fn seed(transaction: *WriteTransaction) !Fixture {
    var catalogReference = try catalog.createFromDefinitions(transaction, &.{ .{ .kind = .int }, .{ .kind = .int }, .{ .kind = .blob } });
    const first = try rows.insert(transaction, catalogReference, &.{ 1, 11, try blob.put(transaction, "one") });
    catalogReference = first.catalogReference;
    const second = try rows.insert(transaction, catalogReference, &.{ 2, 22, try blob.put(transaction, "two") });
    catalogReference = second.catalogReference;
    const third = try rows.insert(transaction, catalogReference, &.{ 3, 33, try blob.put(transaction, "three") });
    catalogReference = third.catalogReference;

    const deadRow = (try catalog.objectKeyToRow(transaction, catalogReference, first.objectKey)).?;
    var cells: [3]u64 = undefined;
    const version = (try rows.getByPrimaryKey(transaction, catalogReference, 1, &cells)).?;
    catalogReference = (try rows.delete(transaction, catalogReference, 1, version)).ok;
    return .{ .catalogReference = catalogReference, .deadRow = deadRow, .keyTwo = second.objectKey, .keyThree = third.objectKey };
}

test "relocateAndPoison moves the row and poisons every cell of the abandoned slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "fixture1.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seed(&transaction);

    var cells: [3]u64 = undefined;
    const versionBefore = (try rows.getByObjectKey(&transaction, fixture.catalogReference, fixture.keyThree, &cells)).?;
    const oldRow = (try catalog.objectKeyToRow(&transaction, fixture.catalogReference, fixture.keyThree)).?;
    try testing.expect(oldRow != fixture.deadRow);

    const outcome = try RelocationFixtureTests.relocateAndPoison(&transaction, fixture.catalogReference, fixture.keyThree, fixture.deadRow);
    try testing.expectEqual(@as(?u64, oldRow), outcome.abandonedRow);

    // The key resolves to the new row, and the object reads back unchanged there.
    try testing.expectEqual(@as(?u64, fixture.deadRow), try catalog.objectKeyToRow(&transaction, outcome.catalogReference, fixture.keyThree));
    var out: [3]u64 = undefined;
    const versionAfter = (try rows.getByObjectKey(&transaction, outcome.catalogReference, fixture.keyThree, &out)).?;
    try testing.expectEqual(versionBefore, versionAfter);
    try testing.expectEqual(@as(u64, 3), out[0]);
    try testing.expectEqual(@as(u64, 33), out[1]);
    try testing.expectEqualStrings("three", try blob.get(&transaction, out[2]));

    // The abandoned slot is dead and every cell, version included, holds the poison.
    const view = try catalog.loadCatalog(&transaction, outcome.catalogReference);
    try testing.expectEqual(@as(u64, 0), try Column.get(&transaction, view.liveColumnReference, oldRow));
    try testing.expectEqual(@as(u64, 1), try Column.get(&transaction, view.liveColumnReference, fixture.deadRow));
    var propertyIndex: usize = 0;
    while (propertyIndex < 3) : (propertyIndex += 1) {
        try testing.expectEqual(RelocationFixtureTests.poison, try Column.get(&transaction, view.propertyColumnReference(propertyIndex), oldRow));
    }
    try testing.expectEqual(RelocationFixtureTests.poison, try Column.get(&transaction, view.versionColumnReference, oldRow));

    // The untouched live row keeps its own values.
    const keyTwoVersion = try rows.getByObjectKey(&transaction, outcome.catalogReference, fixture.keyTwo, &out);
    try testing.expect(keyTwoVersion != null);
    try testing.expectEqual(@as(u64, 22), out[1]);
}

test "a poisoned blob reference fails to dereference instead of reading a real node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "fixture2.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();

    try testing.expect(RelocationFixtureTests.poison > 1 << 40);
    if (blob.get(&transaction, RelocationFixtureTests.poison)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "relocateAndPoison on an unknown key changes nothing and reports no abandoned row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "fixture3.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seed(&transaction);

    const outcome = try RelocationFixtureTests.relocateAndPoison(&transaction, fixture.catalogReference, 9999, fixture.deadRow);
    try testing.expectEqual(fixture.catalogReference, outcome.catalogReference);
    try testing.expectEqual(@as(?u64, null), outcome.abandonedRow);
    var out: [3]u64 = undefined;
    _ = (try rows.getByObjectKey(&transaction, outcome.catalogReference, fixture.keyThree, &out)).?;
    try testing.expectEqual(@as(u64, 33), out[1]);
}

test "relocateAndPoison onto the row the key already occupies poisons nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "fixture4.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var transaction = try database.beginWrite();
    defer transaction.deinit();
    const fixture = try seed(&transaction);

    const ownRow = (try catalog.objectKeyToRow(&transaction, fixture.catalogReference, fixture.keyThree)).?;
    const outcome = try RelocationFixtureTests.relocateAndPoison(&transaction, fixture.catalogReference, fixture.keyThree, ownRow);
    try testing.expectEqual(fixture.catalogReference, outcome.catalogReference);
    try testing.expectEqual(@as(?u64, null), outcome.abandonedRow);
    var out: [3]u64 = undefined;
    _ = (try rows.getByObjectKey(&transaction, outcome.catalogReference, fixture.keyThree, &out)).?;
    try testing.expectEqual(@as(u64, 33), out[1]);
}

test "a committed database with a poisoned abandoned slot passes verifyIntegrity" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(testing.allocator, &tmp, "fixture5.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();

    var transaction = try database.beginWrite();
    const definitions = [_]catalog.PropertyDefinition{ .{ .kind = .int }, .{ .kind = .int, .indexed = true }, .{ .kind = .blob, .indexed = true } };
    var directoryReference = try typeDirectory.createWithDefinitions(&transaction, &.{&definitions});
    const first = try typeRouting.insert(&transaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .int = 11 }, .{ .bytes = "one" } });
    directoryReference = first.directoryReference;
    const second = try typeRouting.insert(&transaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .int = 22 }, .{ .bytes = "two" } });
    directoryReference = second.directoryReference;

    var catalogReference = try typeDirectory.catalogReference(&transaction, directoryReference, 0);
    const deadRow = (try catalog.objectKeyToRow(&transaction, catalogReference, first.objectKey)).?;
    var cells: [3]u64 = undefined;
    const version = (try rows.getByPrimaryKey(&transaction, catalogReference, 1, &cells)).?;
    directoryReference = (try typeRouting.delete(&transaction, directoryReference, 0, 1, version)).ok;

    catalogReference = try typeDirectory.catalogReference(&transaction, directoryReference, 0);
    const outcome = try RelocationFixtureTests.relocateAndPoison(&transaction, catalogReference, second.objectKey, deadRow);
    try testing.expectEqual(@as(?u64, 1), outcome.abandonedRow);
    directoryReference = try typeDirectory.setCatalogReference(&transaction, directoryReference, 0, outcome.catalogReference);
    transaction.setRoot(directoryReference, .typeDirectory);
    _ = try transaction.commit();

    try verification.verifyIntegrity(&database);
}
