# Changelog

All notable changes to airdb are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [Semantic Versioning](https://semver.org/).

The on-disk format is not yet stable. Expect it to change between releases
until 1.0, with no migration support.

## [0.1.0] - Unreleased

First release. It requires Zig 0.17.1 and has no package dependencies. The
project is licensed under MPL-2.0.

### Added

- Embedded single-file object database written in Zig.
- Two-slot atomic commit behind a full durability barrier: `F_FULLFSYNC` on
  Apple hardware, `fsync` elsewhere.
- MVCC snapshots. Readers never block the writer. Point-in-time reads work
  within a configurable retention window.
- Typed object store with int, blob, list, set and dict properties, stable
  object keys, and optimistic per-row versioning.
- Secondary value indexes, including truncated-key blob indexes.
- Links with nullify, cascade and block delete rules.
- Query engine with predicate trees, ordering, pagination, distinct, groupBy,
  and include-fetch through `materializePage`.
- Bulk import and right-edge bulk append.
- Incremental and whole-file compaction, plus maintenance entry points.
- Schema migrations that add and remove properties.
- Offline `verifyIntegrity`. It audits the root by the kind recorded in the
  commit slot (fixes issue 64).
- Multi-process attach through a coordination sidecar.
- C ABI for CRUD, bulk operations and explicit transactions, in
  `include/airdb.h` and the static library. Blob, link and query are not
  exposed over the C ABI.
- `zig build` installs `airdb.h` next to the library, at
  `zig-out/include/airdb.h`. `build.zig.zon` `.paths` also include `include/`,
  `LICENSE` and `README.md`, so the package carries the header.
- Seeded fuzz tests for the index node parsers, and for the catalog, sidecar
  and node parsers.
- Relocate-and-poison test helper and related recovery tests, closing
  issue 67.
- CI runs the tests on Linux, macOS and Windows. It build-checks the static
  library for iOS (device and simulator) and Android (aarch64 and x86_64).
  Those targets are built only, not tested. The format check covers `tests/`.
- `CHANGELOG.md` and `docs/usage.md`. The Zig example in the usage guide is
  compiled by the test suite.

### Changed

- Breaking: `WriteTransaction.setRoot` takes a required kind, `setRoot(reference,
  kind)`. The kind is one of type directory, catalog or raw blob, and is
  recorded in the commit slot.
- Breaking: the commit slot is 40 bytes and carries a kind byte. The only
  format version is `airdb_0001`.
- Breaking: `airdb_open` on an existing file returns `NULL` unless the root is
  a single catalog. Type-directory and raw-blob roots are refused and the file
  is left untouched. Files created through `airdb_open` are catalog rooted and
  keep opening.
- Breaking: `maybeCompactStep` and `compactToNewFile` return `RootKindMismatch`
  on a root that is not a type directory.
- `VerifyError` gains `RootUnreadable`.
- Breaking, pre-1.0: the Zig package root no longer re-exports internals. The
  public API is the application surface (`Database`, `ReadTransaction`,
  `WriteTransaction`, `Reference`, `typeDirectory`, `typeRouting`, `catalog`,
  `objects`, `query`, `blob`, `collections`, `links`, `bulk`, `migrations`,
  `maintenance`, `verification`, `compaction`) plus a marked `airdb.internal`
  namespace for this repository's tests and bench. Zig callers that imported
  removed names from `@import("airdb")` must stop. The C ABI is unchanged.

### Fixed

- `verifyIntegrity` no longer guesses the root kind, so type-directory and
  raw-blob roots verify correctly (issue 64).
- Predicate reads on indexed paths are pinned against relocation.
