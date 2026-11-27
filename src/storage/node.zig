const std = @import("std");

/// Kind byte of a generic storage node: leaf values, inner references, or raw bytes.
pub const NodeKind = enum(u8) { leafValues, innerReferences, rawBytes };

/// The header every generic storage node starts with: a kind byte plus a
/// little-endian element count.
pub const NodeHeader = struct {
    kind: NodeKind,
    elementCount: u32,
    /// Encoded header size: [kind:u8][elementCount:u32 LE].
    pub const size: usize = 5;

    /// Encode the header into the first `size` bytes of `buffer` (the caller
    /// supplies at least `size` bytes).
    pub fn encode(buffer: []u8, header: NodeHeader) EncodeResult {
        // Caller must provide >= size bytes. Under ReleaseSafe (this project's build mode) this assert is a safe trap, not UB.
        std.debug.assert(buffer.len >= size);
        buffer[0] = @backingInt(header.kind);
        std.mem.writeInt(u32, buffer[1..5], header.elementCount, .little);
        return .{ .headerLen = size };
    }
    /// The encoded header length, with a helper to size the full node.
    pub const EncodeResult = struct {
        headerLen: usize,
        /// Total node length: the header plus a `payloadLen`-byte payload.
        pub fn totalLengthWithPayload(self: EncodeResult, payloadLen: usize) usize {
            return self.headerLen + payloadLen;
        }
    };
};

/// A parsed node: its header plus the payload slice that follows it.
pub const NodeView = struct {
    header: NodeHeader,
    payload: []const u8,
    /// Validate and split `bytes` into header and payload; error.Corrupt on a
    /// short buffer or an out-of-range kind byte.
    pub fn parse(bytes: []const u8) error{Corrupt}!NodeView {
        if (bytes.len < NodeHeader.size) return error.Corrupt;
        const rawKind = bytes[0];
        if (rawKind > @backingInt(NodeKind.rawBytes)) return error.Corrupt;
        return .{
            .header = .{
                .kind = @fromBackingInt(@intCast(rawKind)),
                .elementCount = std.mem.readInt(u32, bytes[1..5], .little),
            },
            .payload = bytes[NodeHeader.size..],
        };
    }
};

const testing = std.testing;

test "encode then decode node header round-trips for every kind" {
    const cases = [_]struct { kind: NodeKind, count: u32 }{
        .{ .kind = .leafValues, .count = 0 },
        .{ .kind = .innerReferences, .count = 300 },
        .{ .kind = .rawBytes, .count = 4294967295 },
    };
    for (cases) |testCase| {
        var buffer: [16]u8 = undefined;
        const written = NodeHeader.encode(&buffer, .{ .kind = testCase.kind, .elementCount = testCase.count });
        const view = try NodeView.parse(buffer[0..written.totalLengthWithPayload(0)]);
        try testing.expectEqual(testCase.kind, view.header.kind);
        try testing.expectEqual(testCase.count, view.header.elementCount);
    }
}

test "parse rejects a truncated buffer" {
    const tiny = [_]u8{0x01};
    try testing.expectError(error.Corrupt, NodeView.parse(&tiny));
}

test "parse rejects an out-of-range kind byte" {
    var buffer: [NodeHeader.size]u8 = undefined;
    buffer[0] = 3; // one past rawBytes (2)
    std.mem.writeInt(u32, buffer[1..5], 0, .little);
    try testing.expectError(error.Corrupt, NodeView.parse(&buffer));
}

test "parse rejects a 4-byte buffer with a valid kind" {
    // One byte under NodeHeader.size, so the length check alone must reject it
    // even though the kind byte is valid. The trailing three bytes are zeros in
    // one pass and an encoded count in the other; neither may change the result.
    const cases = [_]struct { kind: NodeKind, byte: u8 }{
        .{ .kind = .leafValues, .byte = 0 },
        .{ .kind = .innerReferences, .byte = 1 },
        .{ .kind = .rawBytes, .byte = 2 },
    };
    for (cases) |testCase| {
        const zeros = [_]u8{ testCase.byte, 0, 0, 0 };
        try testing.expectError(error.Corrupt, NodeView.parse(&zeros));

        var counted: [NodeHeader.size - 1]u8 = undefined;
        counted[0] = testCase.byte;
        std.mem.writeInt(u24, counted[1..4], 300, .little);
        try testing.expectError(error.Corrupt, NodeView.parse(&counted));
    }
}

test "parse accepts an exact 5-byte buffer for every kind" {
    const cases = [_]struct { kind: NodeKind, byte: u8, count: u32 }{
        .{ .kind = .leafValues, .byte = 0, .count = 0 },
        .{ .kind = .innerReferences, .byte = 1, .count = 300 },
        .{ .kind = .rawBytes, .byte = 2, .count = 4294967295 },
    };
    for (cases) |testCase| {
        var buffer: [NodeHeader.size]u8 = undefined;
        buffer[0] = testCase.byte;
        std.mem.writeInt(u32, buffer[1..5], testCase.count, .little);
        const view = try NodeView.parse(&buffer);
        try testing.expectEqual(testCase.kind, view.header.kind);
        try testing.expectEqual(testCase.count, view.header.elementCount);
        try testing.expectEqual(@as(usize, 0), view.payload.len);
    }
}

test "node fuzz round-trips random headers and payloads for every kind" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("node round-trip fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var buffer: [NodeHeader.size + 64]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 300) : (iteration += 1) {
        const kind = random.enumValue(NodeKind);
        const elementCount: u32 = switch (random.uintLessThan(u8, 4)) {
            0 => 0,
            1 => std.math.maxInt(u32),
            else => random.int(u32),
        };
        const payloadLen = random.uintAtMost(usize, 64);
        const written = NodeHeader.encode(&buffer, .{ .kind = kind, .elementCount = elementCount });
        random.bytes(buffer[written.headerLen..][0..payloadLen]);
        const encoded = buffer[0..written.totalLengthWithPayload(payloadLen)];

        const view = try NodeView.parse(encoded);
        try testing.expectEqual(kind, view.header.kind);
        try testing.expectEqual(elementCount, view.header.elementCount);
        try testing.expectEqualSlices(u8, encoded[NodeHeader.size..], view.payload);
    }
}

test "node fuzz rejects short buffers and out-of-range kind bytes" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("node reject fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var buffer: [NodeHeader.size + 64]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 300) : (iteration += 1) {
        random.bytes(&buffer);
        const shortLen = random.uintLessThan(usize, NodeHeader.size);
        // Any kind byte, including a valid one: length alone must reject.
        try testing.expectError(error.Corrupt, NodeView.parse(buffer[0..shortLen]));

        const fullLen = NodeHeader.size + random.uintAtMost(usize, 64);
        buffer[0] = random.intRangeAtMost(u8, 3, std.math.maxInt(u8));
        try testing.expectError(error.Corrupt, NodeView.parse(buffer[0..fullLen]));
    }
}

test "node fuzz mutated bytes parse to exactly the mutated values" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("node mutation fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var buffer: [NodeHeader.size + 64]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 300) : (iteration += 1) {
        const written = NodeHeader.encode(&buffer, .{ .kind = random.enumValue(NodeKind), .elementCount = random.int(u32) });
        const payloadLen = random.uintAtMost(usize, 64);
        random.bytes(buffer[written.headerLen..][0..payloadLen]);
        const length = written.totalLengthWithPayload(payloadLen);

        const flips = random.intRangeAtMost(usize, 1, 4);
        var flip: usize = 0;
        while (flip < flips) : (flip += 1) buffer[random.uintLessThan(usize, length)] = random.int(u8);
        // Truncation keeps the header intact so only the payload shrinks.
        const kept = NodeHeader.size + random.uintAtMost(usize, length - NodeHeader.size);
        const mutated = buffer[0..kept];

        if (mutated[0] > @backingInt(NodeKind.rawBytes)) {
            try testing.expectError(error.Corrupt, NodeView.parse(mutated));
            continue;
        }
        const view = try NodeView.parse(mutated);
        try testing.expectEqual(mutated[0], @backingInt(view.header.kind));
        try testing.expectEqual(std.mem.readInt(u32, mutated[1..5], .little), view.header.elementCount);
        try testing.expectEqualSlices(u8, mutated[NodeHeader.size..], view.payload);
        try testing.expectEqual(mutated.len - NodeHeader.size, view.payload.len);
    }
}
