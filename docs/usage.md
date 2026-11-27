# Using airdb

airdb is pre-1.0 and its on-disk format is not yet stable. See
[Documentation/FormatStability.md](../Documentation/FormatStability.md).

It needs Zig 0.17.1. Paths passed to `create` and `open` must be absolute.

## Add the package (Zig)

Fetch the package and record it in `build.zig.zon`. The `v0.1.0` tag is not
published yet. Once it is, run:

```sh
zig fetch --save https://github.com/DeveloperBeau/AirDB/archive/refs/tags/v0.1.0.tar.gz
```

`zig fetch` writes the dependency entry and fills in the hash. Do not write
the hash by hand.

Then import the module in `build.zig`:

```zig
const airdb = b.dependency("airdb", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("airdb", airdb.module("airdb"));
```

In your code, `const airdb = @import("airdb");`.

The application API is `Database`, `ReadTransaction`, `WriteTransaction`,
`Reference`, and the modules `typeDirectory`, `typeRouting`, `catalog`,
`objects`, `query`, `blob`, `collections`, `links`, `bulk`, `migrations`,
`maintenance`, `verification` and `compaction`. `airdb.internal` holds helpers
for this repository's tests and bench. Do not use it from an application.

## Create or open a database

```zig
var database = try airdb.Database.create(allocator, "/abs/path/app.airdb");
defer database.deinit();
```

`Database.open(allocator, path)` opens an existing file.

## Write

A write transaction is the only way to change data. Nothing is visible to
other readers until `commit` returns, and the commit is durable when it does.

```zig
// Define a type: primaryKey (int) + name (blob) + an indexed int.
var writeTransaction = try database.beginWrite();
var directoryReference = try airdb.typeDirectory.createWithDefinitions(&writeTransaction, &.{
    &.{ .{ .kind = .int }, .{ .kind = .blob }, .{ .kind = .int, .indexed = true } },
});
directoryReference = (try airdb.typeRouting.insert(&writeTransaction, directoryReference, 0, &.{
    .{ .int = 1 }, .{ .bytes = "Ada" }, .{ .int = 1815 },
})).directoryReference;
writeTransaction.setRoot(directoryReference);
_ = try writeTransaction.commit(); // durable here
```

`setRoot` also records what kind of object the root is (type directory,
catalog or raw blob). Check its signature in the version you depend on.

## Read

A read transaction sees one consistent snapshot and never blocks the writer.

```zig
var readTransaction = try database.beginRead();
defer readTransaction.end();
var out: [3]airdb.typeDirectory.Value = undefined;
_ = try airdb.typeRouting.get(&readTransaction, readTransaction.root(), 0, 1, &out);
```

## Query

A request defaults to every live row, ordered by object key ascending, with no
paging. `query.where` appends the matching object keys to a list.

```zig
var keys = std.ArrayList(u64).empty;
defer keys.deinit(allocator);
const catalogReference = try airdb.typeDirectory.catalogReference(&readTransaction, readTransaction.root(), 0);
try airdb.query.where(
    &readTransaction,
    catalogReference,
    .{ .predicate = .{ .comparison = .{ .property = 2, .operator = .eq, .value = .{ .int = 1815 } } } },
    &keys,
    allocator,
);
```

The Zig snippets above are the body of `run` in
[tests/usageExample.zig](../tests/usageExample.zig). The test suite compiles
and runs it, so they cannot drift from the API.

## Use from C

`zig build` writes `zig-out/lib/libairdb.a` and installs the header at
`zig-out/include/airdb.h`.

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

Compile and link against the installed files:

```sh
cc -I zig-out/include app.c zig-out/lib/libairdb.a -o app
```

The C ABI covers CRUD, bulk import and append, and explicit transactions.
Blob, link and query are not exposed over C.

As of 0.1.0, `airdb_open` on an existing file returns `NULL` unless the root is
a single catalog. Files with a type-directory or raw-blob root are refused and
left untouched. Files created through `airdb_open` are catalog rooted and keep
opening.

The C snippet is not compiled by the test suite. The C ABI smoke test
(`tests/cApiSmoke.c`) covers the same calls.
