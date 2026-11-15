//! Ring assignment for every production file under src/.
//!
//! The architecture test reads this table to check that every import points
//! inward. Paths use "/" and are relative to the repo root.

/// Ring table for the inward-dependency rule, with its known exceptions.
pub const RingTable = struct {
    /// Dependency ring of a file. A file may import from a lower ring, or from another file in the same ring.
    /// Infrastructure is the exception. There a sideways import of a different file is banned unless the pair is allowlisted.
    pub const Ring = enum(u8) {
        entities = 1,
        domain = 2,
        infrastructure = 3,
        // Shared UI and Features have no files. The numbers stay so the table can grow later.
        sharedUi = 4,
        features = 5,
        composition = 6,
    };

    /// One production file and the ring it belongs to.
    pub const Entry = struct { path: []const u8, ring: Ring };

    /// One known outward or sideways import, keyed by file pair and not by line.
    pub const AllowedImport = struct { from: []const u8, to: []const u8, reason: []const u8 };

    /// Every production file under src/, each listed exactly once.
    pub const entries = [_]Entry{
        // Entities: plain data and on-disk formats.
        .{ .path = "src/storage/reference.zig", .ring = .entities },
        .{ .path = "src/storage/slots.zig", .ring = .entities },
        .{ .path = "src/storage/node.zig", .ring = .entities },
        .{ .path = "src/trees/indexNode.zig", .ring = .entities },
        .{ .path = "src/trees/columnNode.zig", .ring = .entities },
        .{ .path = "src/query/aggregate.zig", .ring = .entities },

        // Domain: engine logic. database.zig is the engine state aggregate, not the wiring root.
        .{ .path = "src/database.zig", .ring = .domain },
        .{ .path = "src/maintenance.zig", .ring = .domain },
        .{ .path = "src/query.zig", .ring = .domain },
        .{ .path = "src/verification.zig", .ring = .domain },
        .{ .path = "src/storage/arena.zig", .ring = .domain },
        .{ .path = "src/storage/compaction.zig", .ring = .domain },
        .{ .path = "src/storage/compactionCopy.zig", .ring = .domain },
        .{ .path = "src/storage/freeList.zig", .ring = .domain },
        .{ .path = "src/storage/freeListRecovery.zig", .ring = .domain },
        .{ .path = "src/storage/relocation.zig", .ring = .domain },
        .{ .path = "src/trees/bTreeCore.zig", .ring = .domain },
        .{ .path = "src/trees/byteKeyIndex.zig", .ring = .domain },
        .{ .path = "src/trees/column.zig", .ring = .domain },
        .{ .path = "src/trees/index.zig", .ring = .domain },
        .{ .path = "src/trees/indexBulkBuild.zig", .ring = .domain },
        .{ .path = "src/records/blob.zig", .ring = .domain },
        .{ .path = "src/records/blobIndexKey.zig", .ring = .domain },
        .{ .path = "src/records/bulk.zig", .ring = .domain },
        .{ .path = "src/records/collections.zig", .ring = .domain },
        .{ .path = "src/records/links.zig", .ring = .domain },
        .{ .path = "src/records/objects.zig", .ring = .domain },
        .{ .path = "src/records/rows.zig", .ring = .domain },
        .{ .path = "src/schema/catalog.zig", .ring = .domain },
        .{ .path = "src/schema/migrations.zig", .ring = .domain },
        .{ .path = "src/schema/typeDirectory.zig", .ring = .domain },
        .{ .path = "src/schema/typeRouting.zig", .ring = .domain },
        .{ .path = "src/transactions/readTransaction.zig", .ring = .domain },
        .{ .path = "src/transactions/writeTransaction.zig", .ring = .domain },
        .{ .path = "src/transactions/versioning.zig", .ring = .domain },
        .{ .path = "src/query/batch.zig", .ring = .domain },
        .{ .path = "src/query/evaluation.zig", .ring = .domain },
        .{ .path = "src/query/execution.zig", .ring = .domain },
        .{ .path = "src/query/grouping.zig", .ring = .domain },
        .{ .path = "src/query/include.zig", .ring = .domain },
        .{ .path = "src/query/materialized.zig", .ring = .domain },
        .{ .path = "src/query/ordering.zig", .ring = .domain },
        .{ .path = "src/query/paging.zig", .ring = .domain },
        .{ .path = "src/query/planner.zig", .ring = .domain },
        .{ .path = "src/query/predicate.zig", .ring = .domain },
        .{ .path = "src/query/scan.zig", .ring = .domain },

        // Infrastructure: OS and file system, one file per concern.
        .{ .path = "src/platform.zig", .ring = .infrastructure },
        .{ .path = "src/storage/syncer.zig", .ring = .infrastructure },
        .{ .path = "src/storage/fileStore.zig", .ring = .infrastructure },
        .{ .path = "src/transactions/coordination.zig", .ring = .infrastructure },

        // Composition: builds and wires concrete objects and exposes the boundary.
        .{ .path = "src/airdb.zig", .ring = .composition },
        .{ .path = "src/cApi.zig", .ring = .composition },
    };

    /// Existing violations. Each pair must still occur in src/, so this list can only shrink.
    pub const allowedImports = [_]AllowedImport{
        .{ .from = "src/database.zig", .to = "src/storage/fileStore.zig", .reason = "Database owns a concrete FileStore and also imports defaultPageSize" },
        .{ .from = "src/database.zig", .to = "src/storage/syncer.zig", .reason = "Database.create and open default to FileSyncer, and Syncing lives in this file" },
        .{ .from = "src/database.zig", .to = "src/transactions/coordination.zig", .reason = "Database owns a concrete Coordination sidecar and also imports sentinelMax" },
        .{ .from = "src/storage/arena.zig", .to = "src/platform.zig", .reason = "Arena.init takes a slice of platform Section" },
        .{ .from = "src/storage/compaction.zig", .to = "src/storage/fileStore.zig", .reason = "Compaction calls deleteAbsoluteIgnoreMissing and syncParentDirectory" },
        .{ .from = "src/storage/fileStore.zig", .to = "src/platform.zig", .reason = "FileStore uses platform mapSection and Section" },
        .{ .from = "src/transactions/coordination.zig", .to = "src/platform.zig", .reason = "Coordination uses platform process, map and lock helpers" },
        .{ .from = "src/database.zig", .to = "src/platform.zig", .reason = "Database uses sectionShift and sectionSize constants" },
        .{ .from = "src/records/blob.zig", .to = "src/platform.zig", .reason = "Blob uses the sectionSize constant" },
        .{ .from = "src/storage/freeListRecovery.zig", .to = "src/platform.zig", .reason = "Free-list recovery uses the sectionSize constant" },
        .{ .from = "src/transactions/versioning.zig", .to = "src/platform.zig", .reason = "Versioning uses the sectionSize constant" },
        .{ .from = "src/transactions/versioning.zig", .to = "src/transactions/coordination.zig", .reason = "Versioning uses the sentinelMax constant" },
        .{ .from = "src/transactions/versioning.zig", .to = "src/storage/fileStore.zig", .reason = "Versioning uses the defaultPageSize constant" },
        .{ .from = "src/verification.zig", .to = "src/platform.zig", .reason = "Verification uses the sectionSize constant" },
        .{ .from = "src/storage/fileStore.zig", .to = "src/storage/syncer.zig", .reason = "FileStore takes Syncing, and a top-level FileSyncer import is used only by tests" },
    };

    /// It is the pinned length of allowedImports, so lower it when an entry is removed and never raise it without review.
    pub const allowedImportCap = 15;

    /// Named imports that are not files and are always allowed.
    pub const ignoredModuleNames = [_][]const u8{ "std", "builtin" };
};
