//! The airdb library root: the application API (Database, transactions,
//! records, schema, maintenance) plus one marked `internal` namespace for
//! this repository's tests and benchmarks.

/// One process's handle to a database file.
pub const Database = @import("database.zig").Database;
/// A pinned read snapshot over a Database.
pub const ReadTransaction = @import("database.zig").ReadTransaction;
/// The single in-flight mutation over a Database.
pub const WriteTransaction = @import("database.zig").WriteTransaction;
/// A node's stable identity: an absolute byte offset into the mapped file.
pub const Reference = @import("storage/reference.zig").Reference;

/// The type directory mapping type ids to catalog references.
pub const typeDirectory = @import("schema/typeDirectory.zig");
/// Object/link/delete routing through the type directory.
pub const typeRouting = @import("schema/typeRouting.zig");
/// The per-type catalog: property definitions, columns, and indexes.
pub const catalog = @import("schema/catalog.zig");
/// Typed encode/decode orchestration over the raw row layer.
pub const objects = @import("records/objects.zig");
/// Predicate queries, aggregation, and sorting over a catalog.
pub const query = @import("query.zig");
/// The blob heap with its tagged inline/chunked representation.
pub const blob = @import("records/blob.zig");
/// List/set/dict collection properties.
pub const collections = @import("records/collections.zig");
/// To-one and to-many links with backlink maintenance.
pub const links = @import("records/links.zig");
/// Bulk import and right-edge bulk append.
pub const bulk = @import("records/bulk.zig");
/// Structural schema evolution: add and remove properties.
pub const migrations = @import("schema/migrations.zig");

// Trees: the copy-on-write storage structures.
/// Column tree: dense row index -> u64 value.
pub const column = @import("trees/column.zig");
/// The column tree's on-disk node formats.
pub const columnNode = @import("trees/columnNode.zig");
/// u64-keyed B+tree (inline numeric keys).
pub const index = @import("trees/index.zig");
/// The key->value B+tree's on-disk node formats.
pub const indexNode = @import("trees/indexNode.zig");
/// Byte-keyed B+tree (blob-reference keys).
pub const byteKeyIndex = @import("trees/byteKeyIndex.zig");

// Storage primitives.
/// A node's stable identity: an absolute byte offset into the mapped file.
pub const Reference = @import("storage/reference.zig").Reference;
/// Bump allocation, pooled reuse, and the bounds-checked dereference chokepoint.
pub const arena = @import("storage/arena.zig");
/// The reclaimable-extent pool and its persisted chunk-chain format.
pub const freeList = @import("storage/freeList.zig");
/// Recovery of the persisted free-list chain on open/refresh.
pub const freeListRecovery = @import("storage/freeListRecovery.zig");
/// Header, mmap sections, and the file-backed store.
pub const fileStore = @import("storage/fileStore.zig");
/// The checksummed commit-slot encoding.
pub const slots = @import("storage/slots.zig");
/// What a committed root points at, as recorded in its commit slot.
pub const RootKind = @import("storage/rootKind.zig").RootKind;
/// Generic storage-node header encode/parse.
pub const node = @import("storage/node.zig");
/// The injectable durability barrier and its implementations.
pub const syncer = @import("storage/syncer.zig");
/// Injectable flush capability (see storage/syncer.zig).
pub const Syncing = @import("storage/syncer.zig").Syncing;
/// Test syncer that fails a chosen flush to simulate a crash.
pub const FailingSyncer = @import("storage/syncer.zig").FailingSyncer;

// Maintenance: compaction and relocation.
/// Type packing, incremental compaction, and whole-file compaction.
pub const compaction = @import("storage/compaction.zig");
/// Cross-database deep copying behind whole-file compaction.
pub const compactionCopy = @import("storage/compactionCopy.zig");
/// Moving a live row into a dead physical slot.
pub const relocation = @import("storage/relocation.zig");
/// Caller-driven upkeep entry points (budgeted compaction steps).
pub const maintenance = @import("maintenance.zig");
/// Offline integrity audit.
pub const verification = @import("verification.zig");
/// Type packing, incremental compaction, and whole-file compaction.
pub const compaction = @import("storage/compaction.zig");

/// Test and bench helpers for this repository; not part of the application API.
pub const internal = struct {
    /// Raw row CRUD over the catalog's columns and indexes.
    pub const rows = @import("records/rows.zig");
    /// Test syncer that fails a chosen flush to simulate a crash.
    pub const FailingSyncer = @import("storage/syncer.zig").FailingSyncer;
    /// Peak resident set size of the current process, in bytes.
    pub const peakResidentBytes = @import("platform.zig").peakResidentBytes;
    /// Cumulative minor/major page-fault counts.
    pub const pageFaults = @import("platform.zig").pageFaults;
};

// Every module is reached here so test discovery does not depend on a pub
// re-export. The architecture import scanner skips top-level test blocks.
test {
    _ = @import("database.zig");
    _ = @import("transactions/readTransaction.zig");
    _ = @import("transactions/writeTransaction.zig");
    _ = @import("transactions/versioning.zig");
    _ = @import("transactions/coordination.zig");
    _ = @import("records/objects.zig");
    _ = @import("records/rows.zig");
    _ = @import("records/blob.zig");
    _ = @import("records/collections.zig");
    _ = @import("records/links.zig");
    _ = @import("records/bulk.zig");
    _ = @import("schema/catalog.zig");
    _ = @import("schema/typeDirectory.zig");
    _ = @import("schema/typeRouting.zig");
    _ = @import("schema/migrations.zig");
    _ = @import("trees/column.zig");
    _ = @import("trees/columnNode.zig");
    _ = @import("trees/index.zig");
    _ = @import("trees/indexNode.zig");
    _ = @import("trees/byteKeyIndex.zig");
    _ = @import("storage/reference.zig");
    _ = @import("storage/arena.zig");
    _ = @import("storage/freeList.zig");
    _ = @import("storage/freeListRecovery.zig");
    _ = @import("storage/fileStore.zig");
    _ = @import("storage/slots.zig");
    _ = @import("storage/node.zig");
    _ = @import("storage/syncer.zig");
    _ = @import("storage/compaction.zig");
    _ = @import("storage/compactionCopy.zig");
    _ = @import("storage/relocation.zig");
    _ = @import("maintenance.zig");
    _ = @import("verification.zig");
    _ = @import("query.zig");
    _ = @import("cApi.zig");
    _ = @import("platform.zig");
}
