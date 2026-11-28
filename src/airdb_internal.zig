//! Root of the build-internal `airdb_internal` module: the public application
//! API from airdb.zig plus helpers used only by this repository's integration
//! tests and benchmarks. It is never exposed to package users.

const airdb = @import("airdb.zig");

pub const Database = airdb.Database;
pub const ReadTransaction = airdb.ReadTransaction;
pub const WriteTransaction = airdb.WriteTransaction;
pub const Reference = airdb.Reference;
pub const typeDirectory = airdb.typeDirectory;
pub const typeRouting = airdb.typeRouting;
pub const catalog = airdb.catalog;
pub const objects = airdb.objects;
pub const query = airdb.query;
pub const blob = airdb.blob;
pub const collections = airdb.collections;
pub const links = airdb.links;
pub const bulk = airdb.bulk;
pub const migrations = airdb.migrations;
pub const maintenance = airdb.maintenance;
pub const verification = airdb.verification;
pub const compaction = airdb.compaction;
pub const RootKind = airdb.RootKind;

/// Raw row CRUD over the catalog's columns and indexes.
pub const rows = @import("records/rows.zig");
/// Test syncer that fails a chosen flush to simulate a crash.
pub const FailingSyncer = @import("storage/syncer.zig").FailingSyncer;
/// Peak resident set size of the current process, in bytes.
pub const peakResidentBytes = @import("platform.zig").peakResidentBytes;
/// Cumulative minor/major page-fault counts.
pub const pageFaults = @import("platform.zig").pageFaults;
