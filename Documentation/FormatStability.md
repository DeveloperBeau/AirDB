# Format stability

AirDB is pre-1.0. `build.zig.zon` reports version 0.1.0. There is no tagged release.

The on-disk format is not stable between commits.

A layout change must be called out in the pull request and in [docs/format.md](../docs/format.md).

The current magic is `airdb_0001`. It is the only format. The version does not count up before release, and a file without that magic fails with `error.BadMagic`.

See [docs/format.md](../docs/format.md) for the layout.
