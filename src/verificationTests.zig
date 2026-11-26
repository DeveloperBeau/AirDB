//! Tests for verifyIntegrity driven by the root kind recorded in the commit
//! slot: each kind round-trips through the real file, tagged roots that do
//! not parse are reported, and slot kinds that cannot be true are refused.

const std = @import("std");
const testing = std.testing;
const verification = @import("verification.zig");
const databaseModule = @import("database.zig");
const Database = databaseModule.Database;
const WriteTransaction = databaseModule.WriteTransaction;
const slotAOff = databaseModule.slotAOff;
const slotBOff = databaseModule.slotBOff;
const Reference = @import("storage/reference.zig").Reference;
const RootKind = @import("storage/rootKind.zig").RootKind;
const catalog = @import("schema/catalog.zig");
const typeDirectory = @import("schema/typeDirectory.zig");
const typeRouting = @import("schema/typeRouting.zig");
const rows = @import("records/rows.zig");
const Index = @import("trees/index.zig");
const Column = @import("trees/column.zig");

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    return std.fs.path.join(allocator, &.{ pathBuffer[0..pathLen], name });
}

// A bare catalog: property 0 is the primary key, property 1 is an indexed int
// equal to the primary key. Eight rows, primary keys 0..7.
fn commitIndexedCatalog(database: *Database) !void {
    var writeTransaction = try database.beginWrite();
    errdefer writeTransaction.deinit();
    var catalogReference = try catalog.createFromDefinitions(&writeTransaction, &.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } });
    var primaryKey: u64 = 0;
    while (primaryKey < 8) : (primaryKey += 1) {
        catalogReference = (try rows.insert(&writeTransaction, catalogReference, &.{ primaryKey, primaryKey })).catalogReference;
    }
    writeTransaction.setRoot(catalogReference, .catalog);
    _ = try writeTransaction.commit();
}

// The same shape as commitIndexedCatalog, under a one-type directory.
fn commitIndexedDirectory(database: *Database) !void {
    var writeTransaction = try database.beginWrite();
    errdefer writeTransaction.deinit();
    var directoryReference = try typeDirectory.createTypes(&writeTransaction, &.{&.{ .{ .kind = .int }, .{ .kind = .int, .indexed = true } }}, &.{false});
    var primaryKey: u64 = 0;
    while (primaryKey < 8) : (primaryKey += 1) {
        directoryReference = (try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = primaryKey }, .{ .int = primaryKey } })).directoryReference;
    }
    writeTransaction.setRoot(directoryReference, .typeDirectory);
    _ = try writeTransaction.commit();
}

// Rewrite the kind byte of the slot at `slotOffset` in the closed file and
// restamp its CRC, so only the kind check can reject it.
fn forgeSlotKindOnDisk(path: []const u8, slotOffset: usize, kindByte: u8) !void {
    const file = try std.Io.Dir.openFileAbsolute(testing.io, path, .{ .mode = .read_write });
    defer file.close(testing.io);
    var slotBytes: [40]u8 = undefined;
    _ = try file.readPositionalAll(testing.io, &slotBytes, slotOffset);
    slotBytes[32] = kindByte;
    std.mem.writeInt(u32, slotBytes[36..40], std.hash.Crc32.hash(slotBytes[0..36]), .little);
    try file.writePositionalAll(testing.io, &slotBytes, slotOffset);
}

// Write a type directory node by hand: `count` types, each pointing at
// `catalogReference`, none embedded.
fn writeDirectoryNode(writeTransaction: *WriteTransaction, count: u16, catalogReference: Reference) !Reference {
    const size = 2 + @as(usize, count) * 8 + count;
    const allocation = try writeTransaction.alloc(size);
    @memset(allocation.bytes, 0);
    std.mem.writeInt(u16, allocation.bytes[0..2], count, .little);
    var typeIndex: usize = 0;
    while (typeIndex < count) : (typeIndex += 1) {
        std.mem.writeInt(u64, allocation.bytes[2 + typeIndex * 8 ..][0..8], catalogReference, .little);
    }
    return allocation.reference;
}

// Tombstone a row's live bit but keep its key-to-row entry, the divergence
// no writer produces (rows.delete removes the key in the same step).
fn tombstoneKeepingKey(writeTransaction: *WriteTransaction, directoryReference: Reference, primaryKey: u64) !Reference {
    const catalogReference = try typeDirectory.catalogReference(writeTransaction, directoryReference, 0);
    const objectKey = (try catalog.primaryKeyToObjectKey(writeTransaction, catalogReference, primaryKey)).?;
    const row = (try catalog.objectKeyToRow(writeTransaction, catalogReference, objectKey)).?;
    var snapshot = try catalog.CatalogSnapshot.load(writeTransaction, catalogReference);
    snapshot.liveColumnReference = try Column.set(writeTransaction, snapshot.liveColumnReference, row, 0);
    const newCatalog = try snapshot.replace(writeTransaction);
    return typeDirectory.setCatalogReference(writeTransaction, directoryReference, 0, newCatalog);
}

// ---------------------------------------------------------------------------
// One round trip per kind, through the real file
// ---------------------------------------------------------------------------

test "root kind none: a null root passes verifyIntegrity and stays none after close and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "kind_none.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        try testing.expectEqual(RootKind.none, database.activeRootKind);
        try verification.verifyIntegrity(&database);
        // v2 has a blob root, v3 clears it, so the commit path writes kind none.
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "SOMEDATA");
        writeTransaction.setRoot(allocation.reference, .blob);
        _ = try writeTransaction.commit();
        var clearing = try database.beginWrite();
        clearing.setRoot(0, .none);
        _ = try clearing.commit();
        try verification.verifyIntegrity(&database);
    }
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    try testing.expectEqual(@as(u64, 3), database.activeVersion);
    try testing.expectEqual(@as(u64, 0), database.activeRoot);
    try testing.expectEqual(RootKind.none, database.activeRootKind);
    try testing.expectEqual(@as(u8, 0), database.store.map[slotAOff + 32]); // v3 lands in slot A
    try verification.verifyIntegrity(&database);
}

test "root kind blob: raw bytes pass verifyIntegrity unaudited and stay blob after close and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "kind_blob.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        var writeTransaction = try database.beginWrite();
        const allocation = try writeTransaction.alloc(8);
        @memcpy(allocation.bytes, "INTEGER_");
        writeTransaction.setRoot(allocation.reference, .blob);
        _ = try writeTransaction.commit();
        try verification.verifyIntegrity(&database);
    }
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    try testing.expectEqual(RootKind.blob, database.activeRootKind);
    try testing.expectEqual(@as(u8, 1), database.store.map[slotBOff + 32]); // v2 lands in slot B
    try verification.verifyIntegrity(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    try testing.expectEqualStrings("INTEGER_", try readTransaction.dereference(readTransaction.root(), 8));
}

test "root kind catalog: a clean bare catalog passes verifyIntegrity and stays catalog after close and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "kind_catalog.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        try commitIndexedCatalog(&database);
        try verification.verifyIntegrity(&database);
    }
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    try testing.expectEqual(RootKind.catalog, database.activeRootKind);
    try testing.expectEqual(@as(u8, 2), database.store.map[slotBOff + 32]);
    try verification.verifyIntegrity(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    try testing.expectEqual(@as(u64, 8), try catalog.liveCount(&readTransaction, readTransaction.root()));
}

test "root kind typeDirectory: a clean directory passes verifyIntegrity and stays typeDirectory after close and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "kind_directory.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        try commitIndexedDirectory(&database);
        try verification.verifyIntegrity(&database);
    }
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    try testing.expectEqual(RootKind.typeDirectory, database.activeRootKind);
    try testing.expectEqual(@as(u8, 3), database.store.map[slotBOff + 32]);
    try verification.verifyIntegrity(&database);
    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    try testing.expectEqual(@as(u16, 1), try typeDirectory.typeCount(&readTransaction, readTransaction.root()));
}

test "a write transaction that never calls setRoot keeps the committed root kind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "kind_inherit.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        try commitIndexedCatalog(&database);
        var writeTransaction = try database.beginWrite();
        _ = try writeTransaction.alloc(8);
        _ = try writeTransaction.commit();
        try testing.expectEqual(RootKind.catalog, database.activeRootKind);
    }
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    try testing.expectEqual(@as(u64, 3), database.activeVersion);
    try testing.expectEqual(RootKind.catalog, database.activeRootKind);
    try testing.expectEqual(@as(u8, 2), database.store.map[slotAOff + 32]); // v3 lands in slot A
}

test "a second instance adopts the root kind another instance committed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "kind_refresh.airdb");
    defer testing.allocator.free(path);
    var writer = try Database.create(testing.allocator, path);
    defer writer.deinit();
    var reader = try Database.open(testing.allocator, path);
    defer reader.deinit();
    try testing.expectEqual(RootKind.none, reader.activeRootKind);
    try commitIndexedDirectory(&writer);
    var readTransaction = try reader.beginRead();
    readTransaction.end();
    try testing.expectEqual(@as(u64, 2), reader.activeVersion);
    try testing.expectEqual(RootKind.typeDirectory, reader.activeRootKind);
    try verification.verifyIntegrity(&reader);
}

test "commit refuses a root whose kind cannot be true and keeps the prior version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "kind_mismatch.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        defer writeTransaction.deinit();
        writeTransaction.setRoot(0, .catalog);
        try testing.expectError(error.RootKindMismatch, writeTransaction.commit());
    }
    {
        var writeTransaction = try database.beginWrite(); // the lock was released
        defer writeTransaction.deinit();
        const allocation = try writeTransaction.alloc(8);
        writeTransaction.setRoot(allocation.reference, .none);
        try testing.expectError(error.RootKindMismatch, writeTransaction.commit());
    }
    try testing.expectEqual(@as(u64, 1), database.activeVersion);
    try testing.expectEqual(RootKind.none, database.activeRootKind);
    try verification.verifyIntegrity(&database);
}

// ---------------------------------------------------------------------------
// Damage the audit used to pass
// ---------------------------------------------------------------------------

test "verifyIntegrity reports a corrupted value index under a bare catalog root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "bare_catalog_corrupt.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        try commitIndexedCatalog(&database);
        try verification.verifyIntegrity(&database); // clean before corruption
        // Register the live objectKey of row 0 (value 0) under a value no row has.
        var writeTransaction = try database.beginWrite();
        const catalogReference = database.activeRoot;
        const view = try catalog.loadCatalog(&writeTransaction, catalogReference);
        const objectKey = (try catalog.primaryKeyToObjectKey(&writeTransaction, catalogReference, 0)).?;
        var setRoot = try Index.create(&writeTransaction);
        setRoot = try Index.insert(&writeTransaction, setRoot, objectKey, 1);
        const newValueIndex = try Index.insert(&writeTransaction, view.valueIndexReference(1), 999_999, setRoot);
        const newCatalog = try catalog.setValueIndexReference(&writeTransaction, catalogReference, 1, newValueIndex);
        writeTransaction.setRoot(newCatalog, .catalog);
        _ = try writeTransaction.commit();
        try testing.expectError(error.ValueIndexStaleEntry, verification.verifyIntegrity(&database));
    }
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    try testing.expectError(error.ValueIndexStaleEntry, verification.verifyIntegrity(&database));
}

test "verifyIntegrity reports a type directory whose catalog reference points outside the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "dir_bad_catalog_ref.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitIndexedDirectory(&database);
    var writeTransaction = try database.beginWrite();
    const garbage: Reference = 0x7FFF_FFF8; // 8-aligned, far past the mapped sections
    const newDirectory = try typeDirectory.setCatalogReference(&writeTransaction, database.activeRoot, 0, garbage);
    writeTransaction.setRoot(newDirectory, .typeDirectory);
    _ = try writeTransaction.commit();
    try testing.expectError(error.RootUnreadable, verification.verifyIntegrity(&database));
}

test "verifyIntegrity reports a type directory whose catalog reference points at garbage bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "dir_garbage_catalog.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitIndexedDirectory(&database);
    var writeTransaction = try database.beginWrite();
    const garbage = try writeTransaction.alloc(64);
    @memset(garbage.bytes, 0xFF); // property count 0xFFFF, over the 256 limit
    const newDirectory = try typeDirectory.setCatalogReference(&writeTransaction, database.activeRoot, 0, garbage.reference);
    writeTransaction.setRoot(newDirectory, .typeDirectory);
    _ = try writeTransaction.commit();
    try testing.expectError(error.RootUnreadable, verification.verifyIntegrity(&database));
}

test "verifyIntegrity reports a type directory with 257 types even when every catalog is clean" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "dir_257_types.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitIndexedCatalog(&database);
    var writeTransaction = try database.beginWrite();
    const directory = try writeDirectoryNode(&writeTransaction, 257, database.activeRoot);
    writeTransaction.setRoot(directory, .typeDirectory);
    _ = try writeTransaction.commit();
    try testing.expectError(error.RootUnreadable, verification.verifyIntegrity(&database));
}

test "verifyIntegrity passes a type directory with exactly 256 clean types" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "dir_256_types.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitIndexedCatalog(&database);
    var writeTransaction = try database.beginWrite();
    const directory = try writeDirectoryNode(&writeTransaction, 256, database.activeRoot);
    writeTransaction.setRoot(directory, .typeDirectory);
    _ = try writeTransaction.commit();
    try verification.verifyIntegrity(&database);
}

test "verifyIntegrity reports raw bytes committed under the typeDirectory kind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "blob_as_directory.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(8);
    @memcpy(allocation.bytes, "INTEGER_"); // reads as type count 0x4E49
    writeTransaction.setRoot(allocation.reference, .typeDirectory);
    _ = try writeTransaction.commit();
    try testing.expectError(error.RootUnreadable, verification.verifyIntegrity(&database));
}

test "verifyIntegrity reports raw bytes committed under the catalog kind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "blob_as_catalog.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    var writeTransaction = try database.beginWrite();
    const allocation = try writeTransaction.alloc(64);
    @memset(allocation.bytes, 0xFF); // property count 0xFFFF
    writeTransaction.setRoot(allocation.reference, .catalog);
    _ = try writeTransaction.commit();
    try testing.expectError(error.RootUnreadable, verification.verifyIntegrity(&database));
}

// ---------------------------------------------------------------------------
// Slot kinds that cannot be true
// ---------------------------------------------------------------------------

test "an unknown kind byte in the active slot makes open fall back to the previous version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "slot_unknown_kind.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        try commitIndexedCatalog(&database); // v2 in slot B, v1 (empty) stays in slot A
    }
    try forgeSlotKindOnDisk(path, slotBOff, 9);
    var database = try Database.open(testing.allocator, path);
    defer database.deinit();
    try testing.expect(database.recoveredFallback);
    try testing.expectEqual(@as(u64, 1), database.activeVersion);
    try testing.expectEqual(@as(u64, 0), database.activeRoot);
    try testing.expectEqual(RootKind.none, database.activeRootKind);
    try verification.verifyIntegrity(&database);
}

test "an unknown kind byte in both slots makes open fail with error.Corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "slots_unknown_kind.airdb");
    defer testing.allocator.free(path);
    {
        var database = try Database.create(testing.allocator, path);
        defer database.deinit();
        try commitIndexedCatalog(&database);
    }
    try forgeSlotKindOnDisk(path, slotAOff, 4);
    try forgeSlotKindOnDisk(path, slotBOff, 0xFF);
    try testing.expectError(error.Corrupt, Database.open(testing.allocator, path));
}

test "verifyIntegrity reports SlotCorrupt when both mapped slots carry a kind that disagrees with the root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "slots_kind_mismatch.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitIndexedCatalog(&database);
    // Slot A holds v1 with a null root: tag it catalog. Slot B holds v2 with a
    // catalog root: tag it none. Both CRCs are restamped.
    for ([_]struct { offset: usize, kind: u8 }{ .{ .offset = slotAOff, .kind = 2 }, .{ .offset = slotBOff, .kind = 0 } }) |forge| {
        const slotBytes = database.store.map[forge.offset..][0..40];
        slotBytes[32] = forge.kind;
        std.mem.writeInt(u32, slotBytes[36..40], std.hash.Crc32.hash(slotBytes[0..36]), .little);
    }
    try testing.expectError(error.SlotCorrupt, verification.verifyIntegrity(&database));
}

// ---------------------------------------------------------------------------
// Key-to-row entries that name a dead row
// ---------------------------------------------------------------------------

test "verifyIntegrity reports a key-to-row entry that names a dead row with an indexed int property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "dead_row_int.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    try commitIndexedDirectory(&database);
    var writeTransaction = try database.beginWrite();
    const newDirectory = try tombstoneKeepingKey(&writeTransaction, database.activeRoot, 3);
    writeTransaction.setRoot(newDirectory, .typeDirectory);
    _ = try writeTransaction.commit();
    try testing.expectError(error.ValueIndexMissingEntry, verification.verifyIntegrity(&database));
}

test "verifyIntegrity reports a key-to-row entry that names a dead row with an indexed blob property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "dead_row_blob.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        var directoryReference = try typeDirectory.createTypes(&writeTransaction, &.{&.{ .{ .kind = .int }, .{ .kind = .blob, .indexed = true } }}, &.{false});
        directoryReference = (try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .bytes = "alpha" } })).directoryReference;
        directoryReference = (try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 2 }, .{ .bytes = "beta" } })).directoryReference;
        writeTransaction.setRoot(directoryReference, .typeDirectory);
        _ = try writeTransaction.commit();
    }
    try verification.verifyIntegrity(&database); // clean before corruption
    var writeTransaction = try database.beginWrite();
    const newDirectory = try tombstoneKeepingKey(&writeTransaction, database.activeRoot, 1);
    writeTransaction.setRoot(newDirectory, .typeDirectory);
    _ = try writeTransaction.commit();
    try testing.expectError(error.ValueIndexMissingEntry, verification.verifyIntegrity(&database));
}

test "verifyIntegrity reports a key-to-row entry that names a dead row with a link property" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpFilePath(testing.allocator, &tmp, "dead_row_link.airdb");
    defer testing.allocator.free(path);
    var database = try Database.create(testing.allocator, path);
    defer database.deinit();
    {
        var writeTransaction = try database.beginWrite();
        var directoryReference = try typeDirectory.createTypes(&writeTransaction, &.{
            &.{ .{ .kind = .int }, .{ .kind = .link, .linkTarget = 0 } },
        }, &.{false});
        directoryReference = (try typeRouting.insert(&writeTransaction, directoryReference, 0, &.{ .{ .int = 1 }, .{ .link = null } })).directoryReference;
        writeTransaction.setRoot(directoryReference, .typeDirectory);
        _ = try writeTransaction.commit();
    }
    try verification.verifyIntegrity(&database); // clean before corruption
    var writeTransaction = try database.beginWrite();
    const newDirectory = try tombstoneKeepingKey(&writeTransaction, database.activeRoot, 1);
    writeTransaction.setRoot(newDirectory, .typeDirectory);
    _ = try writeTransaction.commit();
    try testing.expectError(error.BacklinkMissingEntry, verification.verifyIntegrity(&database));
}
