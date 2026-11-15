# Testing

Run both commands from the repository root, on Zig 0.16.0:

```
zig build test --summary all
zig fmt --check src/ bench/ tests/ build.zig build.zig.zon
```

Both must pass.

`zig build test` currently runs the library tests, the integration tests, the architecture tests and the C ABI smoke test. The format check includes `tests/`.

The bench target is optional for a pull request. Run it when the change alters bench behaviour.

Tests write only under a temporary directory.

See [standards.md](../standards.md) for the full testing rules.
