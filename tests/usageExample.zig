//! The Zig example in docs/usage.md and README.md. `run` holds the code the
//! docs show, so the example cannot drift from the API.
const std = @import("std");
const airdb = @import("airdb");
const testing = std.testing;
const Io = std.Io;

/// Creates a database at `path`, stores one row, reads it back, runs a query,
/// and returns the object key the query matched.
fn run(allocator: std.mem.Allocator, path: []const u8) !u64 {
    var database = try airdb.Database.create(allocator, path);
    defer database.deinit();

    // Define a type: primaryKey (int) + name (blob) + an indexed int.
    var writeTransaction = try database.beginWrite();
    var directoryReference = try airdb.typeDirectory.createWithDefinitions(&writeTransaction, &.{
        &.{ .{ .kind = .int }, .{ .kind = .blob }, .{ .kind = .int, .indexed = true } },
    });
    directoryReference = (try airdb.typeRouting.insert(&writeTransaction, directoryReference, 0, &.{
        .{ .int = 1 }, .{ .bytes = "Ada" }, .{ .int = 1815 },
    })).directoryReference;
    writeTransaction.setRoot(directoryReference, .typeDirectory);
    _ = try writeTransaction.commit(); // durable here

    var readTransaction = try database.beginRead();
    defer readTransaction.end();
    var out: [3]airdb.typeDirectory.Value = undefined;
    const version = try airdb.typeRouting.get(&readTransaction, readTransaction.root(), 0, 1, &out);
    try testing.expect(version != null);
    try testing.expectEqual(@as(u64, 1815), out[2].int);

    // Find the rows whose third property equals 1815.
    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(allocator);
    const catalogReference = try airdb.typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
    try airdb.query.where(
        &readTransaction,
        catalogReference,
        .{ .predicate = .{ .comparison = .{ .property = 2, .operator = .eq, .value = .{ .int = 1815 } } } },
        &keys,
        allocator,
    );
    try testing.expectEqual(@as(usize, 1), keys.items.len);
    return keys.items[0];
}

test "the documented Zig usage example opens a database, writes, reads and queries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const path = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..pathLen], "usage.airdb" });
    defer testing.allocator.free(path);

    const matchedKey = try run(testing.allocator, path);
    // The first object stored in a type gets object key 0.
    try testing.expectEqual(@as(u64, 0), matchedKey);
}
