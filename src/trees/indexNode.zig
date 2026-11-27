//! On-disk node formats for the key->value B+tree: fixed-size leaf and inner
//! encodings shared (via bTreeCore) by index.zig's inline numeric keys and
//! byteKeyIndex.zig's blob-reference byte keys.

const std = @import("std");

/// Maximum (key, value) pairs per leaf node.
pub const leafCap: u16 = 64;
/// Maximum children per inner node.
pub const fanout: u16 = 64;
/// Kind byte marking a leaf node.
pub const kindLeaf: u8 = 0;
/// Kind byte marking an inner node.
pub const kindInner: u8 = 1;
/// Byte offset of a node's first entry: [kind u8][count u16].
pub const headerSize: usize = 3;
/// Fixed leaf allocation size: the header plus leafCap (key, value) pairs.
pub const leafNodeSize: usize = headerSize + @as(usize, leafCap) * 16;

/// Bytes per inner-node child entry.
/// Inner layout: [kind u8][childCount u16] then childCount entries of
/// (childReference u64, lowKey u64, subtreeCount u64). The subtree count makes
/// Index.count a single-node read instead of a full-tree walk, which is what
/// keeps liveCount / shouldCompact O(1)-per-node on the compaction hot path.
pub const innerStride: usize = 24;
/// Fixed inner allocation size: the header plus fanout child entries.
pub const innerNodeSize: usize = headerSize + @as(usize, fanout) * innerStride;

/// Encode the parallel (keys, vals) pairs into `buffer` as a leaf node;
/// returns the encoded byte length.
pub fn encodeLeaf(buffer: []u8, keys: []const u64, vals: []const u64) usize {
    std.debug.assert(keys.len == vals.len and keys.len <= leafCap);
    buffer[0] = kindLeaf;
    std.mem.writeInt(u16, buffer[1..3], @intCast(keys.len), .little);
    var offset: usize = headerSize;
    for (keys, vals) |key, value| {
        std.mem.writeInt(u64, buffer[offset..][0..8], key, .little);
        std.mem.writeInt(u64, buffer[offset + 8 ..][0..8], value, .little);
        offset += 16;
    }
    return offset;
}

/// A validated read-only view of a leaf node; construct via parseLeaf.
pub const LeafView = struct {
    bytes: []const u8,
    count: u16,
    /// The stored key at `entryIndex`.
    pub fn key(self: LeafView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * 16 ..][0..8], .little);
    }
    /// The value stored alongside the key at `entryIndex`.
    pub fn value(self: LeafView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * 16 + 8 ..][0..8], .little);
    }
    /// First slot whose stored key is >= `searchKey` (== count when every
    /// key is smaller). Binary search, O(log leafCap); inline numeric keys
    /// only.
    pub fn lowerBound(self: LeafView, searchKey: u64) usize {
        var low: usize = 0;
        var high: usize = self.count;
        while (low < high) {
            const midpoint = low + (high - low) / 2;
            if (self.key(midpoint) < searchKey) low = midpoint + 1 else high = midpoint;
        }
        return low;
    }
};

/// Validate `bytes` as a leaf node and return its view; error.Corrupt on a
/// wrong kind byte, an oversized count, or a short buffer.
pub fn parseLeaf(bytes: []const u8) error{Corrupt}!LeafView {
    if (bytes.len < headerSize) return error.Corrupt;
    if (bytes[0] != kindLeaf) return error.Corrupt;
    const leafCount = std.mem.readInt(u16, bytes[1..3], .little);
    if (leafCount > leafCap) return error.Corrupt;
    if (bytes.len < headerSize + @as(usize, leafCount) * 16) return error.Corrupt;
    return .{ .bytes = bytes, .count = leafCount };
}

// ---------------------------------------------------------------------------
// Inner-node encoding
// ---------------------------------------------------------------------------

/// Encode the parallel (references, lows, counts) child entries into `buffer` as an
/// inner node; returns the encoded byte length.
pub fn encodeInner(buffer: []u8, references: []const u64, lows: []const u64, counts: []const u64) usize {
    std.debug.assert(references.len == lows.len and references.len == counts.len and references.len <= fanout);
    buffer[0] = kindInner;
    std.mem.writeInt(u16, buffer[1..3], @intCast(references.len), .little);
    var offset: usize = headerSize;
    for (references, lows, counts) |reference, lowKey, count| {
        std.mem.writeInt(u64, buffer[offset..][0..8], reference, .little);
        std.mem.writeInt(u64, buffer[offset + 8 ..][0..8], lowKey, .little);
        std.mem.writeInt(u64, buffer[offset + 16 ..][0..8], count, .little);
        offset += innerStride;
    }
    return offset;
}

/// A validated read-only view of an inner node; construct via parseInner.
pub const InnerView = struct {
    bytes: []const u8,
    childCount: u16,
    /// The reference of child `entryIndex`.
    pub fn childReference(self: InnerView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * innerStride ..][0..8], .little);
    }
    /// The smallest key routed to child `entryIndex` (its recorded low).
    pub fn lowKey(self: InnerView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * innerStride + 8 ..][0..8], .little);
    }
    /// The number of entries stored under child `entryIndex`.
    pub fn subtreeCount(self: InnerView, entryIndex: usize) u64 {
        return std.mem.readInt(u64, self.bytes[headerSize + entryIndex * innerStride + 16 ..][0..8], .little);
    }
    /// Total entries under this node: the sum of its children's subtree counts.
    pub fn totalCount(self: InnerView) u64 {
        var total: u64 = 0;
        var entryIndex: usize = 0;
        while (entryIndex < self.childCount) : (entryIndex += 1) total += self.subtreeCount(entryIndex);
        return total;
    }
};

/// Validate `bytes` as an inner node and return its view; error.Corrupt on a
/// wrong kind byte, an oversized child count, or a short buffer.
pub fn parseInner(bytes: []const u8) error{Corrupt}!InnerView {
    if (bytes.len < headerSize) return error.Corrupt;
    if (bytes[0] != kindInner) return error.Corrupt;
    const childCount = std.mem.readInt(u16, bytes[1..3], .little);
    if (childCount > fanout) return error.Corrupt;
    if (bytes.len < headerSize + @as(usize, childCount) * innerStride) return error.Corrupt;
    return .{ .bytes = bytes, .childCount = childCount };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a buffer of `total` zero bytes with a hand-written header, so counts
/// the encoders refuse (above the cap) can be produced.
fn headerBuffer(total: usize, kind: u8, count: u16) ![]u8 {
    const buffer = try testing.allocator.alloc(u8, total);
    @memset(buffer, 0);
    buffer[0] = kind;
    std.mem.writeInt(u16, buffer[1..3], count, .little);
    return buffer;
}

fn expectLeafMatchesBytes(bytes: []const u8, view: LeafView) !void {
    try testing.expectEqual(std.mem.readInt(u16, bytes[1..3], .little), view.count);
    try testing.expect(view.count <= leafCap);
    try testing.expect(bytes.len >= headerSize + @as(usize, view.count) * 16);
    for (0..view.count) |i| {
        try testing.expectEqual(std.mem.readInt(u64, bytes[headerSize + i * 16 ..][0..8], .little), view.key(i));
        try testing.expectEqual(std.mem.readInt(u64, bytes[headerSize + i * 16 + 8 ..][0..8], .little), view.value(i));
    }
}

fn expectInnerMatchesBytes(bytes: []const u8, view: InnerView) !void {
    try testing.expectEqual(std.mem.readInt(u16, bytes[1..3], .little), view.childCount);
    try testing.expect(view.childCount <= fanout);
    try testing.expect(bytes.len >= headerSize + @as(usize, view.childCount) * innerStride);
    for (0..view.childCount) |i| {
        const base = headerSize + i * innerStride;
        try testing.expectEqual(std.mem.readInt(u64, bytes[base..][0..8], .little), view.childReference(i));
        try testing.expectEqual(std.mem.readInt(u64, bytes[base + 8 ..][0..8], .little), view.lowKey(i));
        try testing.expectEqual(std.mem.readInt(u64, bytes[base + 16 ..][0..8], .little), view.subtreeCount(i));
    }
}

test "index node fuzz: random valid leaf round-trips through parseLeaf" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("index leaf round-trip fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buffer: [leafNodeSize]u8 = undefined;
    var keys: [leafCap]u64 = undefined;
    var vals: [leafCap]u64 = undefined;
    for (0..300) |iteration| {
        const count: usize = switch (iteration % 4) {
            0 => 0,
            1 => leafCap,
            else => random.uintAtMost(usize, leafCap),
        };
        for (0..count) |i| {
            keys[i] = random.int(u64);
            vals[i] = random.int(u64);
        }
        const used = encodeLeaf(&buffer, keys[0..count], vals[0..count]);
        try testing.expectEqual(headerSize + count * 16, used);
        const view = try parseLeaf(buffer[0..used]);
        try testing.expectEqual(@as(u16, @intCast(count)), view.count);
        for (0..count) |i| {
            try testing.expectEqual(keys[i], view.key(i));
            try testing.expectEqual(vals[i], view.value(i));
        }
        // lowerBound on a sorted copy must agree with a linear scan.
        std.mem.sort(u64, keys[0..count], {}, std.sort.asc(u64));
        _ = encodeLeaf(&buffer, keys[0..count], vals[0..count]);
        const sorted = try parseLeaf(buffer[0..used]);
        const probe = random.int(u64);
        var expected: usize = 0;
        while (expected < count and keys[expected] < probe) expected += 1;
        try testing.expectEqual(expected, sorted.lowerBound(probe));
    }
}

test "index node fuzz: random valid inner round-trips through parseInner" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("index inner round-trip fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buffer: [innerNodeSize]u8 = undefined;
    var references: [fanout]u64 = undefined;
    var lows: [fanout]u64 = undefined;
    var counts: [fanout]u64 = undefined;
    for (0..300) |iteration| {
        const count: usize = switch (iteration % 4) {
            0 => 0,
            1 => fanout,
            else => random.uintAtMost(usize, fanout),
        };
        var total: u64 = 0;
        for (0..count) |i| {
            references[i] = random.int(u64);
            lows[i] = random.int(u64);
            counts[i] = random.int(u32);
            total += counts[i];
        }
        const used = encodeInner(&buffer, references[0..count], lows[0..count], counts[0..count]);
        try testing.expectEqual(headerSize + count * innerStride, used);
        const view = try parseInner(buffer[0..used]);
        try testing.expectEqual(@as(u16, @intCast(count)), view.childCount);
        for (0..count) |i| {
            try testing.expectEqual(references[i], view.childReference(i));
            try testing.expectEqual(lows[i], view.lowKey(i));
            try testing.expectEqual(counts[i], view.subtreeCount(i));
        }
        try testing.expectEqual(total, view.totalCount());
    }
}

test "index node fuzz: mutated and truncated leaf bytes are rejected or match the bytes" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("index leaf mutation fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const buffer = try testing.allocator.alloc(u8, leafNodeSize + 32);
    defer testing.allocator.free(buffer);
    for (0..300) |_| {
        random.bytes(buffer);
        buffer[0] = kindLeaf;
        // Bias the count toward the boundary region so both sides are hit.
        const count: u16 = @intCast(random.uintAtMost(usize, leafCap + 3));
        std.mem.writeInt(u16, buffer[1..3], count, .little);
        for (0..random.uintAtMost(usize, 4)) |_| {
            buffer[random.uintLessThan(usize, 3)] = random.int(u8);
        }
        const len = random.uintAtMost(usize, buffer.len);
        const bytes = buffer[0..len];
        if (parseLeaf(bytes)) |view| {
            try expectLeafMatchesBytes(bytes, view);
        } else |err| {
            try testing.expectEqual(error.Corrupt, err);
            const ok = len >= headerSize and bytes[0] == kindLeaf and
                std.mem.readInt(u16, bytes[1..3], .little) <= leafCap and
                len >= headerSize + @as(usize, std.mem.readInt(u16, bytes[1..3], .little)) * 16;
            try testing.expect(!ok);
        }
    }
}

test "index node fuzz: mutated and truncated inner bytes are rejected or match the bytes" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("index inner mutation fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const buffer = try testing.allocator.alloc(u8, innerNodeSize + 48);
    defer testing.allocator.free(buffer);
    for (0..300) |_| {
        random.bytes(buffer);
        buffer[0] = kindInner;
        const count: u16 = @intCast(random.uintAtMost(usize, fanout + 3));
        std.mem.writeInt(u16, buffer[1..3], count, .little);
        for (0..random.uintAtMost(usize, 4)) |_| {
            buffer[random.uintLessThan(usize, 3)] = random.int(u8);
        }
        const len = random.uintAtMost(usize, buffer.len);
        const bytes = buffer[0..len];
        if (parseInner(bytes)) |view| {
            try expectInnerMatchesBytes(bytes, view);
        } else |err| {
            try testing.expectEqual(error.Corrupt, err);
            const ok = len >= headerSize and bytes[0] == kindInner and
                std.mem.readInt(u16, bytes[1..3], .little) <= fanout and
                len >= headerSize + @as(usize, std.mem.readInt(u16, bytes[1..3], .little)) * innerStride;
            try testing.expect(!ok);
        }
    }
}

test "index node pin: parseLeaf accepts leafCount == leafCap in an exact-size buffer and reads every pair" {
    const buffer = try headerBuffer(headerSize + @as(usize, leafCap) * 16, kindLeaf, leafCap);
    defer testing.allocator.free(buffer);
    for (0..leafCap) |i| {
        std.mem.writeInt(u64, buffer[headerSize + i * 16 ..][0..8], 1000 + i, .little);
        std.mem.writeInt(u64, buffer[headerSize + i * 16 + 8 ..][0..8], 5000 + i, .little);
    }
    const view = try parseLeaf(buffer);
    try testing.expectEqual(leafCap, view.count);
    for (0..leafCap) |i| {
        try testing.expectEqual(@as(u64, 1000 + i), view.key(i));
        try testing.expectEqual(@as(u64, 5000 + i), view.value(i));
    }
}

test "index node pin: parseLeaf rejects leafCount == leafCap + 1 even when the buffer holds 65 entries" {
    const buffer = try headerBuffer(headerSize + (@as(usize, leafCap) + 1) * 16 + 16, kindLeaf, leafCap + 1);
    defer testing.allocator.free(buffer);
    try testing.expectError(error.Corrupt, parseLeaf(buffer));
}

test "index node pin: parseInner accepts childCount == fanout in an exact-size buffer and reads every entry" {
    const buffer = try headerBuffer(headerSize + @as(usize, fanout) * innerStride, kindInner, fanout);
    defer testing.allocator.free(buffer);
    for (0..fanout) |i| {
        const base = headerSize + i * innerStride;
        std.mem.writeInt(u64, buffer[base..][0..8], 100 + i, .little);
        std.mem.writeInt(u64, buffer[base + 8 ..][0..8], 200 + i, .little);
        std.mem.writeInt(u64, buffer[base + 16 ..][0..8], 300 + i, .little);
    }
    const view = try parseInner(buffer);
    try testing.expectEqual(fanout, view.childCount);
    for (0..fanout) |i| {
        try testing.expectEqual(@as(u64, 100 + i), view.childReference(i));
        try testing.expectEqual(@as(u64, 200 + i), view.lowKey(i));
        try testing.expectEqual(@as(u64, 300 + i), view.subtreeCount(i));
    }
}

test "index node pin: parseInner rejects childCount == fanout + 1 even when the buffer holds 65 entries" {
    const buffer = try headerBuffer(headerSize + (@as(usize, fanout) + 1) * innerStride + innerStride, kindInner, fanout + 1);
    defer testing.allocator.free(buffer);
    try testing.expectError(error.Corrupt, parseInner(buffer));
}

test "index node pin: parseLeaf needs exactly headerSize + count*16 bytes for count 0, 1, 2 and leafCap" {
    for ([_]u16{ 0, 1, 2, leafCap }) |count| {
        const exact = headerSize + @as(usize, count) * 16;
        const buffer = try headerBuffer(exact, kindLeaf, count);
        defer testing.allocator.free(buffer);
        const view = try parseLeaf(buffer);
        try testing.expectEqual(count, view.count);
        if (count > 0) {
            try testing.expectError(error.Corrupt, parseLeaf(buffer[0 .. exact - 1]));
        }
    }
}

test "index node pin: parseInner needs exactly headerSize + count*24 bytes for count 0, 1, 2 and fanout" {
    for ([_]u16{ 0, 1, 2, fanout }) |count| {
        const exact = headerSize + @as(usize, count) * innerStride;
        const buffer = try headerBuffer(exact, kindInner, count);
        defer testing.allocator.free(buffer);
        const view = try parseInner(buffer);
        try testing.expectEqual(count, view.childCount);
        if (count > 0) {
            try testing.expectError(error.Corrupt, parseInner(buffer[0 .. exact - 1]));
        }
    }
}

test "index node pin: parseLeaf and parseInner reject every length below headerSize" {
    const leafBytes = [_]u8{ kindLeaf, 0, 0 };
    const innerBytes = [_]u8{ kindInner, 0, 0 };
    for (0..headerSize) |len| {
        try testing.expectError(error.Corrupt, parseLeaf(leafBytes[0..len]));
        try testing.expectError(error.Corrupt, parseInner(innerBytes[0..len]));
    }
    // The header alone, with a zero count, is the smallest valid node.
    try testing.expectEqual(@as(u16, 0), (try parseLeaf(&leafBytes)).count);
    try testing.expectEqual(@as(u16, 0), (try parseInner(&innerBytes)).childCount);
}

test "index node pin: parseLeaf rejects every non-leaf kind byte and parseInner every non-inner kind byte" {
    var buffer: [leafNodeSize + innerNodeSize]u8 = undefined;
    for (0..256) |kind| {
        @memset(&buffer, 0);
        buffer[0] = @intCast(kind);
        if (kind == kindLeaf) {
            _ = try parseLeaf(&buffer);
        } else {
            try testing.expectError(error.Corrupt, parseLeaf(&buffer));
        }
        if (kind == kindInner) {
            _ = try parseInner(&buffer);
        } else {
            try testing.expectError(error.Corrupt, parseInner(&buffer));
        }
    }
}
