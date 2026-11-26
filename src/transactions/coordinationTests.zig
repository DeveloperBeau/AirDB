const std = @import("std");
const testing = std.testing;
const coordination = @import("coordination.zig");
const platform = @import("../platform.zig");
const Coordination = coordination.Coordination;
const coordIo = coordination.coordIo;
const sentinelMax = coordination.sentinelMax;

test "coordination create initializes magic and zero attach count, reopen reads them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "x.coord" });
    defer testing.allocator.free(cpath);

    var coordinator1 = try Coordination.openOrCreate(cpath);
    try testing.expectEqual(@as(u32, 1), coordinator1.attach());
    var coordinator2 = try Coordination.openOrCreate(cpath);
    try testing.expectEqual(@as(u32, 2), coordinator2.attach());
    try testing.expectEqual(@as(u32, 1), coordinator2.detach());
    coordinator2.deinit();
    _ = coordinator1.detach();
    coordinator1.deinit();
}

test "a second openOrCreate preserves live coordination state" {
    // Regression: the init path must never re-zero an already-stamped page.
    // Attach count, claimed slot, published pin, and latest version written by
    // the first opener must all survive a second open of the same file.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "keep.coord" });
    defer testing.allocator.free(cpath);

    var coordinator1 = try Coordination.openOrCreate(cpath);
    defer coordinator1.deinit();
    _ = coordinator1.attach();
    const slot = (try coordinator1.claimSlot()).?;
    coordinator1.publishMinPinned(slot, 7);
    coordinator1.setLatestVersion(42);

    var coordinator2 = try Coordination.openOrCreate(cpath);
    defer coordinator2.deinit();
    try testing.expectEqual(@as(u32, 1), coordinator2.attachCount());
    try testing.expectEqual(@as(u64, 7), coordinator2.slotMinPinnedForTest(slot));
    try testing.expectEqual(@as(u64, 42), coordinator2.latestVersion());
    coordinator1.releaseSlot(slot);
    _ = coordinator1.detach();
}

test "openOrCreate succeeds while another holder owns the coordination flock" {
    // The init fast path must not block behind the write lock: an existing
    // (stamped) coordination file opens without touching the flock.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "locked.coord" });
    defer testing.allocator.free(cpath);

    var coordinatorA = try Coordination.openOrCreate(cpath);
    defer coordinatorA.deinit();
    try coordinatorA.lockExclusive(); // simulate a writer mid-transaction

    var coordinatorB = try Coordination.openOrCreate(cpath); // must not deadlock
    coordinatorB.deinit();
    coordinatorA.unlock();
}

test "latestVersion round-trips through the mapping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "y.coord" });
    defer testing.allocator.free(cpath);
    var coordinator = try Coordination.openOrCreate(cpath);
    defer coordinator.deinit();
    coordinator.setLatestVersion(42);
    try testing.expectEqual(@as(u64, 42), coordinator.latestVersion());
}

test "exclusive lock blocks a second holder via the same coordination file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "z.coord" });
    defer testing.allocator.free(cpath);

    var coordinatorA = try Coordination.openOrCreate(cpath);
    defer coordinatorA.deinit();
    var coordinatorB = try Coordination.openOrCreate(cpath); // separate open file description -> independent flock that contends
    defer coordinatorB.deinit();

    try coordinatorA.lockExclusive();
    try testing.expectError(error.WouldBlock, coordinatorB.tryLockExclusive());
    coordinatorA.unlock();
    try coordinatorB.tryLockExclusive();
    coordinatorB.unlock();
}

test "claim returns a slot index, publish and read back minPinned, release frees it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "p.coord" });
    defer testing.allocator.free(cpath);
    var coordinator = try Coordination.openOrCreate(cpath);
    defer coordinator.deinit();
    const slotIndex = (try coordinator.claimSlot()).?;
    coordinator.publishMinPinned(slotIndex, 7);
    try testing.expectEqual(@as(u64, 7), coordinator.slotMinPinnedForTest(slotIndex));
    coordinator.releaseSlot(slotIndex);
    try testing.expectEqual(@as(u32, 0), coordinator.slotPidForTest(slotIndex));
}

test "two claims get distinct slots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "p2.coord" });
    defer testing.allocator.free(cpath);
    var coordinator = try Coordination.openOrCreate(cpath);
    defer coordinator.deinit();
    const slotIndex = (try coordinator.claimSlot()).?;
    const slotIndexB = (try coordinator.claimSlot()).?;
    try testing.expect(slotIndex != slotIndexB);
    coordinator.releaseSlot(slotIndex);
    coordinator.releaseSlot(slotIndexB);
}

test "globalHorizon is the min of live slots minPinned, clamped to fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "gh.coord" });
    defer testing.allocator.free(cpath);
    var coordinator = try Coordination.openOrCreate(cpath);
    defer coordinator.deinit();
    const slotIndex = (try coordinator.claimSlot()).?;
    coordinator.publishMinPinned(slotIndex, 5);
    try testing.expectEqual(@as(u64, 5), coordinator.globalHorizon(100));
    coordinator.publishMinPinned(slotIndex, sentinelMax);
    try testing.expectEqual(@as(u64, 100), coordinator.globalHorizon(100));
    coordinator.releaseSlot(slotIndex);
}

test "globalHorizon ignores and reclaims a dead-pid slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "dead.coord" });
    defer testing.allocator.free(cpath);
    var coordinator = try Coordination.openOrCreate(cpath);
    defer coordinator.deinit();
    const live = (try coordinator.claimSlot()).?;
    coordinator.publishMinPinned(live, sentinelMax);
    coordinator.forgeSlotForTest(1, 0x7fffffff, 0, 3); // an almost-certainly-dead pid with a low minPinned
    try testing.expectEqual(@as(u64, 50), coordinator.globalHorizon(50));
    try testing.expectEqual(@as(u32, 0), coordinator.slotPidForTest(1)); // reclaimed
    coordinator.releaseSlot(live);
}

test "globalHorizon reclaims a slot whose live pid has the wrong incarnation token" {
    // A recycled pid must not keep a dead reader's pin alive: the slot names a
    // LIVE pid (our own) but a token from a different process incarnation, so
    // the horizon must ignore and reclaim it.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "recycled.coord" });
    defer testing.allocator.free(cpath);
    var coordinator = try Coordination.openOrCreate(cpath);
    defer coordinator.deinit();

    const myPid: u32 = @intCast(platform.currentPid());
    const myToken: u32 = @truncate(platform.processStartToken(myPid) orelse return error.SkipZigTest);
    coordinator.forgeSlotForTest(2, myPid, myToken +% 1, 3); // alive pid, wrong incarnation
    try testing.expectEqual(@as(u64, 50), coordinator.globalHorizon(50));
    try testing.expectEqual(@as(u32, 0), coordinator.slotPidForTest(2)); // reclaimed

    // A correctly claimed slot (matching token) still pins the horizon.
    const slotIndex = (try coordinator.claimSlot()).?;
    coordinator.publishMinPinned(slotIndex, 7);
    try testing.expectEqual(@as(u64, 7), coordinator.globalHorizon(50));
    coordinator.releaseSlot(slotIndex);
}

test "globalHorizon keeps a live-pid slot whose stored token is zero" {
    // A claimer that could not obtain its own start token stores 0. Treating
    // that as a token mismatch would reclaim a LIVE reader's slot and drop its
    // pin; the horizon must honor the pin (pid-only liveness) instead.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    const cpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "zerotoken.coord" });
    defer testing.allocator.free(cpath);
    var coordinator = try Coordination.openOrCreate(cpath);
    defer coordinator.deinit();

    const myPid: u32 = @intCast(platform.currentPid());
    coordinator.forgeSlotForTest(1, myPid, 0, 5); // alive pid, unknown incarnation
    try testing.expectEqual(@as(u64, 5), coordinator.globalHorizon(50));
    try testing.expectEqual(myPid, coordinator.slotPidForTest(1)); // not reclaimed
    coordinator.releaseSlot(1);
}

fn fuzzCoordPath(tmp: *testing.TmpDir, name: []const u8) ![]u8 {
    var pathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(coordIo(), &pathBuffer);
    return std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], name });
}

fn slotTokenFromMap(coordinator: *Coordination, slotIndex: usize) u32 {
    return std.mem.readInt(u32, coordinator.map[64 + slotIndex * 16 + 4 ..][0..4], .little);
}

test "sidecar fuzz reopen reads back the stored attach count, latest version and slots" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("sidecar round-trip fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cpath = try fuzzCoordPath(&tmp, "roundtrip.coord");
    defer testing.allocator.free(cpath);

    var iteration: usize = 0;
    while (iteration < 200) : (iteration += 1) {
        var pids: [64]u32 = undefined;
        var tokens: [64]u32 = undefined;
        var pins: [64]u64 = undefined;
        const attachCount = random.int(u32);
        const latest = random.int(u64);
        {
            var writer = try Coordination.openOrCreate(cpath);
            defer writer.deinit();
            @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(&writer.map[8]))), attachCount, .seq_cst);
            writer.setLatestVersion(latest);
            for (0..64) |slotIndex| {
                const filled = random.boolean();
                // Arbitrary pids: only raw fields are checked, never globalHorizon.
                pids[slotIndex] = if (filled) random.intRangeAtMost(u32, 1, std.math.maxInt(u32)) else 0;
                tokens[slotIndex] = random.int(u32);
                pins[slotIndex] = if (random.boolean()) sentinelMax else random.int(u64);
                writer.forgeSlotForTest(slotIndex, pids[slotIndex], tokens[slotIndex], pins[slotIndex]);
            }
        }
        var reader = try Coordination.openOrCreate(cpath);
        defer reader.deinit();
        try testing.expectEqual(coordination.coordMagic, std.mem.readInt(u64, reader.map[0..8], .little));
        try testing.expectEqual(attachCount, reader.attachCount());
        try testing.expectEqual(latest, reader.latestVersion());
        for (0..64) |slotIndex| {
            try testing.expectEqual(pids[slotIndex], reader.slotPidForTest(slotIndex));
            try testing.expectEqual(tokens[slotIndex], slotTokenFromMap(&reader, slotIndex));
            try testing.expectEqual(pins[slotIndex], reader.slotMinPinnedForTest(slotIndex));
        }
    }
}

test "sidecar fuzz reinitialises short and wrong-magic files" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("sidecar wrong-magic fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cpath = try fuzzCoordPath(&tmp, "short.coord");
    defer testing.allocator.free(cpath);

    var content: [4096]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 100) : (iteration += 1) {
        const length = switch (random.uintLessThan(u8, 4)) {
            0 => 0,
            1 => 4095,
            else => random.uintLessThan(usize, 4096),
        };
        random.bytes(content[0..length]);
        if (length >= 8 and std.mem.readInt(u64, content[0..8], .little) == coordination.coordMagic) content[0] ^= 1;
        {
            const file = try std.Io.Dir.createFileAbsolute(coordIo(), cpath, .{ .read = true, .truncate = true });
            defer file.close(coordIo());
            try file.writePositionalAll(coordIo(), content[0..length], 0);
        }
        var coordinator = try Coordination.openOrCreate(cpath);
        defer coordinator.deinit();
        try testing.expect(try coordinator.file.length(coordIo()) >= 4096);
        try testing.expectEqual(coordination.coordMagic, std.mem.readInt(u64, coordinator.map[0..8], .little));
        try testing.expectEqual(@as(u32, 0), coordinator.attachCount());
        try testing.expectEqual(@as(u64, 0), coordinator.latestVersion());
        for (0..64) |slotIndex| {
            try testing.expectEqual(@as(u32, 0), coordinator.slotPidForTest(slotIndex));
            try testing.expectEqual(@as(u64, 0), coordinator.slotMinPinnedForTest(slotIndex));
        }
    }
}

test "sidecar fuzz keeps a stamped page with random garbage in every other byte" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("sidecar garbage fuzz seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cpath = try fuzzCoordPath(&tmp, "garbage.coord");
    defer testing.allocator.free(cpath);

    var content: [4096]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 100) : (iteration += 1) {
        random.bytes(&content);
        std.mem.writeInt(u64, content[0..8], coordination.coordMagic, .little);
        {
            const file = try std.Io.Dir.createFileAbsolute(coordIo(), cpath, .{ .read = true, .truncate = true });
            defer file.close(coordIo());
            try file.writePositionalAll(coordIo(), &content, 0);
        }
        var coordinator = try Coordination.openOrCreate(cpath);
        defer coordinator.deinit();
        try testing.expectEqualSlices(u8, &content, coordinator.map);
        try testing.expectEqual(std.mem.readInt(u32, content[8..12], .little), coordinator.attachCount());
        try testing.expectEqual(std.mem.readInt(u64, content[16..24], .little), coordinator.latestVersion());
        for (0..64) |slotIndex| {
            const base = 64 + slotIndex * 16;
            try testing.expectEqual(std.mem.readInt(u32, content[base..][0..4], .little), coordinator.slotPidForTest(slotIndex));
            try testing.expectEqual(std.mem.readInt(u64, content[base + 8 ..][0..8], .little), coordinator.slotMinPinnedForTest(slotIndex));
        }
    }
}
