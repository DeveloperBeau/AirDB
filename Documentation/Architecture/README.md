# Architecture

This page is a short write-up of the dependency rings. The full rules are in [standards.md](../../standards.md).

## Rings

Every production file under `src/` sits in one of six rings, inner to outer:

1. Entities
2. Domain
3. Infrastructure
4. Shared UI
5. Features
6. Composition

A file depends only inward. It may import from a lower ring. Same-ring imports are allowed, with one exception. In Infrastructure, a sideways import of a different file is banned unless the pair is allowlisted.

Shared UI and Features have no files today. The numbers stay so the table can grow later.

`database.zig` is Domain. It is the engine state aggregate, not the wiring root. Composition is `src/airdb.zig` and `src/cApi.zig`.

## Architecture test

The architecture test runs as part of `zig build test`. It fails when:

- A production file is missing from the table.
- An import points outward or sideways without an allowlist entry.
- An allowlist entry is stale or duplicated.
- The allowlist length does not equal the cap.

## Allowlist

There are 15 allowlisted file pairs today. The cap is pinned at 15 by `allowedImportCap`. The list can only shrink. Lower the cap when an entry is removed. Do not raise it without explicit review in the pull request.

The ring table and the allowlist live in `tests/architecture/ringTable.zig`. That file is the source of truth. This page does not copy them.

## Two views of the code

[docs/architecture.md](../../docs/architecture.md) describes the engine by functional layer: platform, store, transactions, trees, objects, operations and edge. That layer map is not the dependency ring table. Both are current.

Use `docs/architecture.md` for the commit protocol, MVCC, mapping and compaction.
