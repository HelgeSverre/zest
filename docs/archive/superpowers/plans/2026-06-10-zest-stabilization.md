# Zest Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Zest fast and correct: async off-main queries, daemon rebuild-loop fix, index hot-reload, UX fixes (double-click, nav feedback, lazy rows), engine fast paths, corruption hardening — and delete the dead legacy Zig GUI.

**Architecture:** Swift/AppKit app (`Sources/Zest/`) + Zig engine via C ABI (`src/capi/zest_core.zig`) + Zig indexer daemon. UI state (pins/colors) moves to a Swift `UserState`; the legacy pure-Zig GUI chain is deleted. All engine changes are guarded by `zig build test` and `just bench-capi` (baseline table in `docs/ROADMAP.md`).

**Tech Stack:** Zig 0.16.0, Swift 5.9 / AppKit (macOS 14), SwiftPM + zig build via `just`.

**Context for every task:** `docs/ROADMAP.md` has the diagnosis + benchmark baseline. Conventions: 4-space Swift (swift-format config in repo), Zig tests embedded in source files rooted at `src/test_root.zig`, Swift tests in `Sources/ZestTests`. The Swift app links whatever `zig-out/lib/libzest-core.a` exists — keep it ReleaseFast (`zig build core -Doptimize=ReleaseFast`). The daemon is NOT installed via launchd on this machine (verified); the user runs `just index` manually. Do not install the daemon.

**Decisions locked (from user):** pins/saved-filters/folder-colors persist Swift-side (same JSON files); scope = Phase A5–A7 + legacy deletion + Phase B + Phase C; incremental commits; rebuild daemon but do not install.

---

### Task 0: Commit the diagnosis round (already-working tree changes)

The tree contains finished, tested work from the diagnosis session. Commit it as four logical chunks before anything else.

**Files:** all currently modified/untracked (see `git status`).

- [ ] **Step 1: Verify green before committing**

Run: `zig build test && zig build core -Doptimize=ReleaseFast && swift build && swift test`
Expected: all pass (Zig tests exit 0; `Build complete!`; 30 Swift tests pass).

- [ ] **Step 2: Commit the engine fix**

```bash
git add src/index/search.zig
git commit -m "perf(search): O(1) duplicate check in text-search hot loop

Entry indices from findEntryForBlobPos are non-decreasing in blob
position, so a duplicate can only equal the last seen index. Replaces
the O(results) scan that made short queries quadratic: 'i' over a
5.56M-entry index drops 4458ms -> 17.8ms (ReleaseFast, just bench-capi).
Result counts are byte-identical across the bench matrix."
```

- [ ] **Step 3: Commit the Swift query-pipeline fixes**

```bash
git add Sources/Zest/App/AppCoordinator.swift Sources/Zest/Shell/SearchField.swift Sources/Zest/Shell/FilterBarView.swift
git commit -m "perf(ui): one query per change, 2k result cap, single-notify search commit

- AppCoordinator caches the result set per change-tick so browser.reload()
  and the filter-bar count share one engine query instead of two
- commitSearch() wraps scope+text mutation in one onChange (was two,
  i.e. 4 query passes per keystroke)
- maxResults 100_000 -> 2_000; filter bar renders '2,000+' when capped"
```

- [ ] **Step 4: Commit build + benchmark infrastructure**

```bash
git add justfile benchmarks/
git commit -m "build: ship ReleaseFast engine; add C-ABI benchmark harness

just build/test now rebuild libzest-core.a ReleaseFast last (Package.swift
links zig-out/lib; a Debug engine is ~19x slower — 82.8s vs 4.5s for a
1-char query). just bench-capi runs benchmarks/bench_capi.zig against the
real index: keystroke ladder, browse listing, histogram, ext breakdown."
```

- [ ] **Step 5: Commit docs**

```bash
git add CLAUDE.md docs/
git commit -m "docs: add ROADMAP (diagnosis + phased plan), archive stale docs, rewrite CLAUDE.md

CLAUDE.md described the retired pure-Zig UI; now documents the Swift+Zig
hybrid, the ReleaseFast rule, and the bench workflow. TODO/PLAN/phase-0
plan/unified-query spec move to docs/archive/ (completed or superseded)."
```

---

### Task 1: Swift UserState — pins + folder colors from JSON

Replaces hardcoded sidebar pins; reads the same `pins.json` / `folder_colors.json` the old Zig app wrote (formats unchanged — see fixtures below).

**Files:**
- Create: `Sources/Zest/Core/UserState.swift`
- Test: `Sources/ZestTests/UserStateTests.swift`
- Modify: `Sources/Zest/App/AppCoordinator.swift` (own a `UserState`)
- Modify: `Sources/Zest/Sidebar/SidebarViewController.swift` (`pins()` reads from it)

On-disk formats (already in `~/Library/Application Support/zest/`):

```json
// pins.json
[
  {"name": "Home", "path": "/Users/helge", "is_default": true},
  {"name": "Desktop", "path": "/Users/helge/Desktop", "is_default": true}
]
// folder_colors.json
{"version": 1, "folders": {"/Users/helge/code/agent": {"red": 214, "green": 180, "blue": 89, "alpha": 255}}}
```

- [ ] **Step 1: Write the failing test**

```swift
// Sources/ZestTests/UserStateTests.swift
import Foundation
import Testing

@testable import Zest

@Suite struct UserStateTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zest-userstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadsPinsFromJson() throws {
        let dir = try tempDir()
        let json = #"[{"name": "Code", "path": "/Users/x/code", "is_default": false}]"#
        try json.write(to: dir.appendingPathComponent("pins.json"), atomically: true, encoding: .utf8)
        let state = UserState(directory: dir)
        #expect(state.pins == [UserState.Pin(name: "Code", path: "/Users/x/code", isDefault: false)])
    }

    @Test func missingPinsFileYieldsDefaults() throws {
        let state = UserState(directory: try tempDir())
        #expect(state.pins.map(\.name) == ["Home", "Desktop", "Documents", "Downloads"])
    }

    @Test func addAndRemovePinRoundTripsThroughDisk() throws {
        let dir = try tempDir()
        let state = UserState(directory: dir)
        state.addPin(name: "Proj", path: "/tmp/proj")
        let reloaded = UserState(directory: dir)
        #expect(reloaded.pins.contains(UserState.Pin(name: "Proj", path: "/tmp/proj", isDefault: false)))
        reloaded.removePin(path: "/tmp/proj")
        let again = UserState(directory: dir)
        #expect(!again.pins.contains(where: { $0.path == "/tmp/proj" }))
    }

    @Test func loadsFolderColors() throws {
        let dir = try tempDir()
        let json = #"{"version": 1, "folders": {"/a/b": {"red": 214, "green": 180, "blue": 89, "alpha": 255}}}"#
        try json.write(to: dir.appendingPathComponent("folder_colors.json"), atomically: true, encoding: .utf8)
        let state = UserState(directory: dir)
        let c = try #require(state.folderColor(forPath: "/a/b"))
        #expect(abs(c.redComponent - 214.0 / 255.0) < 0.001)
    }

    @Test func corruptJsonFallsBackToDefaults() throws {
        let dir = try tempDir()
        try "not json {".write(to: dir.appendingPathComponent("pins.json"), atomically: true, encoding: .utf8)
        let state = UserState(directory: dir)
        #expect(state.pins.map(\.name) == ["Home", "Desktop", "Documents", "Downloads"])
    }
}
```

(Existing Swift tests use the `Testing` framework if present — check `Sources/ZestTests/FilterTests.swift` first; if they use XCTest, write XCTest style instead, same assertions.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UserStateTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'UserState' in scope`.

- [ ] **Step 3: Implement UserState**

```swift
// Sources/Zest/Core/UserState.swift
import AppKit
import Foundation

/// Pins + folder colors persisted as JSON in the zest app-support directory.
/// Replaces the legacy Zig `user_state.zig` — the Swift app owns UI state.
/// File formats are unchanged so pins.json / folder_colors.json written by
/// the old app keep working. Loads are forgiving (corrupt/missing files fall
/// back to defaults); saves are atomic.
final class UserState {
    struct Pin: Codable, Equatable {
        let name: String
        let path: String
        var isDefault: Bool

        enum CodingKeys: String, CodingKey {
            case name, path
            case isDefault = "is_default"
        }
    }

    private struct ColorEntry: Codable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    private struct ColorsFile: Codable {
        let version: Int
        let folders: [String: ColorEntry]
    }

    private(set) var pins: [Pin]
    private var colors: [String: NSColor]
    private let pinsURL: URL?
    private let colorsURL: URL?

    /// `directory` is the zest app-support dir; nil (no app support) yields
    /// in-memory defaults that don't persist.
    init(directory: URL?) {
        pinsURL = directory?.appendingPathComponent("pins.json")
        colorsURL = directory?.appendingPathComponent("folder_colors.json")
        pins = Self.loadPins(from: pinsURL) ?? Self.defaultPins()
        colors = Self.loadColors(from: colorsURL)
    }

    func folderColor(forPath path: String) -> NSColor? {
        colors[path]
    }

    func addPin(name: String, path: String) {
        guard !pins.contains(where: { $0.path == path }) else { return }
        pins.append(Pin(name: name, path: path, isDefault: false))
        savePins()
    }

    func removePin(path: String) {
        pins.removeAll { $0.path == path }
        savePins()
    }

    // MARK: - Load / save

    private static func defaultPins() -> [Pin] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func sub(_ n: String) -> String { (home as NSString).appendingPathComponent(n) }
        return [
            Pin(name: "Home", path: home, isDefault: true),
            Pin(name: "Desktop", path: sub("Desktop"), isDefault: true),
            Pin(name: "Documents", path: sub("Documents"), isDefault: true),
            Pin(name: "Downloads", path: sub("Downloads"), isDefault: true),
        ]
    }

    private static func loadPins(from url: URL?) -> [Pin]? {
        guard let url, let data = try? Data(contentsOf: url),
            let parsed = try? JSONDecoder().decode([Pin].self, from: data),
            !parsed.isEmpty
        else { return nil }
        return parsed
    }

    private static func loadColors(from url: URL?) -> [String: NSColor] {
        guard let url, let data = try? Data(contentsOf: url),
            let parsed = try? JSONDecoder().decode(ColorsFile.self, from: data)
        else { return [:] }
        return parsed.folders.mapValues { e in
            NSColor(
                red: CGFloat(e.red) / 255, green: CGFloat(e.green) / 255,
                blue: CGFloat(e.blue) / 255, alpha: CGFloat(e.alpha) / 255)
        }
    }

    private func savePins() {
        guard let pinsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pins) else { return }
        do {
            try data.write(to: pinsURL, options: .atomic)
        } catch {
            NSLog("UserState: failed to save pins: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UserStateTests 2>&1 | tail -5`
Expected: PASS (5 tests). The test target must see `UserState` — `@testable import Zest` works because ZestTests already depends on the Zest target.

- [ ] **Step 5: Own it in AppCoordinator and use it in the sidebar**

In `Sources/Zest/App/AppCoordinator.swift`, add a property and initialize it in `init()` (the app-support URL is already computed there):

```swift
    let userState: UserState

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let zestDir = support?.appendingPathComponent("zest")
        core = zestDir.flatMap { ZestCore(indexPath: $0.appendingPathComponent("index.zst").path) }
        userState = UserState(directory: zestDir)
        currentPath = fm.homeDirectoryForCurrentUser.path
    }
```

Note: the existing init computes `index.zst` via `appendingPathComponent("zest/index.zst")` — refactor to the shared `zestDir` as above (same path).

In `Sources/Zest/Sidebar/SidebarViewController.swift`, replace the hardcoded `pins()` (the `// TODO: load from configuration` block) with:

```swift
    private func pins() -> [Pin] {
        coordinator.userState.pins.map { p in
            Pin(label: p.name, symbol: Self.pinSymbol(for: p), path: p.path)
        }
    }

    private static func pinSymbol(for pin: UserState.Pin) -> String {
        switch pin.name {
        case "Home": "house"
        case "Desktop": "display"
        case "Documents": "doc"
        case "Downloads": "arrow.down.circle"
        default: "folder"
        }
    }
```

(Keep the sidebar's private `Pin` struct; only the data source changes. Match the existing symbol names — check the current hardcoded list and reuse its exact symbols for the four defaults.)

- [ ] **Step 6: Build + full test suite**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: build succeeds, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Zest/Core/UserState.swift Sources/ZestTests/UserStateTests.swift Sources/Zest/App/AppCoordinator.swift Sources/Zest/Sidebar/SidebarViewController.swift
git commit -m "feat(ui): Swift UserState — pins + folder colors from JSON

Sidebar pins come from pins.json (same format the legacy Zig app wrote)
instead of being hardcoded; folder_colors.json is loaded for future row
tinting. Corrupt/missing files fall back to defaults. Replaces the
persistence half of the legacy user_state.zig ahead of its deletion."
```

---

### Task 2: Delete the legacy Zig GUI chain (roadmap D1 + D6)

The Swift app superseded the pure-Zig GUI. Verified dead (import graph): nothing retained imports these. `humanize.zig` and `runtime.zig` STAY (daemon/builder use them).

**Files:**
- Delete: `src/ui/` (all 8 files), `src/main.zig`, `src/app.zig`, `src/core/async_search.zig`, `src/core/dispatch.zig`, `src/core/navigator.zig`, `src/core/user_state.zig`, `src/core/fs_provider.zig`, `src/core/real_fs.zig`, `src/core/fake_fs.zig`, `src/index/session.zig`, `Sample of Zest.txt`
- Modify: `build.zig` (remove the `zest` executable + run step), `src/test_root.zig` (prune imports), `README.md` (remove Zig-UI sections), `docs/ROADMAP.md` (tick D1/D6)

- [ ] **Step 1: Delete the files**

```bash
git rm -r src/ui
git rm src/main.zig src/app.zig
git rm src/core/async_search.zig src/core/dispatch.zig src/core/navigator.zig \
       src/core/user_state.zig src/core/fs_provider.zig src/core/real_fs.zig src/core/fake_fs.zig
git rm src/index/session.zig
git rm "Sample of Zest.txt"
```

- [ ] **Step 2: Remove the `zest` executable and run step from build.zig**

Delete the `// === Binary 1: zest (GUI/CLI app) ===` block (build.zig:16-29) and the `// === Run step ===` block (build.zig:69-77). The `coreservices_frameworks` path setup stays (the indexer needs it). Result: build.zig defines `zest-indexer`, `zest-core` lib, `core`/`indexer` steps, and tests only.

- [ ] **Step 3: Prune test_root.zig**

Remove these four lines from `src/test_root.zig` (the rest stays):

```zig
    _ = @import("core/fake_fs.zig");
    _ = @import("core/navigator.zig");
    _ = @import("core/user_state.zig");
    _ = @import("index/session.zig");
```

- [ ] **Step 4: Verify everything still builds and passes**

Run: `zig build && zig build test && zig build core -Doptimize=ReleaseFast && swift build && swift test 2>&1 | tail -3`
Expected: all pass. If `zig build` errors on a survivor importing a deleted module, the import graph check missed something — fix by inlining or restoring the single needed function, not the whole file.

- [ ] **Step 5: Update README.md**

Remove/replace: the "zest binary" mermaid subgraph (lines ~180-196 describe the Zig UI), the `--benchmark`/`--benchmark-list` section (superseded by `just bench-capi`), the `ui/` entries in Project Structure, and the stale `just dev`/`just bench` references. Point benchmarking at `just bench-capi`. Keep the index/daemon/search documentation (accurate).

- [ ] **Step 6: Tick D1 + D6 in docs/ROADMAP.md and commit**

```bash
git add -A
git commit -m "refactor: delete the legacy Zig GUI chain

The Swift app (Sources/Zest) superseded the pure-Zig AppKit UI. Removes
src/ui/*, main.zig, app.zig, async_search, dispatch, navigator,
user_state (persistence now Swift-side UserState), the FakeFs/RealFs
vtable abstraction, session.zig (inode-poll logic moves to Swift in the
hot-reload task), and a stray committed profiler dump. build.zig no
longer links AppKit; test_root pruned; README updated."
```

---

### Task 3: Stop the daemon rebuild treadmill (roadmap A6)

`onFSEvent` counts the daemon's own writes under `~/Library/Application Support/zest`, so every rebuild schedules the next one. Fix at both layers: `kFSEventStreamCreateFlagIgnoreSelf` on the stream, plus an explicit exclusion-path filter (renames by other processes, e.g. a manually-run `just index`, must not retrigger either).

**Files:**
- Modify: `src/index/fsevents.zig` (flag + `FSEventStreamSetExclusionPaths`)
- Modify: `src/index/daemon.zig` (pass the app-support dir as exclusion; path filter in `onFSEvent`)

- [ ] **Step 1: Add IgnoreSelf + exclusion paths to the watcher**

In `src/index/fsevents.zig`, change `init` to accept exclusion paths and apply both mechanisms:

```zig
    pub fn init(
        self: *FSEventsWatcher,
        allocator: std.mem.Allocator,
        watch_path: []const u8,
        exclude_paths: []const []const u8,
        callback: FSEventCallback,
    ) !void {
```

After `FSEventStreamCreate` succeeds, change the flags line in the create call to:

```zig
            c.kFSEventStreamCreateFlagFileEvents | c.kFSEventStreamCreateFlagNoDefer | c.kFSEventStreamCreateFlagIgnoreSelf,
```

and add, after the create:

```zig
        // The daemon writes scan temps + the index into the app-support dir;
        // without an exclusion, every rebuild emits events that schedule the
        // next rebuild — an endless full-rescan loop (~23s of I/O every 30s).
        // IgnoreSelf covers this process's own writes; the exclusion list also
        // covers other writers (e.g. a manually run `just index`).
        if (exclude_paths.len > 0) {
            var cf_excludes = std.ArrayList(?*const anyopaque).empty;
            defer cf_excludes.deinit(allocator);
            for (exclude_paths) |p| {
                const cf = c.CFStringCreateWithBytes(null, p.ptr, @intCast(p.len), c.kCFStringEncodingUTF8, 0) orelse continue;
                cf_excludes.append(allocator, @ptrCast(cf)) catch {
                    c.CFRelease(@ptrCast(cf));
                    continue;
                };
            }
            if (cf_excludes.items.len > 0) {
                const arr = c.CFArrayCreate(null, @ptrCast(cf_excludes.items.ptr), @intCast(cf_excludes.items.len), &c.kCFTypeArrayCallBacks);
                if (arr) |a| {
                    _ = c.FSEventStreamSetExclusionPaths(self.stream, a);
                    c.CFRelease(@ptrCast(a));
                }
                for (cf_excludes.items) |cf| c.CFRelease(@ptrCast(cf));
            }
        }
```

- [ ] **Step 2: Pass the exclusion dir and filter in the daemon**

In `src/index/daemon.zig`: resolve the app-support dir (the parent of `config.indexPath`) before creating the watcher, pass it to `watcher.init(allocator, root, &.{app_support_dir}, onFSEvent)`, and as belt-and-suspenders filter paths in `onFSEvent`:

```zig
/// Set once in watchLoop before the watcher starts; onFSEvent runs on the
/// same thread's run loop, so a plain optional is fine.
var exclude_prefix: ?[]const u8 = null;

fn onFSEvent(paths: []const []const u8) void {
    var relevant: usize = 0;
    for (paths) |p| {
        if (exclude_prefix) |ex| {
            if (std.mem.startsWith(u8, p, ex)) continue;
        }
        relevant += 1;
    }
    if (relevant == 0) return;
    const total = dirty_count.fetchAdd(relevant, .monotonic) + relevant;
    _ = total; // keep the existing logging line, adjusted to `relevant`
}
```

(Adapt to the existing body — keep its logging; only the counting changes. `exclude_prefix` is the app-support dir, e.g. `/Users/x/Library/Application Support/zest`.)

- [ ] **Step 3: Build + tests**

Run: `zig build test && zig build indexer -Doptimize=ReleaseFast`
Expected: pass. (FSEvents behavior is not unit-testable; the verification is Step 4.)

- [ ] **Step 4: Manual verification (document result in commit)**

Run the watcher briefly: `./zig-out/bin/zest-indexer --full-scan ~ && timeout 100 ./zig-out/bin/zest-indexer` — wait through one 30s window with no file activity. Expected: no "Rebuilding index" line after the initial scan (previously it rebuilt every ~30s forever). Touch a file in `~/tmp` → one rebuild fires, then quiet again. Skip if a ~2min wait is impractical; note it for the user instead. Do NOT `zest-indexer install`.

- [ ] **Step 5: Commit**

```bash
git add src/index/fsevents.zig src/index/daemon.zig
git commit -m "fix(daemon): stop self-triggered rebuild loop

FSEvents watched \$HOME including the daemon's own output dir, so every
rebuild scheduled the next one (~23s full rescan every 30s, forever).
kFSEventStreamCreateFlagIgnoreSelf + FSEventStreamSetExclusionPaths on
the app-support dir + a path-prefix filter in onFSEvent."
```

---

### Task 4: Index hot-reload in Swift + no-index state (roadmap A7 + B6)

The app mmaps once at init; daemon rebuilds are invisible until restart, and `core == nil` (launch before first index) is permanent. Port the legacy `session.zig` inode-poll to Swift.

**Files:**
- Modify: `Sources/Zest/Core/ZestCore.swift` (expose the file identity it was built from)
- Modify: `Sources/Zest/App/AppCoordinator.swift` (poll timer, swap, retry-from-nil)
- Modify: `Sources/Zest/Browser/BrowserViewController.swift` (empty-state copy)

- [ ] **Step 1: Record file identity in ZestCore**

In `ZestCore.init?`, after the successful `fstat`, store identity; add properties:

```swift
    let indexPath: String
    let fileIdentity: FileIdentity

    struct FileIdentity: Equatable {
        let inode: UInt64
        let size: Int64
        let mtime: Int64
    }

    static func currentIdentity(of path: String) -> FileIdentity? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_size > 0 else { return nil }
        return FileIdentity(inode: UInt64(st.st_ino), size: Int64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec))
    }
```

Set `self.indexPath = indexPath` and `self.fileIdentity = FileIdentity(inode: UInt64(st.st_ino), size: Int64(st.st_size), mtime: Int64(st.st_mtimespec.tv_sec))` in init (the `st` from the existing `fstat` call).

- [ ] **Step 2: Poll + swap in AppCoordinator**

`core` becomes `private(set) var core: ZestCore?`. Store the path, add the timer + reload:

```swift
    private var indexPathForReload: String?
    private var reloadTimer: Timer?

    /// Poll the index file every 5s: if the daemon published a new index
    /// (different inode/size/mtime), or we launched before the first index
    /// existed (core == nil), open the new file and swap. Rows are copied at
    /// the FFI boundary, so dropping the old core is safe; ARC unmaps it.
    func startIndexReloadTimer() {
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reloadIndexIfChanged()
        }
    }

    func reloadIndexIfChanged() {
        guard let path = indexPathForReload else { return }
        guard let onDisk = ZestCore.currentIdentity(of: path) else { return }  // no index yet
        if let core, core.fileIdentity == onDisk { return }  // unchanged
        guard let fresh = ZestCore(indexPath: path) else { return }  // mid-rename; retry next tick
        core = fresh
        notifyChange()  // invalidates the results cache + refreshes every observer
    }
```

In `init()`, set `indexPathForReload = zestDir?.appendingPathComponent("index.zst").path` (reuse the same constant as the `core` creation — extract it to one `let indexPath` local). Call `coordinator.startIndexReloadTimer()` from `RootViewController.viewDidLoad()` after the `onChange` wiring.

- [ ] **Step 3: No-index empty state in the browser**

`BrowserViewController.reload()` already toggles an `emptyLabel`. Differentiate the copy:

```swift
        let isEmpty = items.isEmpty
        scrollView.isHidden = isEmpty
        emptyLabel?.isHidden = !isEmpty
        if isEmpty {
            emptyLabel?.stringValue =
                coordinator.core == nil
                ? "No search index yet — run `just index` to build it. Zest will pick it up automatically."
                : (coordinator.isSearchMode ? "No results" : "Empty folder")
        }
```

(Adapt to the actual emptyLabel construction — find it in BrowserViewController; if it's an attributed/styled label, set the text through whatever it already uses.)

- [ ] **Step 4: Build, test, manual verify**

Run: `swift build && swift test 2>&1 | tail -3` — pass.
Manual: `mv` the index aside, launch (`swift run Zest`), see the no-index state; `mv` it back; within 5s the list populates. (Run if practical; otherwise note for the user.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Zest/Core/ZestCore.swift Sources/Zest/App/AppCoordinator.swift Sources/Zest/Browser/BrowserViewController.swift Sources/Zest/Shell/RootViewController.swift
git commit -m "feat(ui): index hot-reload (5s inode poll) + no-index empty state

Ports the legacy session.zig inode-poll to Swift: when the daemon
publishes a new index (or the first one appears after launch), the app
swaps in a fresh ZestCore and refreshes. Stale-index navigation no-ops
shrink accordingly. Distinct empty-state copy for missing index vs no
results vs empty folder."
```

---

### Task 5: Async off-main queries (roadmap A5, includes the C7 race fix)

Queries currently run synchronously on the main thread. Move them to a serial background queue with generation-based staleness, sidebar-style. Prerequisite: kill the lazy-bitmap-init race in the reader (two threads will now call the C API).

**Files:**
- Modify: `src/index/reader.zig` (eager-only bitmaps — no lazy mutation)
- Modify: `Sources/Zest/App/AppCoordinator.swift` (async pipeline)
- Modify: `Sources/Zest/Shell/FilterBarView.swift` (optional loading hint)

- [ ] **Step 1 (C7): Make category bitmaps eager-only**

`IndexReader.init` already builds bitmaps eagerly but `catch null`s failure, and `getCategoryBitmaps` lazily retries — mutating shared state on the query thread. Change `getCategoryBitmaps` to a non-mutating read of whatever init produced:

```zig
    /// Bitmaps are built once in init; a failed build means category filters
    /// degrade to no-bitmap scans. No lazy retry — queries may run off-main
    /// concurrently with the sidebar, and mutating here would be a data race.
    pub fn getCategoryBitmaps(self: *IndexReader) !*std.AutoHashMap(types.FileCategory, bitmap_mod.Bitmap) {
        if (self.category_bitmaps) |*bm| return bm;
        return error.BitmapsUnavailable;
    }
```

Update the two call sites in `src/index/search.zig` (lines ~57-73) to treat the error as "no bitmap" (`catch null` on the `bitmaps.get(...)` chain — wrap: `var bitmaps = reader.getCategoryBitmaps() catch null; if (bitmaps) |bm| cat_bitmap = bm.get(cat);`). Run `zig build test` — the C-API category tests (`zest_query routes cat: ...`) must still pass, proving eager init covers the normal path.

- [ ] **Step 2: Async pipeline in AppCoordinator**

Replace the synchronous cache fill with delivered snapshots. The shape:

```swift
    /// Serial queue for engine queries — one in flight at a time; the
    /// generation check drops stale deliveries (sidebar-style pattern).
    private let queryQueue = DispatchQueue(label: "zest.query", qos: .userInitiated)
    private var queryGeneration = 0

    private func notifyChange() {
        guard !suppressChange else { return }
        cachedResults = nil
        startQuery()
        onChange?()  // observers render the stale/empty snapshot + loading state now
    }

    var isLoading: Bool { cachedResults == nil && core != nil }

    private func startQuery() {
        queryGeneration += 1
        let gen = queryGeneration
        guard let core else { return }
        let q = queryText
        let root = scopeRoot
        let depth = scopeDepth
        queryQueue.async { [weak self] in
            var rows = core.query(q, scope: root, maxDepth: depth, maxResults: UInt32(Self.maxResults))
            // Sorting happens off-main too — applySort only reads value-type
            // state captured below.
            DispatchQueue.main.async {
                guard let self, self.queryGeneration == gen else { return }
                self.applySort(to: &rows)
                self.cachedResults = rows
                self.onChange?()  // second pass: observers render fresh rows
            }
        }
    }

    /// Last delivered rows (possibly one tick stale while a query is in
    /// flight). Never blocks.
    func results() -> [ZestCore.Row] {
        cachedResults ?? []
    }
```

Notes for the implementer:
- `applySort` runs on main in the delivery block (it reads `sortColumn`/`sortAscending`); rows arrive unsorted from the queue. If sort shows up in profiles later, snapshot the sort state into the closure and sort off-main — don't do it speculatively.
- The double-`onChange` (stale render + fresh render) is intentional and cheap: sidebar caches by (path, scope); browser reload with identical items is a fast table reload at 2k rows. The empty initial render also gives instant navigation feedback.
- `core` is captured strongly in the closure on purpose — a hot-reload swap mid-query keeps the old core alive until delivery, then the stale generation drops it. This is the snapshot-lifetime guarantee.
- Initial load: `RootViewController.viewDidLoad` ends with refresh calls; ensure one `notifyChange()`-equivalent kick happens (call `coordinator.kickInitialQuery()` = `startQuery()` exposed, or simply have `viewDidLoad` set `coordinator.onChange` then call `coordinator.refreshAll()` — a new public method doing `notifyChange()`).

- [ ] **Step 3: Loading state in the filter bar**

In `FilterBarView.updateCount()`, render an em-dash while loading:

```swift
        let countText =
            coordinator.isLoading ? "…" : (coordinator.resultsCapped ? "\(n)+" : "\(n)")
```

- [ ] **Step 4: Build, tests, manual stutter check**

Run: `swift build && swift test 2>&1 | tail -3` — pass.
Manual: `just run` (or `swift run Zest`), type a 1-char search in `~` scope: UI stays responsive, count shows `…` then the capped count. Folder switching never beachballs.

- [ ] **Step 5: Commit**

```bash
git add src/index/reader.zig src/index/search.zig Sources/Zest/App/AppCoordinator.swift Sources/Zest/Shell/FilterBarView.swift
git commit -m "perf(ui): queries run off-main with generation-dropped staleness

Serial query queue + generation counter in AppCoordinator (the sidebar
histogram already used this pattern); observers render instantly and get
a second onChange when fresh rows land. Reader bitmaps become eager-only
(no lazy mutation) so concurrent query/sidebar threads can't race."
```

---

### Task 6: Double-click reliability + selection preservation (roadmap B1)

`reload()` does `reloadData()` + select-row-0 + scroll-to-top on *every* change — destroying the clicked row mid-double-click and trashing scroll position on refreshes (e.g. index hot-reload, async second pass).

**Files:**
- Modify: `Sources/Zest/Browser/BrowserViewController.swift`

- [ ] **Step 1: Key the reset behavior on context change**

Add a context key; only reset selection/scroll when it changes:

```swift
    private struct ReloadKey: Equatable {
        let path: String
        let query: String
        let scope: AppCoordinator.Scope
    }
    private var lastReloadKey: ReloadKey?

    func reload() {
        searchMode = coordinator.isSearchMode
        let selectedPath = tableView.selectedRow >= 0 && tableView.selectedRow < items.count
            ? items[tableView.selectedRow].path : nil

        items = coordinator.results().map { Self.makeItem(from: $0) }
        updateSortIndicator()

        let isEmpty = items.isEmpty
        scrollView.isHidden = isEmpty
        emptyLabel?.isHidden = !isEmpty
        // (keep the Task-4 empty-state copy block here)

        tableView.reloadData()

        let key = ReloadKey(path: coordinator.currentPath, query: coordinator.queryText, scope: coordinator.scope)
        let contextChanged = key != lastReloadKey
        lastReloadKey = key

        if isEmpty {
            tableView.deselectAll(nil)
        } else if contextChanged {
            // Real navigation/search change: reset to the top.
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        } else if let selectedPath, let idx = items.firstIndex(where: { $0.path == selectedPath }) {
            // Same context (async second pass, hot-reload, sort tweak):
            // keep the user's selection and scroll position.
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        pushSelectionSummary()
    }
```

Note: sort changes leave the key equal but reorder rows — re-finding `selectedPath` makes the selection follow the item, which is the desired behavior.

- [ ] **Step 2: Build + manual double-click check**

Run: `swift build` — pass. Manual: `just run`, double-click folders repeatedly including immediately after typing in search; navigation triggers reliably; scroll position survives the async second pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/Zest/Browser/BrowserViewController.swift
git commit -m "fix(ui): preserve selection/scroll on same-context reloads

reloadData + select-row-0 + scroll-to-top now happen only when the
(path, query, scope) context actually changes. Refresh passes (async
delivery, index hot-reload, sort) keep the selected item — fixes
double-clicks dying when a reload recycled the clicked row."
```

---

### Task 7: Navigation failure feedback (roadmap B2)

**Files:**
- Modify: `Sources/Zest/App/AppCoordinator.swift` (`navigate` returns Bool)
- Modify: `Sources/Zest/Shell/Breadcrumb.swift` (beep + stay in edit on failure)
- Modify: `Sources/Zest/Browser/BrowserViewController.swift` (beep on dead folder)

- [ ] **Step 1: Make navigate report**

```swift
    @discardableResult
    func navigate(to path: String) -> Bool {
        let resolved = Self.resolve(path, relativeTo: currentPath)
        guard isDirectory(resolved) else { return false }
        guard resolved != currentPath else { return true }  // no-op, not a failure
        backStack.append(currentPath)
        forwardStack.removeAll()
        currentPath = resolved
        resetQueryForNavigation()
        notifyChange()
        return true
    }
```

- [ ] **Step 2: Breadcrumb: failed Enter beeps and stays editable**

In `Breadcrumb.commitEdit()`, navigate *first*; only leave edit mode on success:

```swift
    private func commitEdit() {
        let value = editField.stringValue
        if !coordinator.navigate(to: value) {
            NSSound.beep()
            editField.currentEditor()?.selectAll(nil)
            return  // stay in edit mode so the user can fix the path
        }
        editing = false
        editField.isHidden = true
        stack.isHidden = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.clear.cgColor
        layer?.shadowOpacity = 0
        window?.makeFirstResponder(window)
        refresh()
    }
```

In `BrowserViewController.activate(row:)`, the directory branch becomes:

```swift
        if item.isDirectory {
            if !coordinator.navigate(to: item.path) { NSSound.beep() }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
```

- [ ] **Step 3: Build + test + commit**

Run: `swift build && swift test 2>&1 | tail -3` — pass.

```bash
git add Sources/Zest/App/AppCoordinator.swift Sources/Zest/Shell/Breadcrumb.swift Sources/Zest/Browser/BrowserViewController.swift
git commit -m "fix(ui): audible feedback when navigation fails

navigate(to:) reports success; a bad address-bar path beeps and stays in
edit mode instead of silently reverting, and double-clicking a stale/
deleted folder beeps instead of doing nothing."
```

---

### Task 8: Lazy row formatting + cheap sort keys (roadmap B3)

`makeItem` runs `ByteCountFormatter` + `DateFormatter` for every row (2k now, still wasteful); sorts use `localizedCaseInsensitiveCompare` per comparison.

**Files:**
- Modify: `Sources/Zest/Browser/BrowserViewController.swift` (+ `FileItem` wherever it's defined — same file or `Browser/FileItem.swift`)
- Modify: `Sources/Zest/App/AppCoordinator.swift` (sort comparators)

- [ ] **Step 1: Make FileItem format lazily**

Store raw values; compute display strings on first access (only visible rows get asked):

```swift
final class FileItem {  // class: lazy vars need mutability; rows are reference-shared with cells
    let name: String
    let path: String
    let dirPath: String
    let isDirectory: Bool
    let size: UInt64
    let mtime: Int64
    let kindLabel: String
    let kindColor: NSColor
    let symbol: String
    let symbolColor: NSColor
    let extText: String

    lazy var sizeText: String = isDirectory ? "—" : Self.formatSize(size)
    lazy var isoDate: String = Self.isoFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(mtime)))
    lazy var agoText: String = Self.relativeText(from: mtime)
    ...
}
```

Move `makeItem`'s formatting helpers (`byteFormatter` → replace with a hand-rolled `formatSize`, `isoFormatter`, `relativeText`) onto `FileItem`. Hand-rolled size (no NSFormatter overhead):

```swift
    static func formatSize(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }
```

Adjust `makeItem` to pass raw `size`/`mtime` through, and the cell-population code (`tableView(_:viewFor:row:)` / `FileCellView`) keeps reading `item.sizeText` etc. — now lazily computed. `currentSelectionSummary()` keeps working unchanged.

- [ ] **Step 2: Cheap sort comparators**

In `AppCoordinator.applySort`, sort on a precomputed key instead of ICU comparisons per compare:

```swift
    private func applySort(to rows: inout [ZestCore.Row]) {
        let asc = sortAscending
        func ascending(_ less: Bool) -> Bool { asc ? less : !less }

        // One lowercased key per row (O(n)), then cheap byte compares in the
        // O(n log n) sort — replaces localizedCaseInsensitiveCompare per
        // comparison (~1.7M ICU calls for a full result set).
        switch sortColumn {
        case .name:
            let keys = rows.map { $0.name.lowercased() }
            var order = Array(rows.indices)
            order.sort { i, j in
                if asc {
                    let ad = rows[i].kind == 1
                    let bd = rows[j].kind == 1
                    if ad != bd { return ad }
                }
                if keys[i] == keys[j] { return false }
                return ascending(keys[i] < keys[j])
            }
            rows = order.map { rows[$0] }
        case .size:
            let keys = rows.map { $0.name.lowercased() }
            sortWithTieBreak(&rows, keys: keys, asc: asc) { ($0.size, $1.size) }
        case .modified:
            let keys = rows.map { $0.name.lowercased() }
            sortWithTieBreak(&rows, keys: keys, asc: asc) { ($0.mtime, $1.mtime) }
        case .kind:
            let labels = rows.map { Category.meta(kind: $0.kind, category: $0.category).label }
            let keys = rows.map { $0.name.lowercased() }
            var order = Array(rows.indices)
            order.sort { i, j in
                if labels[i] == labels[j] { return keys[i] < keys[j] }
                return ascending(labels[i] < labels[j])
            }
            rows = order.map { rows[$0] }
        case .ext:
            let exts = rows.map { $0.fileExtension }
            let keys = rows.map { $0.name.lowercased() }
            var order = Array(rows.indices)
            order.sort { i, j in
                if exts[i] == exts[j] { return keys[i] < keys[j] }
                return ascending(exts[i] < exts[j])
            }
            rows = order.map { rows[$0] }
        }
    }

    private func sortWithTieBreak<K: Comparable>(
        _ rows: inout [ZestCore.Row], keys: [String], asc: Bool,
        _ key: (ZestCore.Row, ZestCore.Row) -> (K, K)
    ) {
        var order = Array(rows.indices)
        order.sort { i, j in
            let (a, b) = key(rows[i], rows[j])
            if a == b { return keys[i] < keys[j] }
            return asc ? a < b : a > b
        }
        rows = order.map { rows[$0] }
    }
```

Behavior note (intentional): name ordering becomes simple Unicode-scalar ordering of lowercased names instead of locale collation. For filenames this is imperceptible and ~50× cheaper. If the user reports odd ordering for localized names, revisit with a precomputed `localizedStandardCompare` key array.

- [ ] **Step 3: Build, tests, commit**

Run: `swift build && swift test 2>&1 | tail -3` — pass.

```bash
git add Sources/Zest/Browser/ Sources/Zest/App/AppCoordinator.swift
git commit -m "perf(ui): lazy row formatting + precomputed sort keys

Size/date strings format on first access (visible rows only) with a
hand-rolled byte formatter; sorts compare precomputed lowercase keys
instead of per-comparison ICU calls."
```

---

### Task 9: Subtree filter-query fast path (roadmap B4, Zig)

Filter-only queries with `max_depth > 1` (scope = Subfolders) call `buildResult` + string-prefix `matchesScope` for ALL ~5.5M entries. Mark subtree dirs once, then test the parent-id column per entry.

**Files:**
- Modify: `src/index/search.zig` (filter-only branch)
- Modify: `src/index/subtree.zig` (export the dir-marking helper if private)

- [ ] **Step 1: Write the failing perf-shape test (correctness pin)**

Add to `src/index/search.zig` tests (fixture style copied from the existing scope tests in that file):

```zig
test "filter-only subtree query matches descendants but not siblings" {
    const format = @import("format.zig");
    const entries = [_]format.IndexEntry{
        .{ .name = "a.pdf", .dir_path = "/home/u/docs", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
        .{ .name = "b.pdf", .dir_path = "/home/u/docs/sub", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
        .{ .name = "c.pdf", .dir_path = "/home/other", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
        .{ .name = "sub", .dir_path = "/home/u/docs", .size = 0, .mtime = 1, .kind = .directory, .category = .uncategorized },
    };
    const data = try format.writeIndex(std.testing.allocator, &entries);
    defer std.testing.allocator.free(data);
    var reader = try @import("reader.zig").IndexReader.init(std.testing.allocator, data);
    defer reader.deinit();

    const f = [_]filters.FilterCriterion{.{ .ext = .{ .value = "pdf", .negated = false } }};
    const results = try search(std.testing.allocator, &reader, .{
        .query = "",
        .filters = &f,
        .scope = "/home/u/docs",
        .max_depth = std.math.maxInt(u32),
        .max_results = 100,
    });
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len); // a.pdf + b.pdf, NOT c.pdf
}
```

(Adapt the `FilterCriterion` construction to the actual shape in `src/core/filters.zig` — check its test blocks for the literal syntax.) Run `zig build test`: this should PASS already (it pins behavior before the optimization — green-to-green refactor).

- [ ] **Step 2: Implement the fast path**

In the filter-only branch of `search()` (`src/index/search.zig:151+`), extend the existing `scope_dir_id` resolution with a subtree-membership table. `subtree.zig` walks descendants via the dir table — reuse its marking logic; if `markSubtreeDirs` is private/absent, add an exported helper there:

```zig
/// Fill `marks[dir_id] = 1` for `scope_path`'s dir and every descendant dir.
/// `marks.len` must equal the dir-table count. O(D) over the dir table.
pub fn markSubtreeDirs(reader: reader_mod.IndexReader, scope_path: []const u8, marks: []u8) void {
    // walk the dir table exactly like computeHistogram does — copy that
    // function's dir-table iteration, but instead of summing counts, set
    // marks[d] = 1 when the dir path == scope_path or starts with
    // scope_path ++ "/".
}
```

(Concretely: copy `computeHistogram`'s loop skeleton — it already iterates `(dir_id, dir_path)` pairs; replace its body with the prefix test + `marks[d] = 1`.)

Then in `search.zig`, replace the per-entry `matchesScope` string compare for the subtree case:

```zig
        const dir_count = reader.dirCount(); // add a trivial getter if absent (reads the same header field findDirId uses)
        var subtree_marks: ?[]u8 = null;
        defer if (subtree_marks) |m| allocator.free(m);
        if (opts.max_depth > 1 and !scope_is_root) {
            const m = try allocator.alloc(u8, dir_count);
            @memset(m, 0);
            subtree_mod.markSubtreeDirs(reader.*, stripTrailingSlash(opts.scope), m);
            subtree_marks = m;
        }

        var idx: u32 = 0;
        while (idx < num_entries and results.items.len < opts.max_results) : (idx += 1) {
            // (cancellation check unchanged)
            if (scope_dir_id) |want| {
                if ((reader.getParentId(idx) orelse continue) != want) continue;
            } else if (subtree_marks) |m| {
                const pid = reader.getParentId(idx) orelse continue;
                if (pid >= m.len or m[pid] == 0) continue;
            }
            if (cat_bitmap) |bm| {
                if (!bm.contains(idx)) continue;
            }
            if (buildResult(reader, idx)) |result| {
                // matchesScope stays as a cheap depth check only when needed;
                // for subtree_marks hits the prefix test is already proven.
                if (subtree_marks == null and !matchesScope(result.dir_path, opts.scope, opts.max_depth)) continue;
                if (!matchFilters(opts.filters, result)) continue;
                try results.append(allocator, result);
            }
        }
```

- [ ] **Step 3: Tests + bench**

Run: `zig build test` — all pass including Step 1's pin and the existing scope/depth tests.
Run: `just bench-capi 2>&1 | tail -20` — record the table; the search ladder must be unchanged (text path untouched); no regression anywhere.

- [ ] **Step 4: Commit**

```bash
git add src/index/search.zig src/index/subtree.zig
git commit -m "perf(search): subtree filter queries match parent-ids, not path strings

Filter-only queries at depth>1 marked: build a dir-id membership table
once (O(D) over the dedup'd dir table), then test one byte per entry
instead of buildResult + string-prefix compare for all 5.5M entries."
```

---

### Task 10: Fix subtree ext-breakdown merge (roadmap B5, Zig)

The merge map in `computeExtBreakdown` keys on the *prospective append offset* (`ext_storage.items.len`) — strictly increasing, so `found_existing` is never true and per-extension counts never merge across directories.

**Files:**
- Modify: `src/index/subtree.zig`

- [ ] **Step 1: Write the failing test**

Add to `src/index/subtree.zig` (or alongside the existing breakdown tests in `src/capi/zest_core.zig`, matching their fixture style):

```zig
test "subtree ext breakdown merges the same ext across directories" {
    const format = @import("format.zig");
    const entries = [_]format.IndexEntry{
        .{ .name = "a.pdf", .dir_path = "/home/u/x", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
        .{ .name = "b.pdf", .dir_path = "/home/u/y", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
    };
    const data = try format.writeIndex(std.testing.allocator, &entries);
    defer std.testing.allocator.free(data);
    var reader = try reader_mod.IndexReader.init(std.testing.allocator, data);
    defer reader.deinit();

    var out: [8]reader_mod.IndexReader.ExtCount = undefined;
    const n = computeExtBreakdown(reader, "/home/u", 3, out[0..], std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), n); // ONE merged "pdf" row…
    try std.testing.expectEqual(@as(u32, 2), out[0].count); // …with count 2
}
```

(Adapt the `computeExtBreakdown` signature/category-arg to the actual declaration at the top of the function — `cat` 3 = documents.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -5`
Expected: FAIL — n == 2 (two unmerged "pdf" rows).

- [ ] **Step 3: Key the merge map by name bytes**

Replace `KeyOff`/`KeyOffContext`/`ext_storage` with a `StringHashMap` keyed by slices into `data` (the index buffer outlives the call):

```zig
    var merge = std.StringHashMap(u32).init(allocator);
    defer merge.deinit();
    ...
                    const name = data[p..@intCast(p + len)];
                    p += len;
                    const count = std.mem.readInt(u32, data[p..][0..4], .little);
                    p += 4;

                    const gop = merge.getOrPut(name) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += count;
```

Delete the now-dead `KeyOff`, `KeyOffContext`, and `ext_storage` plumbing; the materialization loop at the end iterates `merge.iterator()` getting `entry.key_ptr.*` (the name slice) + `entry.value_ptr.*` directly.

- [ ] **Step 4: Run tests, verify in app, commit**

Run: `zig build test && zig build core -Doptimize=ReleaseFast` — pass, including Step 1's test.
Manual: `just run`, set scope to Subfolders in a tree with the same ext in many dirs — sidebar category expansion shows one row per ext with merged counts.

```bash
git add src/index/subtree.zig
git commit -m "fix(index): subtree ext-breakdown merges by name, not storage offset

The merge map keyed on the prospective append offset — strictly
increasing, so identical extensions in different dirs never merged and
the sidebar showed duplicate split rows. Key by the ext name bytes
(slices into the index buffer, which outlives the call)."
```

---

### Task 11: Corrupt-index + daemon hardening batch (roadmap C1–C6)

Small independent fixes; one commit. For each, the pattern is: failing test with corrupt bytes where practical, fix, green.

**Files:**
- Modify: `src/index/reader.zig` (C1, C2, C4), `src/index/bitmap.zig` (C1, C3), `src/index/bulk_scan.zig` (C5, C6), `src/index/builder.zig` (C5 parse side)

- [ ] **Step 1 (C1): Safe enum decode**

`reader.zig getMeta` (~line 196):

```zig
        const kind = std.enums.fromInt(types.FileKind, self.data[kinds_start + idx]) orelse .file;
        const category = std.enums.fromInt(types.FileCategory, self.data[cats_start + idx]) orelse .uncategorized;
```

`bitmap.zig readCategoryBitmaps` (~line 132): skip unknown categories instead of `@enumFromInt`:

```zig
        const cat = std.enums.fromInt(types.FileCategory, cat_byte) orelse {
            allocator.free(aligned);
            pos = end;
            continue;
        };
```

Test (in `reader.zig`): build a valid index via `format.writeIndex`, flip one kind byte to `0xFF` (locate it: `meta_offset + num*8 + num*8 + idx`), assert `getMeta` returns `.file` instead of panicking. If byte-surgery on the fixture proves too fiddly, a direct unit test of `std.enums.fromInt(types.FileKind, 0xFF) == null` plus the code change is acceptable coverage.

- [ ] **Step 2 (C2): getDirPath bounds**

In `reader.zig getDirPath`, before the slice (after `next_offset` is computed, ~line 133):

```zig
        if (dir_offset > next_offset or next_offset > dir_blob_len) return null;
```

- [ ] **Step 3 (C3): bitmap count overflow**

`bitmap.zig` ~line 124:

```zig
        const end = pos + @as(usize, cnt) * 4;
```

- [ ] **Step 4 (C4): validate num_entries at open**

In `IndexReader.init`, after the header parse, before bitmaps:

```zig
        // A corrupt num_entries makes every column extent lie outside the
        // buffer; reject at open instead of panicking on first access. The
        // meta column alone needs num*(8+8+1+1) bytes.
        const num: usize = @intCast(header.num_entries);
        const meta_need = std.math.mul(usize, num, 18) catch return error.MalformedIndex;
        if (header.meta_offset > data.len or meta_need > data.len - @as(usize, @intCast(header.meta_offset)))
            return error.MalformedIndex;
```

(Adapt field names to the actual header struct; the existing `zest_open returns null on malformed bytes` test plus a new test with a forged huge `num_entries` header pin this.)

- [ ] **Step 5 (C5): escape TSV-breaking filename bytes**

Writer (`bulk_scan.zig` ~line 271, the `w.writer.print` call) — escape `\`, `\t`, `\n` in `name` (paths can't contain them — they'd have been rejected as dirs earlier; if paranoid, escape `path` too with the same helper):

```zig
// Before the print: names may legally contain \t and \n on APFS, which
// would shear the TSV record. Escape into a small stack buffer
// (MAXNAMLEN*2 worst case); records unescape in builder.zig.
```

Add to a shared spot (`format.zig` or a new small fn in `bulk_scan.zig` + mirrored unescape in `builder.zig`):

```zig
pub fn escapeTsv(out: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (s) |ch| {
        const esc: ?u8 = switch (ch) {
            '\\' => '\\',
            '\t' => 't',
            '\n' => 'n',
            else => null,
        };
        if (esc) |e| {
            if (n + 2 > out.len) return null;
            out[n] = '\\';
            out[n + 1] = e;
            n += 2;
        } else {
            if (n + 1 > out.len) return null;
            out[n] = ch;
            n += 1;
        }
    }
    return out[0..n];
}

pub fn unescapeTsv(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            out[n] = switch (s[i]) {
                't' => '\t',
                'n' => '\n',
                else => s[i],
            };
        } else {
            out[n] = s[i];
        }
        n += 1;
    }
    return out[0..n];
}
```

Wire: writer escapes `name` (and `path`); `builder.zig`'s scan-line parser unescapes both fields after splitting on `\t`. Test: round-trip `"we\tird\nname"` through escape→TSV line→split→unescape in a `format.zig` test block.

- [ ] **Step 6 (C6): worker-pool pending count**

`bulk_scan.zig` ~line 166 — count only successful appends:

```zig
        var appended: usize = 0;
        for (subdirs.items) |sd| {
            if (sh.queue.append(sh.alloc, sd)) {
                appended += 1;
            } else |_| {
                sh.write_failed.store(true, .monotonic);
                sh.alloc.free(sd);
            }
        }
        sh.pending += appended;
        sh.pending -= 1;
        if (sh.pending == 0) {
            sh.done = true;
            sh.cond.broadcast(io);
        } else if (appended > 0) {
```

(Keep the trailing `cond` signaling consistent with the existing `else if` body — it signals workers when new work arrived.)

Also (same file, ~line 266, the single-threaded `processDir` path): `subdirs.append(alloc, cp) catch alloc.free(cp);` → also set `write_failed` if the shared handle is reachable there; if not reachable, leave and note it — the worker path is the one that deadlocked.

- [ ] **Step 7: Full gate + commit**

Run: `zig build test && zig build core -Doptimize=ReleaseFast && zig build indexer -Doptimize=ReleaseFast && swift test 2>&1 | tail -3` — pass.
Run: `just bench-capi 2>&1 | tail -16` — no regression vs the Task 9 table.

```bash
git add src/index/
git commit -m "fix(index): harden readers + scanner against corrupt input

- enum decodes from disk bytes fall back instead of panicking (kind,
  category, bitmap category byte)
- getDirPath validates offset ordering; bitmap count can't overflow u32;
  num_entries validated against the buffer at open
- filenames containing tab/newline (legal on APFS) are escaped in scan
  records instead of shearing the TSV line
- worker pool counts only successfully queued subdirs (OOM no longer
  deadlocks the scan)"
```

---

### Task 12: Final verification + roadmap bookkeeping

- [ ] **Step 1: Full matrix**

Run: `just test && just bench-capi 2>&1 | tail -16`
Expected: everything green; bench ladder at-or-better than the Task 0 baseline (search `i`/`in` ≈ 18-24ms @100k in ReleaseFast, browse ≈ 5ms, no new regressions).

- [ ] **Step 2: Run the app**

`just run` — manual sweep: type "invoice" in search (no stutter, count updates), switch folders rapidly, double-click folders, breadcrumb-edit a bad path (beep, stays editable), pin list shows your real pins.json content.

- [ ] **Step 3: Update docs/ROADMAP.md**

Tick: A5, A6, A7, B1, B2, B3, B4, B5, B6, C1–C6, D1, D6, E1b(partial — pins/colors done, saved-filters manager still E1). Append the new bench table under "Benchmarks" with the date.

- [ ] **Step 4: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs: tick stabilization round in roadmap; refresh bench baseline"
```

---

## Deferred (explicitly out of this plan)

- **C7** folded into Task 5 (bitmap race). **C8** (C-ABI error out-param) deferred — Swift-visible behavior identical today; revisit with the next ABI change.
- **E1** saved-filters manager, **E1c** theming/light mode, **E1d** command model, **E1e** app bundle, **E2** dir→entry-range format v4, **E3** SIMD scan — roadmap Phase E, separate plan.
- Daemon launchd install — user runs `just index` manually for now.
