# Zest — Testing

Four layers, all runnable without Xcode. `just test` runs the first and
third; CI runs everything except the benchmarks.

| Layer                | Recipe             | What it exercises                                   | Needs an index |
| -------------------- | ------------------ | --------------------------------------------------- | -------------- |
| Zig unit tests       | `just test`        | Engine, index format, daemon logic, C ABI marshaling | No             |
| Daemon integration   | `just test-daemon` | Live FSEvents, rebuild scheduling, failure recovery  | No (makes its own) |
| Swift unit + UI      | `just test`, `just test-ui` | View models, FFI wrapper, the real window in-process | Yes (skips otherwise) |
| Benchmarks           | `just bench-*`     | Engine and UI latency; numbers, not pass/fail        | `bench-capi`, `bench-app`: yes |

## Zig unit tests

Tests live next to the code they cover (`test "..."` blocks). `src/test_root.zig`
imports every module that has them, so `zig build test` runs the whole set in one
binary: `core/` (types, file_types, casefold, filters, humanize, cli, paths),
`config/`, `index/` (format, bulk_scan, bitmap, reader, subtree, search, builder,
incremental, startup, schedule, service, access, progress), `query_main.zig`, and
`capi/zest_core.zig`.

Adding a module with tests means adding one `_ = @import(...)` line to
`test_root.zig`, or its tests never run.

`zig build test` installs a **Debug** `libzest-core.a`. The `test` recipe rebuilds
it in ReleaseFast before `swift test`, and you must do the same after running
`zig build test` by hand (see CLAUDE.md).

## Daemon integration (`just test-daemon`)

`scripts/test-daemon.mjs` (Node) builds `zest-indexer` and `zest-query`, creates a
throwaway `$HOME` under the system temp dir, and drives the real daemon binary
against it. It never touches launchd, the user's index, or preferences. Checks:

1. Initial scan publishes `index.zst` and a `progress-daemon.json` with mode 0600,
   `phase: published`, and `written == total`.
2. Writes under excluded directories and the daemon's own output do not trigger a
   rebuild.
3. Create, rename, delete, and an explicit `reindex.request` are reflected in
   `zest-query` output. The change batch must rebuild **incrementally** (the log
   says so) and a renamed directory must be rescanned under its new name.
4. A failed rebuild retries without another event and keeps the last good index.
5. Overlapping manual scans and the daemon coexist, repeated three times.

It is the only test needing Node. Porting it to Zig (`std.process.Child`) is a
reasonable future step if that dependency becomes a nuisance.

## Swift tests

`Sources/ZestTests` is one XCTest target run by `swift test`. Two groups:

**Pure unit tests** (no index, no window): sorting, filter parsing, breadcrumb
layout math, preview routing and state reduction, tree-sitter highlighting,
persisted user state, indexer process and menu state machines, launch-option
parsing, release-installation detection, theme tokens.

**Integration tests against a real index**:

- `ZestCoreTests` — the FFI wrapper: open, query, cancellation, file identity for
  hot reload, histogram and extension breakdown.
- `UITests` — the headless UI layer described below.

### Index resolution and skipping

Both integration groups resolve the index the same way (`ZestCoreTests.swift`):

- `ZEST_TEST_INDEX_PATH` (+ `ZEST_TEST_INDEX_SCOPE`) when set. If the variable is
  set but the file is missing or unreadable, the test **fails** — CI must never
  silently skip.
- Otherwise `~/Library/Application Support/zest/index.zst`. If that is absent the
  tests **skip** with a hint to run `just index`.

CI builds a small deterministic tree and indexes it with
`.github/scripts/build-test-fixture.sh`, which exports the two variables. Locally:

```sh
eval "$(bash .github/scripts/build-test-fixture.sh)"
just test-ui
```

### Headless UI tests (`just test-ui`)

There is no Xcode project, so XCUITest is not an option, and out-of-process
Accessibility automation needs a TCC grant CI cannot give. Instead the tests run
the real UI **in-process**:

- `UIHarness` builds `RootViewController` with an `AppCoordinator` in an
  off-screen `NSWindow` (same trick as `Zest --snapshot` and `Zest --bench`),
  installs the real main menu, and pumps the run loop until the coordinator's
  `isLoading` clears.
- Views are located by accessibility identifier. The identifiers live in
  `Sources/Zest/Design/A11y.swift` and are set on the search field, browser table,
  sidebar and its category rows, breadcrumb, scope chips, status bar labels,
  preview overlay, and toolbar buttons. Icon-only controls also get labels, so
  VoiceOver benefits for free.
- **Keyboard is real.** Typing, Escape, Delete, and arrows are synthesized
  `NSEvent`s sent through `window.sendEvent`, so they pass through the field
  editor, `controlTextDidChange`, the search debounce, and `commitSearch`. ⌘
  shortcuts go to `NSApp.mainMenu.performKeyEquivalent`, so ⌘↑ runs the same
  menu action a user triggers.
- **Mouse is simulated.** A window that never became key drops synthesized
  mouse-downs, so the harness hit-tests the view hierarchy and calls
  `mouseDown(with:)` on the target. Double-click on the table invokes its
  `doubleAction` after selecting the row.

Assertions are against coordinator state (path, scope, filter, results) and what
the views show (cell text, status bar text). No pixel comparison.

Not reachable this way: native double-click tracking, drag and drop, context
menus, Quick Look, and anything requiring a key window or an active app.

Adding a UI test: give the control an identifier in `A11y`, find it with
`harness.find(...)`, act, `harness.settle()`, assert.

## Benchmarks

Numbers, not gates. Medians over seven iterations; keep the tables in
`docs/BENCHMARKS.md` current when engine or UI performance changes.

- `just bench-search` — engine against a synthetic million-entry corpus. No index.
- `just bench-capi` — the C ABI against the real index. Prints result counts;
  engine changes must keep those counts stable.
- `just bench-app` — `Zest --bench`: the real UI off-screen, per-step query
  latency (mutation → fresh rows on main) and forced render time. `--json` for
  scripting, `--iterations N` to change the sample count.

## CI

`.github/workflows/ci.yml`: build the fixture, `just test`, `just test-daemon`,
`just app-package`. `macos-pkg.yml` repeats the test steps before signing.
Benchmarks do not run in CI.
