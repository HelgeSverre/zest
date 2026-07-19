# Index Reliability and CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent partial index publication, start filesystem observation before the initial scan, and run hermetic Zig/Swift integration tests in macOS CI.

**Architecture:** The bulk scanner returns explicit completeness metadata and the builder rejects every known-loss condition before atomic publication. A small pure startup sequencer makes watcher-before-scan ordering testable without linking FSEvents into unit tests. GitHub Actions generates a real index from a temporary fixture tree and points the existing Swift integration suite at it through test-only environment variables.

**Tech Stack:** Zig 0.16.0, Swift 5.9/XCTest, macOS 14+, FSEvents/CoreFoundation, GitHub Actions.

## Global Constraints

- Keep the macOS deployment target at 14.
- Do not add runtime dependencies or commit a binary index fixture.
- Preserve `--full-scan` as a one-shot operation without FSEvents.
- Preserve intentional exclusions and access-denied directory omissions.
- Do not stage or modify `reddit-scrutiny.json`.
- Write each behavioral change test-first and observe the focused test fail before implementation.

---

### Task 1: Reject incomplete scan output

**Files:**
- Modify: `src/index/builder.zig`
- Modify: `src/index/bulk_scan.zig`
- Test: embedded tests in `src/index/builder.zig`

**Interfaces:**
- Produces: `bulk_scan.ScanResult { paths, entry_count, complete }`.
- Produces: strict `validateParsedCount(walked, parsed)` and `validateScanComplete(complete)` guards.
- Consumes: existing worker-local entry counts and shared atomic failure state.

- [ ] **Step 1: Make the current partial-count test require rejection**

Change the existing validation test to require an error for `validateParsedCount(17, 12)`, and add a test requiring `validateScanComplete(false)` to fail while `true` passes.

```zig
try std.testing.expectError(error.ScanParseEntryCountMismatch, validateParsedCount(17, 12));
try validateScanComplete(true);
try std.testing.expectError(error.ScanIncomplete, validateScanComplete(false));
```

- [ ] **Step 2: Run the Zig suite and verify RED**

Run: `zig build test`

Expected: FAIL because partial loss is currently accepted and `validateScanComplete` does not exist.

- [ ] **Step 3: Return completeness metadata and enforce it**

Replace the out-parameter/count-only scanner result with:

```zig
pub const ScanResult = struct {
    paths: []const []u8,
    entry_count: u64,
    complete: bool,
};
```

Return `complete = !shared.scan_failed.load(.monotonic)`. Set `scan_failed` for queue, escape, write, flush, unexpected `getattrlistbulk`, and malformed kernel-record failures. Keep access-denied, vanished-directory, and not-a-directory opens as allowed concurrent/access omissions.

In `buildIndex`, clean up `result.paths`, reject `!result.complete`, parse every shard, and require exact equality between `result.entry_count` and `parsed` before returning index bytes.

- [ ] **Step 4: Make malformed TSV records fatal**

Update `parseScanReader` so nonblank records must contain exactly six fields and valid numeric/enum values. Return `error.MalformedScanRecord` instead of skipping or substituting zero. Add focused tests for a short record and invalid numeric metadata before changing the parser, verify RED, then implement strict parsing.

- [ ] **Step 5: Verify Task 1**

Run: `zig fmt src/index/builder.zig src/index/bulk_scan.zig && zig build test`

Expected: all Zig tests pass; partial counts and malformed records fail closed.

- [ ] **Step 6: Commit Task 1**

```bash
git add src/index/builder.zig src/index/bulk_scan.zig
git commit -m "fix: reject incomplete index scans"
```

### Task 2: Start FSEvents before the initial scan

**Files:**
- Create: `src/index/startup.zig`
- Modify: `src/index/daemon.zig`
- Modify: `src/index/fsevents.zig`
- Modify: `src/test_root.zig`
- Test: embedded tests in `src/index/startup.zig`

**Interfaces:**
- Produces: `startup.run(ops)` calling `startWatcher`, `initialScan`, then `watchLoop` with fail-fast propagation.
- Produces: `FSEventsWatcher.start() !void`, returning `error.FSEventStreamStartFailed` when the C API returns false.
- Consumes: daemon-specific operations implementing the three startup methods.

- [ ] **Step 1: Add failing startup-order tests**

Create `startup.zig` with tests backed by a recorder operation type. Require the recorded order to equal `"watcher,scan,loop"`; require scan not to run after watcher failure and loop not to run after scan failure. Import the new module from `test_root.zig` before adding `startup.run`.

- [ ] **Step 2: Run the Zig suite and verify RED**

Run: `zig build test`

Expected: FAIL because `startup.run` is undefined.

- [ ] **Step 3: Implement the pure sequencer**

```zig
pub fn run(ops: anytype) !void {
    try ops.startWatcher();
    try ops.initialScan();
    try ops.watchLoop();
}
```

Run `zig build test`; expect the startup tests to pass.

- [ ] **Step 4: Refactor daemon ownership and watcher start errors**

Move watcher creation, exclusion setup, start, stop, and deinit into the default daemon path before `runFullScan`. Leave `runWatchLoop` responsible only for servicing/coalescing events. Route those operations through `startup.run`.

Change `FSEventsWatcher.start` to return an error when `FSEventStreamStart` returns false:

```zig
if (c.FSEventStreamStart(self.stream) == 0) {
    return error.FSEventStreamStartFailed;
}
```

- [ ] **Step 5: Verify Task 2**

Run: `zig fmt src/index/startup.zig src/index/daemon.zig src/index/fsevents.zig src/test_root.zig && zig build test && zig build indexer`

Expected: all tests pass and the daemon executable links.

- [ ] **Step 6: Commit Task 2**

```bash
git add src/index/startup.zig src/index/daemon.zig src/index/fsevents.zig src/test_root.zig
git commit -m "fix: watch filesystem during initial scan"
```

### Task 3: Add generated-fixture macOS CI

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `Sources/ZestTests/ZestCoreTests.swift`

**Interfaces:**
- Consumes: `ZEST_TEST_INDEX_PATH` and `ZEST_TEST_INDEX_SCOPE` in integration tests.
- Produces: CI fixture index at the explicit path generated under `$RUNNER_TEMP`.

- [ ] **Step 1: Make configured integration fixtures mandatory**

Add test-only location resolution so the environment variables override the developer-local index and home scope. When `ZEST_TEST_INDEX_PATH` is set, a missing or unreadable index fails with `XCTUnwrap`; without it, retain existing `XCTSkip` behavior. Update every real-index test to use the resolved scope.

- [ ] **Step 2: Verify Swift tests locally**

Run: `zig build core -Doptimize=ReleaseFast && swift test --filter ZestCoreTests`

Expected: existing developer-local behavior passes; an invocation with `ZEST_TEST_INDEX_PATH=/missing` fails, proving configured CI fixtures cannot silently skip.

- [ ] **Step 3: Add the workflow**

Create `.github/workflows/ci.yml` with pull-request and `main` push triggers, `contents: read`, ref-scoped concurrency, `macos-14`, immutable action SHAs, Zig 0.16.0, and a generated fixture.

The fixture step creates nested code, image, document, and text files; runs `zest-indexer --full-scan` with a temporary `HOME`; exports the resulting index path and fixture scope through `$GITHUB_ENV`; and then runs `just test`.

- [ ] **Step 4: Validate workflow and fixture behavior locally**

Reproduce the workflow fixture in a `mktemp -d` directory, run the indexer, then execute `ZEST_TEST_INDEX_PATH=... ZEST_TEST_INDEX_SCOPE=... just test`. Parse the YAML with Ruby and run `git diff --check`.

Expected: generated-fixture integration tests and the full suite pass; YAML parses.

- [ ] **Step 5: Commit Task 3**

```bash
git add .github/workflows/ci.yml Sources/ZestTests/ZestCoreTests.swift
git commit -m "ci: test against generated index fixture"
```

### Task 4: Final verification and review

**Files:**
- Modify only if verification exposes a scoped defect.

**Interfaces:**
- Consumes all earlier task outputs.
- Produces a reviewed, buildable branch with no unrelated files staged.

- [ ] **Step 1: Run full verification**

Run: `just test && swift build && swift-format lint --recursive Sources && git diff --check`

Expected: exit code zero from every command.

- [ ] **Step 2: Review the complete diff**

Use the code-review workflow. Check failure cleanup/ownership, atomic publication ordering, watcher lifetime, test fixture isolation, workflow permissions, and immutable action pins.

- [ ] **Step 3: Confirm repository state**

Run: `git status --short --branch && git log -5 --oneline`

Expected: implementation commits are present; only the pre-existing untracked `reddit-scrutiny.json` remains; no implementation changes are uncommitted.
