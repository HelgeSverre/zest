# Index Reliability and CI Design

Zest must never replace a known-good index with output known to be incomplete, must observe filesystem changes that occur during daemon startup, and must exercise its Zig/Swift boundary in CI without relying on developer state.

## Scope

This change covers three related reliability gaps:

- scan-shard and scanner-internal failures can currently publish a partial index;
- the initial full scan completes before FSEvents starts, leaving an event-loss window;
- the repository has no automated macOS build and test workflow.

It does not add incremental indexing, persist FSEvent IDs, change intentional filesystem exclusions, or turn permission-denied directories into fatal errors.

## Scan publication is fail-closed

The scanner distinguishes intentional omissions from internal data loss.

- Existing exclusion rules and directories that cannot be opened because the process lacks access remain permitted omissions. The index covers what the process can read.
- Queue allocation, TSV escaping, shard writes, shard flushes, malformed shard records, and missing or unreadable shard files are internal failures. They abort the rebuild.
- The builder compares the number of successfully written scan records with the number parsed from all shards. Any mismatch aborts the rebuild, including partial loss.
- `runFullScan` publishes only after all validation succeeds. On failure, the existing `index.zst` remains unchanged and temporary shards are cleaned up.

Unexpected `getattrlistbulk` and malformed kernel-record conditions are reported as scanner failures rather than silently ending a directory. Expected access failures remain non-fatal and should be diagnosable in daemon output.

## FSEvents starts before the initial scan

The default daemon path creates, schedules, and starts its FSEvents stream before running the initial full scan. Filesystem events that arrive while the scan is running remain queued on the run loop. After the scan, the normal watch loop processes them and schedules another rebuild when necessary.

Startup ordering is:

1. Resolve the watched root and application-support exclusion.
2. Create and start the FSEvents stream.
3. Run the initial full scan and atomically publish it.
4. Enter the existing coalescing watch loop.

If watcher creation or start fails, daemon startup fails instead of claiming that watching is active. `--full-scan` remains a one-shot scan and does not create a watcher.

This design deliberately keeps the startup scan. Index mtime cannot prove that no files changed while the daemon was stopped. Persisting and replaying an FSEvent ID is a possible later optimization, not part of this change.

## CI builds a real temporary index

A GitHub Actions workflow runs on pull requests and pushes to `main` using a macOS runner. It grants read-only repository permissions, cancels superseded runs for the same ref, installs Zig 0.16.0 and `just`, and executes the repository's unified test command.

Before `just test`, the workflow:

1. Creates a temporary home and a small fixture tree containing representative code, image, document, and nested files.
2. Builds `zest-indexer` and scans the fixture tree with the temporary home, producing a real `index.zst` outside the repository.
3. Exposes the generated index path and fixture scope through test-only environment variables.

`ZestCoreTests` uses those variables when present and otherwise retains the current optional developer-local integration behavior. CI therefore exercises index opening, FFI queries, histograms, and extension breakdowns without committing a binary fixture or reading or overwriting user data.

Third-party GitHub Actions are pinned to immutable commit SHAs. The workflow uses `actions/checkout` for repository checkout; tool setup must install the exact Zig version declared in the README.

## Testing

Zig tests cover:

- a non-empty scan with any parsed-count mismatch is rejected;
- an internal scan write/queue/flush failure is rejected;
- expected access omissions remain distinguishable from fatal scanner failures;
- daemon startup invokes watcher start before the initial scan and does not enter the watch loop when either step fails.

Swift integration tests cover:

- opening the generated fixture index;
- querying the configured fixture scope;
- category histogram and extension breakdown results from known fixture files.

Repository verification runs `just test`, a Swift build, workflow syntax checks, formatting checks for changed sources, and `git diff --check`.

## Success criteria

- No known partial scan can replace the current index.
- A change made after watcher start but during the initial scan is observed after the scan.
- Watcher startup failure terminates daemon startup with an error.
- Pull requests and pushes to `main` run both Zig and Swift tests on macOS.
- CI's FFI integration checks use a generated fixture and do not depend on a runner's home-directory contents.
