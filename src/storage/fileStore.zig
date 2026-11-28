//! Header, mmap, and injectable Syncing for airdb.
//!
//! Zig 0.16 API adaptations used throughout:
//!   - std.fs.File           -> std.Io.File  (std.fs.File removed in 0.16)
//!   - std.fs.createFileAbsolute/openFileAbsolute
//!                           -> std.Io.Dir.createFileAbsolute/openFileAbsolute(io, ...)
//!   - File.setEndPos(n)     -> File.setLength(io, n)
//!   - File.getEndPos()      -> File.length(io) -> u64
//!   - File.sync()           -> File.sync(io)
//!   - File.close()          -> File.close(io)
//!   - mmap alignment        -> []align(std.heap.page_size_min) u8
//!   - mmap flags            -> .{ .TYPE = .SHARED } (not .SHARED = true)
//!   - page-size constant    -> std.heap.page_size_min (compile-time lower bound)
//!   - Dir.realpathAlloc     -> Dir.realPath(io, buffer) with stack buffer
//!   - Io instance           -> std.Io.Threaded.global_single_threaded.io()
//!       (always initialized; works in both test and production contexts)

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const platform = @import("../platform.zig");
const Syncing = @import("syncer.zig").Syncing;
const FileSyncer = @import("syncer.zig").FileSyncer;

// ---------------------------------------------------------------------------
// Public constants
// ---------------------------------------------------------------------------

/// File magic: "airdb_0001". `open` fails with `error.BadMagic` on any other value.
pub const airdbMagic: u64 = 0x6169726462_0001;
/// Size of the header page; the header and both commit slots live in it.
pub const defaultPageSize: u32 = 4096;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// On-disk byte-order marker recorded in the header (only .little is accepted).
pub const Endianness = enum(u8) { little = 1, big = 2 };

/// The decoded fixed file header: magic, page size, endianness, the active
/// commit slot, and the logical (in-use) file size.
pub const Header = struct {
    magic: u64,
    pageSize: u32,
    endianness: Endianness,
    activeSlot: u8,
    logicalSize: u64,
};

// ---------------------------------------------------------------------------
// FileStore
// ---------------------------------------------------------------------------

/// The mapped database file: owns the file handle, the append-only section
/// mappings, the parsed header, and the injected durability barrier.
pub const FileStore = struct {
    allocator: std.mem.Allocator, // reserved for future allocations (buffer pool, catalog pages)
    file: Io.File,
    /// Always points at section 0's mapping. The header and the two commit slots live in
    /// section 0, so every `store.map[...]` access (header, slots) stays correct.
    map: []align(std.heap.page_size_min) u8,
    /// Append-only list of fixed-size sections covering the file. Existing entries are
    /// never remapped or moved on growth; growth only appends. Unmapped in deinit.
    sections: std.ArrayList(platform.Section),
    header: Header,
    syncer: Syncing,
    /// True when the header CRC32 matches the stored checksum at [28..32].
    /// Set by readHeader (open path) or to true after writeHeader (create/persistHeader path).
    /// Recovery in database.zig openWith reads this to decide whether to trust activeSlot.
    headerChecksumOk: bool,
    /// Measurement-only counters accumulated since open. Total nanoseconds spent in
    /// blocking file.setLength (file growth) and the number of such calls. Read via
    /// Database.metrics(); never affect behavior.
    setlengthNs: u64 = 0,
    setlengthCalls: u64 = 0,

    /// Per-open maximum file size; caps the number of sections (maxSections =
    /// maxReserved / sectionSize). See `platform.maxReserved` for the host-size split.
    pub const maxReserved: usize = platform.maxReserved;

    /// Returns the blocking Io instance used for all file operations.
    /// This is always initialized (compile-time constant vtable), so it
    /// works in both test and production contexts without passing Io around.
    // Phase 1 single-process/single-thread only. Phase 4 (multi-process/threaded) must replace this global Io.
    inline fn sysIo() Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    /// Create a new database file at the given absolute path, truncating any
    /// existing file. Maps section 0 and writes the header.
    pub fn create(
        allocator: std.mem.Allocator,
        path: []const u8,
        syncer: Syncing,
    ) !FileStore {
        const io = sysIo();
        const file = try Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = true,
        });
        errdefer file.close(io);

        var store = FileStore{
            .allocator = allocator,
            .file = file,
            .map = undefined, // set by ensureMapped below
            .sections = .empty,
            .header = .{
                .magic = airdbMagic,
                .pageSize = defaultPageSize,
                .endianness = .little,
                .activeSlot = 0,
                .logicalSize = defaultPageSize,
            },
            .syncer = syncer,
            .headerChecksumOk = false, // set to true after writeHeader below
        };
        errdefer {
            for (store.sections.items) |*section| section.unmap();
            store.sections.deinit(allocator);
        }

        // Extend the file to one section and map it; header + commit slots live here.
        try store.ensureMapped(platform.sectionSize);

        store.writeHeader();
        store.headerChecksumOk = true;
        try store.syncer.flush(store.file);
        return store;
    }

    /// Open an existing database file at the given absolute path.
    /// Validates the header magic and endianness.
    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        syncer: Syncing,
    ) !FileStore {
        const io = sysIo();
        const file = try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        const openedLength = try file.length(io);
        if (openedLength < defaultPageSize) return error.Corrupt;

        var store = FileStore{
            .allocator = allocator,
            .file = file,
            .map = undefined, // set by ensureMapped below
            .sections = .empty,
            .header = undefined,
            .syncer = syncer,
            .headerChecksumOk = false, // set by readHeader below
        };
        errdefer {
            for (store.sections.items) |*section| section.unmap();
            store.sections.deinit(allocator);
        }

        // Map all sections covering the existing file. ensureMapped rounds the file up to
        // a whole-section multiple first (an old file whose length is not a section
        // multiple is extended via setLength before mapping), so every section is fully
        // backed before any dereference.
        try store.ensureMapped(@intCast(openedLength));
        try store.readHeader();
        return store;
    }

    /// Unmap every section and close the file.
    pub fn deinit(self: *FileStore) void {
        for (self.sections.items) |*section| section.unmap();
        self.sections.deinit(self.allocator);
        self.file.close(sysIo());
    }

    // Header byte layout (fixed):
    //   [0..8]   magic        u64 LE
    //   [8..12]  pageSize    u32 LE
    //   [12]     endianness   u8
    //   [13]     activeSlot  u8
    //   [14..16] reserved     (zero)
    //   [16..24] logicalSize u64 LE
    //   [24..28] reserved     (zero, covered by checksum)
    //   [28..32] checksum     CRC32 of [0..28], u32 LE

    const offset = struct {
        const magic: usize = 0;
        const pageSize: usize = 8;
        const endianness: usize = 12;
        const activeSlot: usize = 13;
        const logicalSize: usize = 16;
        // [24..28] reserved -- zeroed before hashing, covered by checksum
        const checksum: usize = 28;
    };

    fn writeHeader(self: *FileStore) void {
        std.mem.writeInt(u64, self.map[offset.magic..][0..8], self.header.magic, .little);
        std.mem.writeInt(u32, self.map[offset.pageSize..][0..4], self.header.pageSize, .little);
        self.map[offset.endianness] = @backingInt(self.header.endianness);
        self.map[offset.activeSlot] = self.header.activeSlot;
        // [14..16] reserved -- zero explicitly so the CRC is deterministic
        @memset(self.map[14..16], 0);
        std.mem.writeInt(u64, self.map[offset.logicalSize..][0..8], self.header.logicalSize, .little);
        // [24..28] reserved -- zero explicitly so the CRC is deterministic
        @memset(self.map[24..28], 0);
        // CRC32 over [0..28] written little-endian at [28..32]
        const crc = std.hash.Crc32.hash(self.map[0..28]);
        std.mem.writeInt(u32, self.map[offset.checksum..][0..4], crc, .little);
    }

    /// Parse and validate the header from the mapping: a wrong magic or
    /// endianness is a hard error, while the CRC32 verdict is only recorded
    /// in headerChecksumOk (never a failure) so database recovery can decide
    /// whether to trust activeSlot.
    pub fn readHeader(self: *FileStore) !void {
        if (self.map.len < defaultPageSize) return error.Corrupt;

        const magic = std.mem.readInt(u64, self.map[offset.magic..][0..8], .little);
        if (magic != airdbMagic) return error.BadMagic;

        const pageSize = std.mem.readInt(u32, self.map[offset.pageSize..][0..4], .little);

        const endiannessByte = self.map[offset.endianness];
        // Zig 0.16: std.meta.intToEnum removed; use std.enums.fromInt instead.
        const endianness = std.enums.fromInt(Endianness, endiannessByte) orelse
            return error.UnsupportedEndianness;
        if (endianness != .little) return error.UnsupportedEndianness;

        const activeSlot = self.map[offset.activeSlot];
        const logicalSize = std.mem.readInt(u64, self.map[offset.logicalSize..][0..8], .little);

        // Validate header CRC32: hash [0..28], compare to stored u32 at [28..32].
        // A mismatch sets headerChecksumOk = false but does NOT hard-fail;
        // database.zig openWith decides how to recover.
        const storedCrc = std.mem.readInt(u32, self.map[offset.checksum..][0..4], .little);
        const computedCrc = std.hash.Crc32.hash(self.map[0..28]);
        self.headerChecksumOk = (storedCrc == computedCrc);

        self.header = .{
            .magic = magic,
            .pageSize = pageSize,
            .endianness = endianness,
            .activeSlot = activeSlot,
            .logicalSize = logicalSize,
        };
    }

    /// Ensure the file is mapped by enough sections to cover `byteLen` bytes.
    /// Extends the file to a whole-section multiple, then maps each not-yet-mapped
    /// section. Existing sections are never remapped or moved, so live pointers stay
    /// valid. `self.map` is (re)pointed at section 0 afterwards.
    /// Returns `error.FileTooLarge` if the required size exceeds `maxReserved`.
    pub fn ensureMapped(self: *FileStore, byteLen: usize) !void {
        const maxSections = maxReserved >> platform.sectionShift;
        const needed = @max((byteLen + platform.sectionSize - 1) >> platform.sectionShift, 1);
        if (needed > maxSections) return error.FileTooLarge;

        const wantBytes: u64 = @as(u64, needed) << platform.sectionShift;
        if (try self.file.length(sysIo()) < wantBytes) {
            // Measurement only: time the blocking setLength; no behavior change.
            const io = sysIo();
            const slStart = Io.Clock.now(.awake, io).nanoseconds;
            try self.file.setLength(io, wantBytes);
            self.setlengthNs += @intCast(Io.Clock.now(.awake, io).nanoseconds - slStart);
            self.setlengthCalls += 1;
        }

        var sectionIndex: usize = self.sections.items.len;
        while (sectionIndex < needed) : (sectionIndex += 1) {
            const section = try platform.mapSection(self.file, @as(u64, sectionIndex) << platform.sectionShift, platform.sectionSize);
            try self.sections.append(self.allocator, section);
        }
        self.map = self.sections.items[0].map;
    }

    /// Grow the file and its mapping to cover at least `minLen` bytes by appending
    /// sections. Existing section base pointers never change; live pointers remain valid.
    /// Returns `error.FileTooLarge` if `minLen` exceeds `maxReserved`.
    pub fn grow(self: *FileStore, minLen: usize) !void {
        if (minLen <= self.sections.items.len * platform.sectionSize) return;
        try self.ensureMapped(minLen);
    }

    /// Return the current on-disk file length in bytes (a whole-section multiple).
    pub fn fileLength(self: *FileStore) !u64 {
        return self.file.length(sysIo());
    }

    /// The live section table, for the arena's reference translation.
    pub fn sectionsView(self: *FileStore) []const platform.Section {
        return self.sections.items;
    }

    /// Re-encode the in-memory header into the mmap'd page and mark the
    /// checksum valid. Does not flush: durability requires a subsequent
    /// Syncing.flush.
    pub fn persistHeader(self: *FileStore) void {
        self.writeHeader();
        self.headerChecksumOk = true;
    }

    /// Test-only: re-parse the header from the current mmap contents.
    /// Used to observe headerChecksumOk after in-place map tampering.
    pub fn reReadHeaderForTest(self: *FileStore) !void {
        try self.readHeader();
    }
};

// ---------------------------------------------------------------------------
// Durable-file helpers
// ---------------------------------------------------------------------------

/// Delete an absolute path, treating a missing file as success. Used to remove
/// coordination files during the publish step of in-place compaction. Any other
/// failure is swallowed best-effort: the data file is already published by the
/// atomic rename, and a leftover/stale coordination file is recreated fresh by Database.open
/// (openOrCreate), so it cannot corrupt the published data. Does I/O.
pub fn deleteAbsoluteIgnoreMissing(io: Io, absPath: []const u8) void {
    Io.Dir.deleteFileAbsolute(io, absPath) catch {};
}

/// Make the directory ENTRY for `path` durable by fsync'ing its parent directory.
/// Uses libc fsync directly on the directory fd, which is the portable POSIX way:
/// the std.Io File sync wrapper panics with BADF on a directory handle on Linux.
/// Best-effort -- errors are swallowed. No-op on Windows. Does I/O.
pub fn syncParentDirectory(path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const directoryPath = std.fs.path.dirname(path) orelse return;
    var parentDirectory = std.Io.Dir.openDirAbsolute(io, directoryPath, .{}) catch return;
    defer parentDirectory.close(io);
    _ = std.c.fsync(parentDirectory.handle);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "real syncer flush succeeds (exercises the platform durability path)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const directoryPath = pathBuffer[0..pathLen];
    const filePath = try std.fs.path.join(testing.allocator, &.{ directoryPath, "fsync.airdb" });
    defer testing.allocator.free(filePath);
    var store = try FileStore.create(testing.allocator, filePath, FileSyncer.any());
    defer store.deinit();
    try store.syncer.flush(store.file); // explicit second flush must also succeed
}

test "header checksum validates on a clean file and fails when the header is tampered" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const filePath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..pathLen], "hcrc.airdb" });
    defer testing.allocator.free(filePath);
    {
        var store = try FileStore.create(testing.allocator, filePath, FileSyncer.any());
        defer store.deinit();
        try testing.expect(store.headerChecksumOk);
    }
    {
        var store = try FileStore.open(testing.allocator, filePath, FileSyncer.any());
        defer store.deinit();
        try testing.expect(store.headerChecksumOk);
        store.map[13] ^= 0xFF; // scramble activeSlot byte
        try store.reReadHeaderForTest();
        try testing.expect(!store.headerChecksumOk);
    }
}

test "create writes a header that reopen reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Zig 0.16: Dir.realpathAlloc no longer exists.
    // Use Dir.realPath(io, buffer) with a stack buffer instead.
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const directoryPath = pathBuffer[0..pathLen];

    const filePath = try std.fs.path.join(testing.allocator, &.{ directoryPath, "wsk.airdb" });
    defer testing.allocator.free(filePath);

    {
        var store = try FileStore.create(testing.allocator, filePath, FileSyncer.any());
        defer store.deinit();
        try testing.expectEqual(@as(u32, defaultPageSize), store.header.pageSize);
        try testing.expectEqual(Endianness.little, store.header.endianness);
    }
    {
        var store = try FileStore.open(testing.allocator, filePath, FileSyncer.any());
        defer store.deinit();
        try testing.expectEqual(airdbMagic, store.header.magic);
        // A hand literal, not airdbMagic: comparing against the same constant
        // on both sides cannot fail however the implementation behaves.
        try testing.expectEqual(@as(u64, 0x6169726462_0001), store.header.magic);
    }
}

test "a file without the current magic is refused with error.BadMagic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const filePath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..pathLen], "bad_magic.airdb" });
    defer testing.allocator.free(filePath);

    {
        var store = try FileStore.create(testing.allocator, filePath, FileSyncer.any());
        store.deinit();
    }

    // Overwrite bytes [0..8) with a value that is not any airdb magic, while
    // the file is genuinely closed (no FileStore handle open).
    {
        const file = try Io.Dir.openFileAbsolute(testing.io, filePath, .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, "notairdb", 0);
    }

    try testing.expectError(error.BadMagic, FileStore.open(testing.allocator, filePath, FileSyncer.any()));
}

test "grow adds sections, section 0 base stable, existing bytes preserved" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const fpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "grow.airdb" });
    defer testing.allocator.free(fpath);
    var store = try FileStore.create(testing.allocator, fpath, FileSyncer.any());
    defer store.deinit();
    const sectionsBefore = store.sections.items.len;
    const baseBefore = @intFromPtr(store.map.ptr);
    store.map[4096] = 0xAB;
    // Cross into a second section.
    try store.grow(platform.sectionSize + 4096 * 10);
    try testing.expect(store.sections.items.len > sectionsBefore);
    // Section 0 (where `map` points) is never remapped or moved.
    try testing.expectEqual(baseBefore, @intFromPtr(store.map.ptr));
    try testing.expectEqual(@as(u8, 0xAB), store.map[4096]);
}

test "grow beyond the reservation fails cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const fpath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..dlen], "toobig.airdb" });
    defer testing.allocator.free(fpath);
    var store = try FileStore.create(testing.allocator, fpath, FileSyncer.any());
    defer store.deinit();
    // The check rejects before any setLength, so no oversized file is created.
    try testing.expectError(error.FileTooLarge, store.grow(FileStore.maxReserved + defaultPageSize));
}

// ---------------------------------------------------------------------------
// Header parser boundary pins and seeded fuzz
// ---------------------------------------------------------------------------

const HeaderBytes = [defaultPageSize]u8;

// Hand-encode a header page: magic, pageSize, endianness, activeSlot,
// logicalSize, zero reserved bytes and a CRC32 over [0, 28). Written from the
// documented layout, not through writeHeader, so it checks the parser against
// the spec rather than against itself.
fn encodeHeaderBytes(bytes: []u8, magic: u64, pageSize: u32, endianness: u8, activeSlot: u8, logicalSize: u64) void {
    @memset(bytes[0..32], 0);
    std.mem.writeInt(u64, bytes[0..8], magic, .little);
    std.mem.writeInt(u32, bytes[8..12], pageSize, .little);
    bytes[12] = endianness;
    bytes[13] = activeSlot;
    std.mem.writeInt(u64, bytes[16..24], logicalSize, .little);
    std.mem.writeInt(u32, bytes[28..32], std.hash.Crc32.hash(bytes[0..28]), .little);
}

fn restampHeaderChecksum(bytes: []u8) void {
    std.mem.writeInt(u32, bytes[28..32], std.hash.Crc32.hash(bytes[0..28]), .little);
}

const HeaderHarness = struct {
    tmp: testing.TmpDir,
    path: []u8,
    store: FileStore,
    realMap: []align(std.heap.page_size_min) u8,
    page: HeaderBytes align(std.heap.page_size_min) = undefined,

    fn start(self: *HeaderHarness) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const pathLen = try self.tmp.dir.realPath(testing.io, &pathBuffer);
        self.path = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..pathLen], "header.airdb" });
        errdefer testing.allocator.free(self.path);
        self.store = try FileStore.create(testing.allocator, self.path, FileSyncer.any());
        self.realMap = self.store.map;
        @memset(&self.page, 0);
    }

    fn finish(self: *HeaderHarness) void {
        self.store.map = self.realMap;
        self.store.deinit();
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    // Parse the first `length` bytes of the local page as the mapping.
    fn parse(self: *HeaderHarness, length: usize) !void {
        self.store.map = self.page[0..length];
        defer self.store.map = self.realMap;
        try self.store.reReadHeaderForTest();
    }
};

test "readHeader accepts a 4096-byte map with a valid header and reads every field back" {
    var harness: HeaderHarness = undefined;
    try harness.start();
    defer harness.finish();
    encodeHeaderBytes(&harness.page, 0x6169726462_0001, 8192, 1, 1, 0x0102030405060708);
    try harness.parse(4096);
    try testing.expect(harness.store.headerChecksumOk);
    try testing.expectEqual(@as(u64, 0x6169726462_0001), harness.store.header.magic);
    try testing.expectEqual(@as(u32, 8192), harness.store.header.pageSize);
    try testing.expectEqual(Endianness.little, harness.store.header.endianness);
    try testing.expectEqual(@as(u8, 1), harness.store.header.activeSlot);
    try testing.expectEqual(@as(u64, 0x0102030405060708), harness.store.header.logicalSize);
}

test "readHeader rejects a 4095-byte map as Corrupt even when the header bytes are valid" {
    var harness: HeaderHarness = undefined;
    try harness.start();
    defer harness.finish();
    encodeHeaderBytes(&harness.page, 0x6169726462_0001, 4096, 1, 0, 4096);
    try testing.expectError(error.Corrupt, harness.parse(4095));
    try testing.expectError(error.Corrupt, harness.parse(32));
    try testing.expectError(error.Corrupt, harness.parse(0));
    try harness.parse(4096);
}

test "FileStore.open rejects a 4095-byte file as Corrupt and accepts a valid 4096-byte file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathBuffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const pathLen = try tmp.dir.realPath(testing.io, &pathBuffer);
    const shortPath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..pathLen], "short.airdb" });
    defer testing.allocator.free(shortPath);
    const exactPath = try std.fs.path.join(testing.allocator, &.{ pathBuffer[0..pathLen], "exact.airdb" });
    defer testing.allocator.free(exactPath);

    var bytes: HeaderBytes = undefined;
    @memset(&bytes, 0);
    encodeHeaderBytes(&bytes, 0x6169726462_0001, 4096, 1, 0, 4096);
    {
        const file = try Io.Dir.createFileAbsolute(testing.io, shortPath, .{});
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, bytes[0..4095], 0);
    }
    {
        const file = try Io.Dir.createFileAbsolute(testing.io, exactPath, .{});
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, bytes[0..4096], 0);
    }
    try testing.expectError(error.Corrupt, FileStore.open(testing.allocator, shortPath, FileSyncer.any()));
    var store = try FileStore.open(testing.allocator, exactPath, FileSyncer.any());
    defer store.deinit();
    try testing.expect(store.headerChecksumOk);
    try testing.expectEqual(@as(u64, 4096), store.header.logicalSize);
}

test "header magic airdb_0001 is accepted and its neighbours are BadMagic" {
    var harness: HeaderHarness = undefined;
    try harness.start();
    defer harness.finish();
    encodeHeaderBytes(&harness.page, 0x6169726462_0001, 4096, 1, 0, 4096);
    try harness.parse(4096);
    try testing.expectEqual(airdbMagic, harness.store.header.magic);

    const rejected = [_]u64{
        0x6169726462_0000,
        0x6169726462_0002,
        0x6169726462_0001 - 1,
        0x6169726462_0001 + 1,
        0x6169726463_0001,
        0x6169726461_0001,
        0x0069726462_0001,
        0,
        std.math.maxInt(u64),
    };
    for (rejected) |magic| {
        encodeHeaderBytes(&harness.page, magic, 4096, 1, 0, 4096);
        try testing.expectError(error.BadMagic, harness.parse(4096));
    }
}

test "header endianness 1 (little) is accepted and 0, 2 (big) and 3 are UnsupportedEndianness" {
    var harness: HeaderHarness = undefined;
    try harness.start();
    defer harness.finish();
    encodeHeaderBytes(&harness.page, 0x6169726462_0001, 4096, 1, 0, 4096);
    try harness.parse(4096);
    try testing.expectEqual(Endianness.little, harness.store.header.endianness);
    for ([_]u8{ 0, 2, 3, 0xFF }) |byte| {
        encodeHeaderBytes(&harness.page, 0x6169726462_0001, 4096, byte, 0, 4096);
        try testing.expectError(error.UnsupportedEndianness, harness.parse(4096));
    }
}

test "header checksum match keeps headerChecksumOk true and a mismatch clears it without failing" {
    var harness: HeaderHarness = undefined;
    try harness.start();
    defer harness.finish();
    encodeHeaderBytes(&harness.page, 0x6169726462_0001, 16384, 1, 1, 65536);
    try harness.parse(4096);
    try testing.expect(harness.store.headerChecksumOk);

    // Wrong stored CRC: the fields still parse to the bytes, only the flag drops.
    harness.page[28] ^= 0x01;
    try harness.parse(4096);
    try testing.expect(!harness.store.headerChecksumOk);
    try testing.expectEqual(@as(u32, 16384), harness.store.header.pageSize);
    try testing.expectEqual(@as(u8, 1), harness.store.header.activeSlot);
    try testing.expectEqual(@as(u64, 65536), harness.store.header.logicalSize);

    // Each byte of the stored CRC and each covered byte counts.
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        encodeHeaderBytes(&harness.page, 0x6169726462_0001, 16384, 1, 1, 65536);
        harness.page[index] ^= 0x80;
        if (index < 8 or index == 12) {
            try testing.expect(std.meta.isError(harness.parse(4096)));
        } else {
            try harness.parse(4096);
            try testing.expect(!harness.store.headerChecksumOk);
        }
    }

    // A bad checksum with a bad magic is still BadMagic, and bad endianness still wins over the CRC.
    encodeHeaderBytes(&harness.page, 0x6169726462_0002, 4096, 1, 0, 4096);
    harness.page[28] ^= 0xFF;
    try testing.expectError(error.BadMagic, harness.parse(4096));
}

test "fuzz: random valid headers parse back exactly and mutated, truncated or restamped headers are never misread" {
    const seed: u64 = testing.random_seed;
    errdefer std.debug.print("seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var harness: HeaderHarness = undefined;
    try harness.start();
    defer harness.finish();

    var round: usize = 0;
    while (round < 300) : (round += 1) {
        const pageSize = random.int(u32);
        const activeSlot = random.int(u8);
        const logicalSize = random.int(u64);
        encodeHeaderBytes(&harness.page, airdbMagic, pageSize, 1, activeSlot, logicalSize);
        random.bytes(harness.page[32..]);

        // Direction 1: a valid header reads back exactly.
        try harness.parse(4096);
        try testing.expect(harness.store.headerChecksumOk);
        try testing.expectEqual(airdbMagic, harness.store.header.magic);
        try testing.expectEqual(pageSize, harness.store.header.pageSize);
        try testing.expectEqual(Endianness.little, harness.store.header.endianness);
        try testing.expectEqual(activeSlot, harness.store.header.activeSlot);
        try testing.expectEqual(logicalSize, harness.store.header.logicalSize);

        // Any shorter map is Corrupt, whatever the bytes say.
        try testing.expectError(error.Corrupt, harness.parse(random.uintLessThan(usize, 4096)));

        // Direction 2a: flip one bit in [0, 32) without restamping. The CRC32 detects any
        // single-bit flip, so a parse that succeeds must report headerChecksumOk false and
        // fields equal to the mutated bytes.
        const bit = random.uintLessThan(usize, 32 * 8);
        const byteIndex = bit / 8;
        harness.page[byteIndex] ^= @as(u8, 1) << @intCast(bit % 8);
        const magic = std.mem.readInt(u64, harness.page[0..8], .little);
        if (magic != airdbMagic) {
            try testing.expectError(error.BadMagic, harness.parse(4096));
        } else if (harness.page[12] != 1) {
            try testing.expectError(error.UnsupportedEndianness, harness.parse(4096));
        } else {
            try harness.parse(4096);
            try testing.expect(!harness.store.headerChecksumOk);
            try testing.expectEqual(std.mem.readInt(u32, harness.page[8..12], .little), harness.store.header.pageSize);
            try testing.expectEqual(harness.page[13], harness.store.header.activeSlot);
            try testing.expectEqual(std.mem.readInt(u64, harness.page[16..24], .little), harness.store.header.logicalSize);
        }

        // Direction 2b: random bytes in [0, 28) then a restamped CRC. Acceptance must follow
        // exactly the magic and endianness rules, and the checksum flag must be true.
        const damage = random.intRangeAtMost(usize, 1, 3);
        var hit: usize = 0;
        while (hit < damage) : (hit += 1) harness.page[random.uintLessThan(usize, 28)] = random.int(u8);
        restampHeaderChecksum(&harness.page);
        const forgedMagic = std.mem.readInt(u64, harness.page[0..8], .little);
        if (forgedMagic != airdbMagic) {
            try testing.expectError(error.BadMagic, harness.parse(4096));
        } else if (harness.page[12] != 1) {
            try testing.expectError(error.UnsupportedEndianness, harness.parse(4096));
        } else {
            try harness.parse(4096);
            try testing.expect(harness.store.headerChecksumOk);
            try testing.expectEqual(std.mem.readInt(u32, harness.page[8..12], .little), harness.store.header.pageSize);
            try testing.expectEqual(harness.page[13], harness.store.header.activeSlot);
            try testing.expectEqual(std.mem.readInt(u64, harness.page[16..24], .little), harness.store.header.logicalSize);
        }
    }
}
