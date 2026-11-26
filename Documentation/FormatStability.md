# Format stability

AirDB is pre-1.0. `build.zig.zon` reports version 0.0.0. There is no tagged release.

The on-disk format is not stable between commits. There is no migration support.

A layout change must be called out in the pull request and in [docs/format.md](../docs/format.md).

The current magic is `airdb_0004`. A file written with an older magic refuses to open with `error.BadMagic`.

See [docs/format.md](../docs/format.md) for the layout.
