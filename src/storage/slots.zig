const std = @import("std");
const Reference = @import("reference.zig").Reference;
const RootKind = @import("rootKind.zig").RootKind;

/// One of the two commit slots in the header page: the durable record of a
/// committed version -- its version number, root reference and the kind of
/// that root, persisted free-list head, and logical file size -- protected by
/// a CRC32.
///
/// Encoded layout, little-endian:
///   [0, 8)   version u64
///   [8, 16)  rootReference u64
///   [16, 24) freeListReference u64
///   [24, 32) logicalSize u64
///   [32]     rootKind u8 (RootKind)
///   [33, 36) reserved, always zero
///   [36, 40) CRC32 of [0, 36)
pub const Slot = struct {
    version: u64,
    rootReference: Reference,
    rootKind: RootKind,
    freeListReference: Reference,
    logicalSize: u64,
    /// Encoded slot size in bytes: four u64 fields, the kind byte, three reserved bytes and the CRC32.
    pub const size: usize = 40;
    const crcOffset: usize = 36;
    const kindOffset: usize = 32;

    /// Encode the slot into `buffer` (at least `size` bytes), stamping a
    /// CRC32 over the fields, the kind byte and the reserved bytes.
    pub fn encode(self: Slot, buffer: []u8) void {
        std.debug.assert(buffer.len >= size);
        std.debug.assert(kindMatchesRoot(self.rootKind, self.rootReference));
        std.mem.writeInt(u64, buffer[0..8], self.version, .little);
        std.mem.writeInt(u64, buffer[8..16], self.rootReference, .little);
        std.mem.writeInt(u64, buffer[16..24], self.freeListReference, .little);
        std.mem.writeInt(u64, buffer[24..32], self.logicalSize, .little);
        buffer[kindOffset] = @backingInt(self.rootKind);
        @memset(buffer[kindOffset + 1 .. crcOffset], 0);
        std.mem.writeInt(u32, buffer[crcOffset..][0..4], std.hash.Crc32.hash(buffer[0..crcOffset]), .little);
    }

    /// Decode a slot from `buffer`. error.BadChecksum when the stored checksum
    /// does not match, error.BadRootKind when the kind byte is unknown or
    /// disagrees with the root reference, error.ReservedNotZero when a
    /// reserved byte is set.
    pub fn decode(buffer: []const u8) error{ BadChecksum, BadRootKind, ReservedNotZero }!Slot {
        std.debug.assert(buffer.len >= size);
        const stored = std.mem.readInt(u32, buffer[crcOffset..][0..4], .little);
        if (stored != std.hash.Crc32.hash(buffer[0..crcOffset])) return error.BadChecksum;
        for (buffer[kindOffset + 1 .. crcOffset]) |reserved| {
            if (reserved != 0) return error.ReservedNotZero;
        }
        const rootKind = std.enums.fromInt(RootKind, buffer[kindOffset]) orelse return error.BadRootKind;
        const rootReference = std.mem.readInt(u64, buffer[8..16], .little);
        if (!kindMatchesRoot(rootKind, rootReference)) return error.BadRootKind;
        return .{
            .version = std.mem.readInt(u64, buffer[0..8], .little),
            .rootReference = rootReference,
            .rootKind = rootKind,
            .freeListReference = std.mem.readInt(u64, buffer[16..24], .little),
            .logicalSize = std.mem.readInt(u64, buffer[24..32], .little),
        };
    }

    // A null root has kind none and every real root has a real kind.
    fn kindMatchesRoot(rootKind: RootKind, rootReference: Reference) bool {
        return (rootKind == .none) == (rootReference == 0);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Re-stamp the CRC over [0, 36) so a test can forge a slot whose checksum is
// valid but whose kind or reserved bytes are not.
fn restampChecksum(buffer: []u8) void {
    std.mem.writeInt(u32, buffer[36..40], std.hash.Crc32.hash(buffer[0..36]), .little);
}

test "slot encode/decode round-trips and checksum validates" {
    var buffer: [Slot.size]u8 = undefined;
    const slot = Slot{ .version = 7, .rootReference = 4096, .rootKind = .typeDirectory, .freeListReference = 8192, .logicalSize = 12288 };
    slot.encode(&buffer);
    const decoded = try Slot.decode(&buffer);
    try testing.expectEqual(@as(u64, 7), decoded.version);
    try testing.expectEqual(@as(u64, 4096), decoded.rootReference);
    try testing.expectEqual(RootKind.typeDirectory, decoded.rootKind);
    try testing.expectEqual(@as(u64, 8192), decoded.freeListReference);
    try testing.expectEqual(@as(u64, 12288), decoded.logicalSize);
}

test "slot encoding puts the kind byte at 32, zero reserved bytes at 33..36 and the CRC at 36..40" {
    var buffer: [Slot.size]u8 = undefined;
    @memset(&buffer, 0xAA);
    (Slot{ .version = 1, .rootReference = 4096, .rootKind = .catalog, .freeListReference = 0, .logicalSize = 8192 }).encode(&buffer);
    try testing.expectEqual(@as(usize, 40), Slot.size);
    try testing.expectEqual(@as(u8, 2), buffer[32]); // catalog = 2
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, buffer[33..36]);
    try testing.expectEqual(std.hash.Crc32.hash(buffer[0..36]), std.mem.readInt(u32, buffer[36..40], .little));
}

test "every root kind round-trips through encode and decode" {
    const cases = [_]struct { kind: RootKind, root: u64, byte: u8 }{
        .{ .kind = .none, .root = 0, .byte = 0 },
        .{ .kind = .blob, .root = 4096, .byte = 1 },
        .{ .kind = .catalog, .root = 8192, .byte = 2 },
        .{ .kind = .typeDirectory, .root = 12288, .byte = 3 },
    };
    for (cases) |case| {
        var buffer: [Slot.size]u8 = undefined;
        (Slot{ .version = 3, .rootReference = case.root, .rootKind = case.kind, .freeListReference = 0, .logicalSize = 16384 }).encode(&buffer);
        try testing.expectEqual(case.byte, buffer[32]);
        const decoded = try Slot.decode(&buffer);
        try testing.expectEqual(case.kind, decoded.rootKind);
        try testing.expectEqual(case.root, decoded.rootReference);
    }
}

test "decode rejects a corrupted slot" {
    var buffer: [Slot.size]u8 = undefined;
    (Slot{ .version = 1, .rootReference = 4096, .rootKind = .blob, .freeListReference = 0, .logicalSize = 8192 }).encode(&buffer);
    buffer[4] ^= 0xFF;
    try testing.expectError(error.BadChecksum, Slot.decode(&buffer));
}

test "the CRC covers the kind byte: flipping it without restamping is a bad checksum" {
    var buffer: [Slot.size]u8 = undefined;
    (Slot{ .version = 1, .rootReference = 4096, .rootKind = .catalog, .freeListReference = 0, .logicalSize = 8192 }).encode(&buffer);
    buffer[32] = 3; // catalog -> typeDirectory, CRC left alone
    try testing.expectError(error.BadChecksum, Slot.decode(&buffer));
}

test "decode rejects an unknown kind byte even with a valid checksum" {
    var buffer: [Slot.size]u8 = undefined;
    (Slot{ .version = 1, .rootReference = 4096, .rootKind = .blob, .freeListReference = 0, .logicalSize = 8192 }).encode(&buffer);
    buffer[32] = 4;
    restampChecksum(&buffer);
    try testing.expectError(error.BadRootKind, Slot.decode(&buffer));
    buffer[32] = 0xFF;
    restampChecksum(&buffer);
    try testing.expectError(error.BadRootKind, Slot.decode(&buffer));
}

test "decode rejects nonzero reserved bytes even with a valid checksum" {
    var index: usize = 33;
    while (index < 36) : (index += 1) {
        var buffer: [Slot.size]u8 = undefined;
        (Slot{ .version = 1, .rootReference = 4096, .rootKind = .blob, .freeListReference = 0, .logicalSize = 8192 }).encode(&buffer);
        buffer[index] = 1;
        restampChecksum(&buffer);
        try testing.expectError(error.ReservedNotZero, Slot.decode(&buffer));
    }
}

test "decode rejects kind none with a nonzero root" {
    var buffer: [Slot.size]u8 = undefined;
    (Slot{ .version = 1, .rootReference = 4096, .rootKind = .blob, .freeListReference = 0, .logicalSize = 8192 }).encode(&buffer);
    buffer[32] = 0; // none
    restampChecksum(&buffer);
    try testing.expectError(error.BadRootKind, Slot.decode(&buffer));
}

test "decode rejects a real kind with a null root" {
    const realKinds = [_]u8{ 1, 2, 3 };
    for (realKinds) |kindByte| {
        var buffer: [Slot.size]u8 = undefined;
        (Slot{ .version = 1, .rootReference = 0, .rootKind = .none, .freeListReference = 0, .logicalSize = 8192 }).encode(&buffer);
        buffer[32] = kindByte;
        restampChecksum(&buffer);
        try testing.expectError(error.BadRootKind, Slot.decode(&buffer));
    }
}

// Seeded fuzz, both directions. Valid slots of every kind must decode back
// exactly (no false negative). Forged slots with a restamped CRC must be
// accepted only when a hand-written rule says the kind byte, reserved bytes
// and root agree (no false positive), and raw byte damage with the old CRC
// must never decode to a different kind than was encoded.
test "fuzz: slot decode accepts every valid slot exactly and never accepts a forged or damaged kind" {
    var seed: u64 = 0x5107_0064;
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        errdefer std.debug.print("slot fuzz failed at seed {d}\n", .{seed});
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        // Direction 1: a valid slot of a random kind decodes back exactly.
        const kindByte = random.intRangeAtMost(u8, 0, 3);
        const kind: RootKind = @fromBackingInt(@intCast(kindByte));
        const root: u64 = if (kindByte == 0) 0 else random.intRangeAtMost(u64, 1, std.math.maxInt(u64));
        const slot = Slot{
            .version = random.int(u64),
            .rootReference = root,
            .rootKind = kind,
            .freeListReference = random.int(u64),
            .logicalSize = random.int(u64),
        };
        var buffer: [Slot.size]u8 = undefined;
        slot.encode(&buffer);
        const decoded = try Slot.decode(&buffer);
        try testing.expectEqual(slot.version, decoded.version);
        try testing.expectEqual(slot.rootReference, decoded.rootReference);
        try testing.expectEqual(slot.rootKind, decoded.rootKind);
        try testing.expectEqual(slot.freeListReference, decoded.freeListReference);
        try testing.expectEqual(slot.logicalSize, decoded.logicalSize);

        // Direction 2a: forge the kind byte, a reserved byte and maybe the
        // root, then restamp the CRC. Accept only what the rule allows.
        var forged = buffer;
        forged[32] = random.int(u8);
        if (random.boolean()) forged[33 + random.uintLessThan(usize, 3)] = random.int(u8);
        if (random.boolean()) std.mem.writeInt(u64, forged[8..16], if (random.boolean()) 0 else random.int(u64), .little);
        restampChecksum(&forged);
        const forgedRoot = std.mem.readInt(u64, forged[8..16], .little);
        const reservedClear = forged[33] == 0 and forged[34] == 0 and forged[35] == 0;
        const knownKind = forged[32] <= 3;
        const agrees = (forged[32] == 0) == (forgedRoot == 0);
        const shouldAccept = reservedClear and knownKind and agrees;
        if (Slot.decode(&forged)) |accepted| {
            try testing.expect(shouldAccept);
            try testing.expectEqual(forged[32], @backingInt(accepted.rootKind));
            try testing.expectEqual(forgedRoot, accepted.rootReference);
        } else |_| {
            try testing.expect(!shouldAccept);
        }

        // Direction 2b: raw damage to one to four bytes with the CRC left
        // alone. A decode that still succeeds must not report a different
        // kind or root than the bytes it accepted say, and the kind must be
        // the encoded one unless the damage also hit the kind byte and CRC.
        var damaged = buffer;
        const flips = random.intRangeAtMost(usize, 1, 4);
        var flip: usize = 0;
        while (flip < flips) : (flip += 1) {
            damaged[random.uintLessThan(usize, Slot.size)] ^= random.intRangeAtMost(u8, 1, 255);
        }
        if (Slot.decode(&damaged)) |accepted| {
            try testing.expectEqual(damaged[32], @backingInt(accepted.rootKind));
            try testing.expectEqual(std.mem.readInt(u64, damaged[8..16], .little), accepted.rootReference);
            try testing.expectEqual(std.hash.Crc32.hash(damaged[0..36]), std.mem.readInt(u32, damaged[36..40], .little));
        } else |_| {}

        seed +%= 0x9E3779B97F4A7C15;
    }
}
