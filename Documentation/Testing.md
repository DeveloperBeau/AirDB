# Testing

Run both commands from the repository root, on Zig 0.17.1:

```
zig build test --summary all
zig fmt --check src/ bench/ tests/ build.zig build.zig.zon
```

Both must pass.

`zig build test` currently runs the library tests, the integration tests, the architecture tests and the C ABI smoke test. The format check includes `tests/`.

The bench target is optional for a pull request. Run it when the change alters bench behaviour.

Tests write only under a temporary directory.

A test that needs a row whose physical slot differs from its object key relocates it with `RelocationFixtureTests.relocateAndPoison` in `src/storage/relocationFixtureTests.zig`. `relocateRow` leaves a readable copy in the slot it abandons, so a read through the wrong index would pass by coincidence. The helper overwrites every property cell and the version cell of that slot with a poison value. Expected values in such a test are written by hand.

See [standards.md](../standards.md) for the full testing rules.
