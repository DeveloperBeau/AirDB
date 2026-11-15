# Standards

These are the engineering standards for AirDB. They describe the repo as it is today.

## Naming

Zig code follows the Swift API Design Guidelines and Swift casing.

- Types are UpperCamelCase.
- Functions, methods, fields, variables, arguments and enum variants are lowerCamelCase.
- An acronym is one case unit. An example is a name like `objectKey`.
- Names describe the role.
- Boolean names read as assertions.
- Capability protocols or traits end in -ing or -able.
- Each public item has a one sentence doc comment.
- The public surface stays small.
- One public type lives in each file, and the file has that type's name.

There is no separate casing lint in this repo today. The formatter is `zig fmt`. Forced exceptions (C ABI, build files, OS symbols) go in the Forced forms section with a reason.

## Architecture

Files sit in six rings, inner to outer:

1. Entities
2. Domain
3. Infrastructure
4. Shared UI
5. Features
6. Composition

A file depends only inward. Same-ring imports are allowed, except in Infrastructure. There a sideways import of a different file is banned unless the pair is allowlisted. Shared UI and Features have no files today. The numbers stay so the table can grow later.

`database.zig` is Domain. It is the engine state aggregate, not the wiring root. Composition is `src/airdb.zig` and `src/cApi.zig`.

The ring table and the allowlist live in `tests/architecture/ringTable.zig`. That file is the source of truth. This document does not copy the file list or the allowlist.

There are 15 allowlisted file pairs today, pinned by `allowedImportCap = 15`. The list can only shrink. Lower the cap when an entry is removed. Do not raise the cap without explicit review in the pull request.

The architecture test is part of `zig build test`. It fails in these cases:

- A production file is missing from the table.
- An import points outward or sideways without an allowlist entry.
- An allowlist entry is stale or duplicated.
- The allowlist length does not equal the cap.

There is no hidden global state. Required dependencies are init arguments, with no default collaborators. Time, clock, random, network, file system, secrets and storage reach production code only through protocols or traits. Tests use doubles and do not call a real external service.

There is one recorded exception. The architecture test may read `src/` from disk, because checking the real tree is the purpose of that gate. The scanner logic is still tested with in-memory fixtures.

No new third-party package dependency lands without approval in the pull request. This repo has no package dependencies today.

See `Documentation/Architecture/README.md` for the short ring write-up. See `docs/architecture.md` for the engine description (commit protocol, MVCC, mapping, compaction). The two views are different. `docs/architecture.md` groups files by engine layer. The ring table groups files by dependency ring.

## Testing and checks

From the repository root, on Zig 0.16.0:

```
zig build test --summary all
zig fmt --check src/ bench/ tests/ build.zig build.zig.zon
```

Both must pass. Tests are not skipped, disabled or flaky. The bench target is not part of the pull request gate unless the change alters bench behaviour.

The rules:

- Tests assert behaviour a caller can observe, not hidden internals.
- A new public API has a success test and a failure test.
- A bug fix ships with a regression test that fails without the fix.
- Coverage is a floor. A test that cannot fail proves nothing.
- Every feature, seam and complete data flow has a success case, a failure case and a fuzz case.
- Fuzz tests check both directions. Bad input is refused and valid input is accepted.
- Fuzz tests are seeded. A passing run must not print the seed, because the Zig 0.16 test runner treats non-empty stderr on a passing test step as a failed command. Print the seed only on failure.
- When a pull request changes module code under test, mutation testing applies. Break that code on purpose, name the test expected to fail, confirm it fails, restore the code, and record the result in the pull request. The branch is current with `main` before the run. Any surviving mutant is killed by a new test or explained.
- Values that cross a module boundary have an end-to-end test checked against a hand-written expected result. A test does not treat a value it produced from the code under test as the expected result.
- Every wait is bounded. A hang fails with a name.
- Test names say what they prove.
- Every module has its own tests and builds and tests alone. Tests cover success, misuse and adversarial cases where they apply (races, teardown, run exactly once, bounded memory).
- Crash safety: the commit path is a two-slot atomic protocol behind a full durability barrier (`F_FULLFSYNC` on Apple hardware). Tests inject flush failures at exact commit steps. After each injected failure the previous committed version opens and reads back the hand-written expected records.
- Parsers for the database file, sidecar, headers, slots, catalogs and indexes have success, failure and fuzz tests. Corrupt or truncated input is rejected cleanly and does not panic in Debug or ReleaseSafe.
- Readers never see partial state.
- Secondary-index invariants are checked in both directions.
- Link delete rules have failure cases.
- The C ABI smoke test stays in the gate.
- Tests write only under a temporary directory.
- A published Zig or C symbol is not removed or changed in behaviour without a documented breaking change.
- The on-disk format is not yet stable. A layout change is called out in the pull request and in `docs/format.md`.

See `Documentation/Testing.md` for the gate commands.

## Pull requests

One pull request should be reviewable in one sitting. The description says:

- What changed.
- Which of the rules above apply.
- How each rule is met.
- The real local output of the two gate commands.

When mutation testing applies, the description includes the mutation table. When the on-disk layout changes, the description says so and `docs/format.md` is updated. When the architecture allowlist cap would rise, the description calls that out. It is never a silent change. Do not skip, disable or leave flaky tests.

## Forced forms

These names break the casing rules for a real reason.

- `build.zig` and `build.zig.zon` are the Zig build file names.
- `std` and `builtin` are the compiler-provided module names.
- The C ABI in `include/airdb.h` and `src/cApi.zig` uses C identifiers such as `AirdbDatabase` and `airdb_open`. That is the C calling convention the header exposes.
- OS symbols such as `F_FULLFSYNC` keep the names the platform defines.
