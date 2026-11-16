# Documentation

This is the engineering index for AirDB.

`docs/` remains the product documentation of the running system. `Documentation/` holds this index and the short pages listed here. The repo root has `standards.md`, which sets the engineering standards.

## Engineering pages

- [Architecture](Architecture/README.md): rings, inward-only dependencies and the architecture test
- [Testing](Testing.md): the gate commands
- [Format stability](FormatStability.md): the on-disk format is not stable yet
- [Learnings](Learnings/README.md): traps, findings and the rules they produced

## Product pages

- [Architecture](../docs/architecture.md): engine layers, commit protocol, MVCC, compaction
- [Features](../docs/features.md): the full feature surface
- [Format](../docs/format.md): on-disk layout
- [Benchmarks](../docs/benchmarks.md): how to run the suite
- [Limits](../docs/limits.md): threading contract, single-writer model, format caveats

## Standards

See [standards.md](../standards.md).
