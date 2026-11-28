# airdb

An embedded, single-file object database written in Zig, built for mobile and
desktop apps that need durable local storage at millions of entities without a
server, a WAL, or a dependency tree.

- **Zero data loss by construction.** Every commit is a two-slot atomic
  protocol behind a full durability barrier (`F_FULLFSYNC` on Apple
  hardware). A crash at any instruction leaves the previous version intact and
  recoverable.
- **MVCC snapshots.** Readers never block the writer and never see partial
  state. Past versions stay readable through a configurable retention window
  (point-in-time reads).
- **Typed object store.** Types with int/blob/list/set/dict properties,
  stable object keys, optimistic per-row versioning, secondary value indexes,
  and links with nullify/cascade/block delete rules.
- **Multi-process.** Several processes can attach to one database file; a
  coordination sidecar carries the write lock, reader pins, and the shared
  space-reclaim horizon.
- **C ABI.** A static library plus `include/airdb.h` expose CRUD, bulk
  import/append, and explicit transactions to Swift, Kotlin, and anything else
  that speaks C.

## Status

Pre-1.0. The on-disk format is not yet stable between commits. POSIX (macOS,
Linux) and Windows.

| Platform | CI | Notes |
| --- | --- | --- |
| Linux (ubuntu-latest) | tested | `zig build test` |
| macOS (macos-latest) | tested | `zig build test` |
| Windows (windows-latest) | tested | `zig build test` |
| iOS device (`aarch64-ios`) | build only | static library; nothing runs |
| iOS simulator (`aarch64-ios-simulator`, `x86_64-ios-simulator`) | build only | static library; nothing runs |
| Android (`aarch64-linux-android`, `x86_64-linux-android`) | build only | static library; nothing runs |

The mobile builds are cross-compiled on Linux. Zig needs no Apple SDK or
Android NDK for the static library. CI also checks formatting and runs the
benchmark suite on Linux; the benchmark job is not a support claim.

## Building

Requires Zig 0.17.1.

```sh
zig build test    # unit + integration tests + C ABI smoke test
zig build bench   # performance suite (1M-entity tier)
zig build         # static library: zig-out/lib/libairdb.a + zig-out/include/airdb.h
```

Benchmark options:

```sh
zig build bench -- --scale=10m       # 10M tier
zig build bench -- --json=PATH       # append one JSON object per scenario
zig build bench -- --only=NAME       # single scenario
```

`bench/baseline-1m.json` holds the committed 1M baseline; see
[docs/benchmarks.md](docs/benchmarks.md) for current numbers.

## Quick look (Zig)

See [docs/usage.md](docs/usage.md) for adding the package and for queries.

```zig
const airdb = @import("airdb");

var database = try airdb.Database.create(allocator, "/abs/path/app.airdb");
defer database.deinit();

// Define a type: primaryKey (int) + name (blob) + an indexed int.
var writeTransaction = try database.beginWrite();
var directoryReference = try airdb.typeDirectory.createWithDefinitions(&writeTransaction, &.{
    &.{ .{ .kind = .int }, .{ .kind = .blob }, .{ .kind = .int, .indexed = true } },
});
directoryReference = (try airdb.typeRouting.insert(&writeTransaction, directoryReference, 0, &.{
    .{ .int = 1 }, .{ .bytes = "Ada" }, .{ .int = 1815 },
})).directoryReference;
writeTransaction.setRoot(directoryReference, .typeDirectory); // the kind is stored in the commit slot
_ = try writeTransaction.commit(); // durable here

var readTransaction = try database.beginRead();
defer readTransaction.end();
var out: [3]airdb.typeDirectory.Value = undefined;
_ = try airdb.typeRouting.get(&readTransaction, readTransaction.root(), 0, 1, &out);
```

## Quick look (C)

```c
#include "airdb.h"

AirdbDatabase *database = airdb_open("/abs/path/app.airdb", 2);
uint64_t row[2] = {1, 42};
airdb_insert(database, row, 2);

AirdbTxn *transaction = airdb_begin(database);        /* batch: one durable commit */
uint64_t a[2] = {2, 10}, b[2] = {3, 20};
airdb_txn_insert(transaction, a, 2);
airdb_txn_insert(transaction, b, 2);
airdb_commit(transaction);
airdb_close(database);
```

## Documentation

- [docs/usage.md](docs/usage.md): adding the package, and Zig and C usage
- [CHANGELOG.md](CHANGELOG.md): release notes
- [docs/architecture.md](docs/architecture.md) — layers, commit protocol,
  MVCC and space reclamation, compaction
- [docs/features.md](docs/features.md) — the full feature surface with code
  pointers
- [docs/format.md](docs/format.md) — on-disk layout
- [docs/benchmarks.md](docs/benchmarks.md) — how to run the suite and current
  numbers
- [docs/limits.md](docs/limits.md) — the honest list: threading contract,
  single-writer model, format caveats
- [standards.md](standards.md): engineering standards
- [Documentation/README.md](Documentation/README.md): engineering index

## Design principles

Safety first, then performance; both are measured, not assumed. The test
suite injects flush failures at exact commit steps, corrupts headers, slots,
catalogs, and indexes on purpose, and verifies both directions of every
secondary-index invariant. The bench suite runs at 1M+ entities and keeps a
committed baseline so regressions show up as diffs.
