# Zest UI Phase 0 — FFI Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the Swift-AppKit-UI ↔ Zig-core architecture end to end — build a `zest-core` C-ABI static library over the existing index engine, link it from a SwiftPM app, and open a window that runs a **real query against the on-disk index** and shows the result count.

**Architecture:** The Zig engine (`IndexReader` + `search`) is pure CPU and needs no `Io`. Swift `mmap`s the index file and passes the byte pointer across a hand-written C ABI (`src/capi/zest_core.zig` → `zest_core.h`); Zig parses + searches over the borrowed bytes and returns rows whose strings borrow into that mmap (Swift copies them at the boundary, then frees the query). No Zig `main`, no `Io` in the library.

**Tech Stack:** Zig 0.16 (`b.addLibrary(.linkage = .static)`, `export fn`, `extern struct`, `std.heap.c_allocator`), C ABI, SwiftPM (`swift-tools-version:5.9`, macOS 13+), Swift + AppKit, `mmap(2)`.

---

## Plan series (this is plan 1 of ~6)

This plan delivers **P0** from the spec (`docs/superpowers/specs/2026-06-06-gui-redesign-design.md` §12). Later phases get their own plans once P0 lands:
- **P1** — static shell (toolbar/breadcrumb/filter-bar/`NSSplitViewController`/sidebar/table/status) with fake data; resize hardening (§8).
- **P2** — rows (`FileRowView`/`FileCellView`, two-line, kind pill, item-count, accent rail, Ext column, ISO date+timeago).
- **P3** — wire FFI for real (BrowserModel/snapshot, scope, search+tokens, sort, off-main debounce).
- **P4** — sidebar pins + scope-aware category histogram (`zest_histogram`) + saved-filters window (`zest_filters_*`) + status/empty/loading.
- **P5** — command model, menus, context menus, drag/drop, SwiftUI islands.
- **P6** — swap: ship the Swift app, delete `src/ui/*` + Zig `async_search`.

**Verification model:** logic/FFI tasks use real TDD; AppKit UI tasks (none here beyond a smoke window) use the screenshot-vs-prototype loop (spec §11). The engine's own correctness is already covered by `search.zig`/`reader.zig` tests — this plan tests the **wrapper + linking + marshaling**, not the search algorithm.

---

## File structure

| File | Responsibility |
|---|---|
| `src/capi/zest_core.zig` (create) | C-ABI surface over `IndexReader` + `search`: open/close/query/count/row/free |
| `src/test_root.zig` (modify) | register `zest_core.zig` so its tests run under `zig build test` |
| `build.zig` (modify) | add the `zest-core` static-library artifact + a `core` build step |
| `Sources/CZestCore/include/zest_core.h` (create) | canonical C header (consumed by both the C-interop module and any C test) |
| `Sources/CZestCore/empty.c` (create) | gives the C-interop target a compilable source |
| `Package.swift` (create, repo root) | SwiftPM: `CZestCore` C module + `Zest` executable + `ZestTests` |
| `Sources/Zest/Core/ZestCore.swift` (create) | safe Swift veneer: `mmap` + RAII + String marshaling |
| `Sources/Zest/Design/Theme.swift` (create) | Ink tokens + `deriveAccent` (base/effective/on-accent) |
| `Sources/Zest/App/main.swift` (create) | `NSApplication` bootstrap + argv |
| `Sources/Zest/App/AppDelegate.swift` (create) | minimal window showing the live query count |
| `Sources/ZestTests/ZestCoreTests.swift` (create) | XCTest: open real index (skip if absent), query returns rows |
| `Sources/ZestTests/ThemeTests.swift` (create) | XCTest: accent luminance + on-accent decision |
| `justfile` (modify) | `core`, `app`, `build`, `run-app` recipes |

---

## Task 1: Zig C-ABI core

**Files:**
- Create: `src/capi/zest_core.zig`
- Modify: `src/test_root.zig`

- [ ] **Step 1: Write the C-ABI core**

Create `src/capi/zest_core.zig`:

```zig
//! C ABI over the Zig index engine for the Swift UI. Pure CPU: the caller
//! (Swift) mmaps the index file and passes the bytes; we borrow them for the
//! Core's lifetime. No Io, no global runtime state — there is no Zig `main` here.
const std = @import("std");
const reader_mod = @import("../index/reader.zig");
const search_mod = @import("../index/search.zig");

const alloc = std.heap.c_allocator;

const Core = struct {
    reader: reader_mod.IndexReader,
};

const Query = struct {
    results: []search_mod.SearchResult,
};

pub const ZestStr = extern struct {
    ptr: [*]const u8,
    len: usize,
};

pub const ZestRow = extern struct {
    name: ZestStr,
    dir_path: ZestStr,
    size: u64,
    mtime: i64,
    kind: u8,
    category: u8,
};

fn zstr(s: []const u8) ZestStr {
    return .{ .ptr = s.ptr, .len = s.len };
}

/// Open an index from caller-owned, caller-kept-alive bytes (a Swift mmap).
/// Returns null on a malformed index. Borrows `index_bytes` until `zest_close`.
export fn zest_open(index_bytes: [*]const u8, len: usize) ?*Core {
    const core = alloc.create(Core) catch return null;
    core.* = .{
        .reader = reader_mod.IndexReader.init(alloc, index_bytes[0..len]) catch {
            alloc.destroy(core);
            return null;
        },
    };
    return core;
}

export fn zest_close(core: *Core) void {
    core.reader.deinit();
    alloc.destroy(core);
}

/// Run one query. `scope_root` "" or "/" means the whole index. `max_depth` 1 =
/// direct children (folder listing), large = subtree. Returns null on error.
export fn zest_query(
    core: *Core,
    query_utf8: [*:0]const u8,
    scope_root: [*:0]const u8,
    max_depth: u32,
    max_results: u32,
) ?*Query {
    const scope_in = std.mem.span(scope_root);
    const scope = if (scope_in.len == 0) "/" else scope_in;
    const results = search_mod.search(alloc, &core.reader, .{
        .query = std.mem.span(query_utf8),
        .scope = scope,
        .max_depth = max_depth,
        .max_results = max_results,
    }) catch return null;
    const q = alloc.create(Query) catch {
        alloc.free(results);
        return null;
    };
    q.* = .{ .results = results };
    return q;
}

export fn zest_query_count(q: *const Query) usize {
    return q.results.len;
}

/// Row `i`'s strings borrow into the index mmap — valid until `zest_query_free`
/// AND while the Core's bytes stay mapped. Swift copies them immediately.
export fn zest_query_row(q: *const Query, i: usize) ZestRow {
    const r = q.results[i];
    return .{
        .name = zstr(r.name),
        .dir_path = zstr(r.dir_path),
        .size = r.size,
        .mtime = r.mtime,
        .kind = @intFromEnum(r.kind),
        .category = @intFromEnum(r.category),
    };
}

export fn zest_query_free(q: *Query) void {
    alloc.free(q.results);
    alloc.destroy(q);
}

test "zest_open returns null on malformed bytes" {
    const garbage = [_]u8{ 0, 1, 2, 3 };
    try std.testing.expect(zest_open(&garbage, garbage.len) == null);
}
```

- [ ] **Step 2: Register the file so its test runs**

In `src/test_root.zig`, add a reference alongside the other module imports (match the existing `_ = @import("...");` style in that file):

```zig
_ = @import("capi/zest_core.zig");
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `zig build test`
Expected: PASS (the new `zest_open returns null on malformed bytes` test runs green; all existing tests still pass). `IndexReader.init` rejects the 4-byte garbage (bad magic/too short) → `zest_open` returns null.

- [ ] **Step 4: Commit**

```bash
git add src/capi/zest_core.zig src/test_root.zig
git commit -m "feat(core): C-ABI wrapper over index reader + search"
```

---

## Task 2: Build the static library

**Files:**
- Modify: `build.zig`

- [ ] **Step 1: Add the static-library artifact**

In `build.zig`, after the `zest-indexer` block (around line 43, before the `indexer_step`), insert:

```zig
    // === Library: zest-core (C ABI for the Swift UI) ===
    // Pure-CPU engine surface (reader + search). No frameworks, no Io.
    const core_lib = b.addLibrary(.{
        .name = "zest-core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi/zest_core.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    core_lib.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(core_lib);

    // `zig build core` — build only the static library (what the Swift app links).
    const core_step = b.step("core", "Build only libzest-core.a");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);
```

- [ ] **Step 2: Build the library and verify the artifact**

Run: `zig build core && ls -la zig-out/lib/`
Expected: a `libzest-core.a` file exists under `zig-out/lib/`.

- [ ] **Step 3: Verify the symbols are exported**

Run: `nm zig-out/lib/libzest-core.a | grep -E '_zest_(open|query|close)'`
Expected: lines listing `T _zest_open`, `T _zest_query`, `T _zest_close`, etc. (`T` = defined text symbol; the leading `_` is the macOS C symbol prefix).

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "build: emit libzest-core.a static library + `zig build core` step"
```

---

## Task 3: C header

**Files:**
- Create: `Sources/CZestCore/include/zest_core.h`

- [ ] **Step 1: Write the header (matches the Zig exports exactly)**

Create `Sources/CZestCore/include/zest_core.h`:

```c
#ifndef ZEST_CORE_H
#define ZEST_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { const uint8_t *ptr; size_t len; } ZestStr; // NOT null-terminated
typedef struct {
    ZestStr  name;
    ZestStr  dir_path;
    uint64_t size;
    int64_t  mtime;   // unix seconds
    uint8_t  kind;    // 0 file, 1 dir, 2 symlink (FileKind order)
    uint8_t  category;// FileCategory enum
} ZestRow;

typedef struct Core  Core;   // opaque
typedef struct Query Query;  // opaque

// Borrows index_bytes until zest_close (caller keeps them mapped).
Core  *zest_open(const uint8_t *index_bytes, size_t len);
void   zest_close(Core *core);

// scope_root "" or "/" = whole index; max_depth 1 = folder listing, large = subtree.
Query *zest_query(Core *core, const char *query_utf8, const char *scope_root,
                  uint32_t max_depth, uint32_t max_results);
size_t  zest_query_count(const Query *q);
ZestRow zest_query_row(const Query *q, size_t i); // strings valid until zest_query_free
void    zest_query_free(Query *q);

#ifdef __cplusplus
}
#endif

#endif // ZEST_CORE_H
```

- [ ] **Step 2: Verify the header compiles**

Run: `clang -fsyntax-only -I Sources/CZestCore/include -x c /dev/null && clang -fsyntax-only Sources/CZestCore/include/zest_core.h`
Expected: no output, exit 0 (header is self-contained and parses).

- [ ] **Step 3: Commit**

```bash
git add Sources/CZestCore/include/zest_core.h
git commit -m "feat(ffi): hand-written zest_core.h C header"
```

---

## Task 4: SwiftPM package scaffold

**Files:**
- Create: `Package.swift` (repo root)
- Create: `Sources/CZestCore/empty.c`

- [ ] **Step 1: Add the C-interop target source**

Create `Sources/CZestCore/empty.c`:

```c
/* Intentionally empty. This target exists only to expose zest_core.h as the
   `CZestCore` Clang module; the symbols come from libzest-core.a, linked by the
   Zest executable target (see Package.swift linkerSettings). */
```

- [ ] **Step 2: Write Package.swift**

Create `Package.swift` at the repo root:

```swift
// swift-tools-version:5.9
import PackageDescription

// libzest-core.a is produced by `zig build core` into ./zig-out/lib.
// swift build runs from the repo root, so this -L path is relative to root.
let zigLibDir = "zig-out/lib"

let package = Package(
    name: "Zest",
    platforms: [.macOS(.v13)],
    targets: [
        // C module exposing zest_core.h (header-only; impl is the Zig static lib).
        .target(name: "CZestCore"),

        .executableTarget(
            name: "Zest",
            dependencies: ["CZestCore"],
            linkerSettings: [
                .unsafeFlags(["-L\(zigLibDir)", "-lzest-core"]),
                .linkedLibrary("c"),
            ]
        ),

        .testTarget(
            name: "ZestTests",
            dependencies: ["Zest", "CZestCore"],
            linkerSettings: [
                .unsafeFlags(["-L\(zigLibDir)", "-lzest-core"]),
            ]
        ),
    ]
)
```

> Note: SwiftPM auto-generates the `CZestCore` Clang module from
> `Sources/CZestCore/include/` (default public-headers path), so `import CZestCore`
> exposes `zest_open` etc. If `swift build` later can't find `-lzest-core`, replace
> `zigLibDir` with an absolute path to `<repo>/zig-out/lib`.

- [ ] **Step 3: Add a placeholder executable source so the package resolves**

Create `Sources/Zest/App/main.swift` (replaced in Task 7 — minimal so `swift build` resolves now):

```swift
print("Zest bootstrap")
```

- [ ] **Step 4: Build the library, then the package**

Run: `zig build core && swift build`
Expected: `swift build` succeeds and links against `libzest-core.a` (no "Compiling…" errors, no undefined symbols). It produces `.build/debug/Zest`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/CZestCore/empty.c Sources/Zest/App/main.swift
git commit -m "build(swift): SwiftPM package linking libzest-core.a via CZestCore module"
```

---

## Task 5: Swift `ZestCore` wrapper (mmap + RAII + marshaling)

**Files:**
- Create: `Sources/Zest/Core/ZestCore.swift`
- Create: `Sources/ZestTests/ZestCoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Sources/ZestTests/ZestCoreTests.swift`:

```swift
import XCTest
@testable import Zest

final class ZestCoreTests: XCTestCase {
    // Resolve the real index the same way config.zig does.
    private var indexPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("zest/index.zst").path
    }

    func testOpenAndQueryRealIndex() throws {
        guard FileManager.default.fileExists(atPath: indexPath) else {
            throw XCTSkip("No index at \(indexPath); run `zest-indexer --full-scan ~` first.")
        }
        let core = try XCTUnwrap(ZestCore(indexPath: indexPath))
        // A bare global query with no scope/depth returns empty by design; scope
        // the home dir at depth 1 (a folder listing) to get real rows.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rows = core.query("", scope: home, maxDepth: 1, maxResults: 5_000)
        XCTAssertFalse(rows.isEmpty, "home folder listing should return entries")
        XCTAssertFalse(rows[0].name.isEmpty)
    }

    func testOpenMissingFileReturnsNil() {
        XCTAssertNil(ZestCore(indexPath: "/nonexistent/zest/index.zst"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build core && swift test --filter ZestCoreTests`
Expected: FAIL — `ZestCore` is undefined ("cannot find 'ZestCore' in scope").

- [ ] **Step 3: Write the wrapper**

Create `Sources/Zest/Core/ZestCore.swift`:

```swift
import Foundation
import CZestCore

/// Safe Swift veneer over the Zig C ABI. Owns the index mmap for the Core's
/// lifetime; the rest of the app never touches raw C.
final class ZestCore {
    private let handle: OpaquePointer
    private let mapBase: UnsafeMutableRawPointer
    private let mapSize: Int

    struct Row {
        let name: String
        let dirPath: String
        let size: UInt64
        let mtime: Int64
        let kind: UInt8
        let category: UInt8
    }

    init?(indexPath: String) {
        let fd = open(indexPath, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
        let size = Int(st.st_size)

        guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              base != MAP_FAILED else { return nil }

        guard let h = zest_open(base.assumingMemoryBound(to: UInt8.self), size) else {
            munmap(base, size)
            return nil
        }
        self.handle = h
        self.mapBase = base
        self.mapSize = size
    }

    deinit {
        zest_close(handle)
        munmap(mapBase, mapSize)
    }

    /// Synchronous (runs in Zig); callers dispatch off-main in later phases.
    func query(_ q: String, scope: String = "/", maxDepth: UInt32 = .max, maxResults: UInt32 = 100_000) -> [Row] {
        guard let qp = zest_query(handle, q, scope, maxDepth, maxResults) else { return [] }
        defer { zest_query_free(qp) }                   // borrow ends here
        let n = zest_query_count(qp)
        var rows: [Row] = []
        rows.reserveCapacity(n)
        for i in 0..<n {
            let r = zest_query_row(qp, i)
            rows.append(Row(
                name: Self.str(r.name),
                dirPath: Self.str(r.dir_path),
                size: r.size, mtime: r.mtime, kind: r.kind, category: r.category
            ))                                          // COPY at the boundary
        }
        return rows
    }

    private static func str(_ s: ZestStr) -> String {
        guard let p = s.ptr, s.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: s.len), as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build core && swift test --filter ZestCoreTests`
Expected: PASS (or `testOpenAndQueryRealIndex` SKIPPED with the "No index" message if you haven't built one — `testOpenMissingFileReturnsNil` must still PASS). To get a non-skipped run: `zig-out/bin/zest-indexer --full-scan ~` once, then re-run.

- [ ] **Step 5: Commit**

```bash
git add Sources/Zest/Core/ZestCore.swift Sources/ZestTests/ZestCoreTests.swift
git commit -m "feat(swift): ZestCore mmap wrapper + FFI integration test"
```

---

## Task 6: Design tokens + accent derivation

**Files:**
- Create: `Sources/Zest/Design/Theme.swift`
- Create: `Sources/ZestTests/ThemeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Sources/ZestTests/ThemeTests.swift`:

```swift
import XCTest
import AppKit
@testable import Zest

final class ThemeTests: XCTestCase {
    func testLightAccentGetsDarkOnAccentText() {
        // Lime is bright → text drawn on it must be near-black.
        let lime = NSColor(srgbRed: 0.72, green: 1.0, blue: 0.235, alpha: 1)
        XCTAssertTrue(Theme.relativeLuminance(lime) > 0.6)
        XCTAssertEqual(Theme.onAccent(forBase: lime, theme: .dark), Theme.nearBlack)
    }

    func testBlueAccentGetsWhiteOnAccentText() {
        let blue = NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
        XCTAssertTrue(Theme.relativeLuminance(blue) < 0.6)
        XCTAssertEqual(Theme.onAccent(forBase: blue, theme: .dark), .white)
    }

    func testLightThemeAlwaysUsesWhiteOnAccent() {
        // Light theme darkens the effective accent, so on-accent is always white.
        let lime = NSColor(srgbRed: 0.72, green: 1.0, blue: 0.235, alpha: 1)
        XCTAssertEqual(Theme.onAccent(forBase: lime, theme: .light), .white)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ThemeTests`
Expected: FAIL — `Theme` is undefined.

- [ ] **Step 3: Write the tokens + derivation**

Create `Sources/Zest/Design/Theme.swift`:

```swift
import AppKit

enum Appearance { case dark, light }

/// Design tokens (Ink graphite base) + accent derivation. Mirrors the prototype:
/// one chosen hue (base); the effective accent is theme-shifted; the family is
/// derived from the effective accent. See spec §4.
enum Theme {
    // Ink neutrals (dark)
    static let background      = srgb(0x0F, 0x11, 0x15)
    static let panel           = srgb(0x16, 0x19, 0x1E)
    static let panelElevated   = srgb(0x1F, 0x24, 0x2A)
    static let hover           = srgb(0x20, 0x25, 0x2B)
    static let border          = srgb(0x27, 0x2C, 0x33)
    static let text            = srgb(0xE9, 0xEC, 0xEF)
    static let textSecondary   = srgb(0x86, 0x8E, 0x99)
    static let textTertiary    = srgb(0x56, 0x5E, 0x68)

    static let nearBlack       = srgb(0x0C, 0x0E, 0x12)
    static let defaultAccentBase = srgb(0xB8, 0xFF, 0x3C) // lime

    // Category colors (theme-independent)
    static let catFolder = srgb(0x6E, 0x9B, 0xE0)
    static let catCode   = srgb(0x46, 0xC2, 0x6A)
    // … remaining categories added in P2 …

    struct Accent {
        let accent: NSColor      // effective
        let accentHi: NSColor
        let accentSoft: NSColor
        let accentLine: NSColor
        let glow: NSColor
        let onAccent: NSColor
    }

    /// Effective accent + derived family for a chosen base hue and theme.
    static func deriveAccent(base: NSColor, theme: Appearance) -> Accent {
        let effective = (theme == .light)
            ? base.blended(withFraction: 0.42, of: .black) ?? base   // darken on light
            : base
        return Accent(
            accent: effective,
            accentHi: effective.blended(withFraction: 0.22, of: .white) ?? effective,
            accentSoft: effective.withAlphaComponent(0.13),
            accentLine: effective.withAlphaComponent(0.55),
            glow: effective.withAlphaComponent(0.16),
            onAccent: onAccent(forBase: base, theme: theme)
        )
    }

    static func onAccent(forBase base: NSColor, theme: Appearance) -> NSColor {
        if theme == .light { return .white }            // darkened effective accent
        return relativeLuminance(base) > 0.6 ? nearBlack : .white
    }

    static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }

    private static func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ThemeTests`
Expected: PASS (all three cases). `nearBlack` is compared by identity of the returned token; the `onAccent` branches return exactly `Theme.nearBlack` / `.white`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Zest/Design/Theme.swift Sources/ZestTests/ThemeTests.swift
git commit -m "feat(swift): Theme tokens + theme-aware accent derivation"
```

---

## Task 7: Minimal window showing the live query count (smoke)

**Files:**
- Modify: `Sources/Zest/App/main.swift`
- Create: `Sources/Zest/App/AppDelegate.swift`

- [ ] **Step 1: Write the AppDelegate**

Create `Sources/Zest/App/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let count = liveCount()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Zest — FFI smoke"
        window.backgroundColor = Theme.background
        window.center()

        let label = NSTextField(labelWithString: count)
        label.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        label.textColor = Theme.text
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the real index and run a home-folder listing; report the count.
    private func liveCount() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let indexPath = appSupport.appendingPathComponent("zest/index.zst").path
        guard let core = ZestCore(indexPath: indexPath) else {
            return "No index — run zest-indexer --full-scan ~"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rows = core.query("", scope: home, maxDepth: 1, maxResults: 100_000)
        let line = "Zig core OK · \(rows.count) entries in \(home)"
        print(line)                                  // also prove it on stdout
        return line
    }
}
```

- [ ] **Step 2: Replace main.swift with the NSApplication bootstrap**

Replace `Sources/Zest/App/main.swift` with:

```swift
import AppKit

// Non-bundled executable (preserves `zest /path` ergonomics, like today's app).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // show in Dock / accept focus when unbundled
app.run()
```

- [ ] **Step 3: Build and run the smoke window**

Run: `zig build core && swift run Zest`
Expected: a dark window titled "Zest — FFI smoke" appears centered, showing either `Zig core OK · <N> entries in /Users/<you>` (N > 0) or the "No index" hint; the same line is printed to the terminal. Quitting the app (⌘Q) returns to the shell.

- [ ] **Step 4: Commit**

```bash
git add Sources/Zest/App/main.swift Sources/Zest/App/AppDelegate.swift
git commit -m "feat(swift): minimal window proving the Swift↔Zig query path"
```

---

## Task 8: justfile recipes

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Add recipes**

Append to `justfile`:

```make
# --- Swift UI (Phase 0+) ---

# Build the Zig C-ABI core the Swift app links against.
core:
    zig build core

# Build the Swift app (depends on the core lib being built first).
app: core
    swift build

# Build everything: Zig binaries + core lib + Swift app.
build-all: core
    zig build
    swift build

# Run the Swift app.
run-app: core
    swift run Zest

# Run Swift tests (FFI + theme).
test-swift: core
    swift test
```

- [ ] **Step 2: Verify the recipes work**

Run: `just build-all && just test-swift`
Expected: Zig builds (both binaries + lib), Swift builds, and Swift tests pass (the real-index test may SKIP if no index — that's success).

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "build: justfile recipes for the Zig core lib + Swift app"
```

---

## Task 9: End-to-end verification

- [ ] **Step 1: Full clean verification**

Run, in order:
```bash
zig build test          # all Zig tests pass (incl. the new zest_open test)
just build-all          # Zig binaries + libzest-core.a + Swift app all build
just test-swift         # Swift FFI + theme tests pass (real-index test passes if an index exists)
zig-out/bin/zest-indexer --full-scan ~   # (if needed) build an index, then:
just run-app            # window shows "Zig core OK · <N> entries…", same on stdout
```
Expected: every command succeeds; the window reports a non-zero entry count against the real index.

- [ ] **Step 2: Tag the milestone**

```bash
git commit --allow-empty -m "chore: Phase 0 (FFI foundation) complete — Swift app runs real Zig queries"
```

---

## Self-review notes (for the author)

- **Spec coverage (P0, spec §12):** C ABI core ✓ (Task 1, 3) · `libzest-core.a` ✓ (Task 2) · SwiftPM links it ✓ (Task 4) · Swift window runs a real query ✓ (Task 7) · `Theme` tokens + derivation ✓ (Task 6) · justfile orchestration ✓ (Task 8). The FFI ownership rule (Swift owns the mmap, Zig borrows, copy at boundary) is realized in Tasks 1 + 5.
- **Deferred to later plans (intentional):** snapshot ref-counting / `zest_reload_if_changed` (P3, only needed once the daemon updates the index live) · histogram / pins / filters / folder-color FFI (P4) · all real UI components (P1–P2) · off-main threading (P3). Strings cross as `{ptr,len}` and are copied immediately, so the simpler "Swift owns one mmap" model is safe for P0.
- **Type consistency:** `ZestRow`/`ZestStr` fields match across `zest_core.zig`, `zest_core.h`, and `ZestCore.Row`. `zest_query` arg order (`query, scope_root, max_depth, max_results`) is identical in all three. `Theme.onAccent(forBase:theme:)` / `relativeLuminance(_:)` / `nearBlack` names match between `Theme.swift` and `ThemeTests.swift`.
- **Known config to confirm at execution:** the `-Lzig-out/lib` relative path in `Package.swift` (Task 4 note) and the `b.addLibrary(.linkage = .static)` signature against the installed Zig 0.16 (verified shape against `build.zig`'s existing `addExecutable` usage).
```
