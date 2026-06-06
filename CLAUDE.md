# CLAUDE.md

## Project Overview

**Zest** is a minimal, fast Finder replacement for macOS built in Zig 0.16.0. CLI: `zest .` or `zest /path` opens a native GUI. macOS only.

Two binaries: `zest` (GUI app) and `zest-indexer` (background daemon).

## Build & Test

```sh
zig build              # Build both binaries
zig build run -- .     # Run zest with current directory
zig build test         # Run all tests
```

## Architecture

- **FileSystemProvider** — vtable interface (`core/fs_provider.zig`). Two impls: `RealFs` (OS) and `FakeFs` (in-memory, for tests).
- **Index** — Custom mmap'd binary format at `~/Library/Application Support/zest/index.zst`. Columnar layout: names, paths (prefix-deduped), metadata, Roaring bitmaps for category/extension filtering.
- **Search** — SIMD substring search over the name column using Zig's `@Vector`. Combined with bitmap intersection for category filtering.
- **Indexer** — Background daemon using FSEvents to watch `$HOME`. Writes to `.tmp` then atomic `rename()`. Readers detect new index via stat polling every ~5s.
- **UI** — Native AppKit via zig-objc. Darcula dark theme. NSSplitView sidebar + NSTableView file list.

## Key Design Decisions

- All tests use `FakeFs` — no real filesystem, no UI in tests.
- Global shared index: one index serves all zest instances via mmap.
- No SQLite/Spotlight dependency. Custom format for sub-10ms query latency.
- Config at `~/.config/zest/config.json`, data at `~/Library/Application Support/zest/`.

## Code Conventions

- Zig 0.16.0 idioms and standard library patterns.
- Filesystem/clock/env/process access goes through the global `Io` handle in `core/runtime.zig` (set once in `main` from `std.process.Init`); use its `readFileAlloc`/`writeFileAbsolute`/`ensureDir`/`getEnvVarOwned`/`nowNanos`/`unixTimestamp` helpers rather than re-deriving the 0.16 `Io` call patterns.
- Vtable interfaces follow the `std.mem.Allocator` pattern (ptr + vtable).
- File type categorization via `StaticStringMap` in `file_types.zig`.
- Tests are embedded in source files (Zig's `test` blocks), listed in `build.zig`.

## Project Structure

```
src/main.zig           — CLI entry, arg parsing
src/app.zig            — App controller (owns Navigator, PinManager, IndexReader)
src/core/              — Types, FS abstraction, navigation, pins, file categorization, runtime (Io handle)
src/index/             — Binary format, builder, mmap reader, SIMD search, bitmaps, FSEvents, daemon
src/ui/                — AppKit UI, Darcula theme
src/config/            — Paths, defaults, exclude patterns
```
