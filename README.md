# Zest

![Zig](https://img.shields.io/badge/lang-Zig-F7A41D?style=flat-square&logo=zig)
![macOS](https://img.shields.io/badge/platform-macOS-000000?style=flat-square&logo=apple)
![MIT License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

A minimal, fast Finder replacement for macOS built in Zig.

```
zest .
zest /path/to/directory
```

## Features

- **Blazing-fast file search** — Custom mmap'd binary index with SIMD substring search. Sub-5ms queries across 1M+ files.
- **Category filtering** — Filter by file type (images, documents, code, audio, video, etc.) using pre-computed Roaring bitmaps.
- **Pinnable sidebar** — Quick access to frequently used directories. Persisted across sessions.
- **Background indexer** — `zest-indexer` daemon watches your home directory via FSEvents, keeping the index up to date automatically.
- **Dark theme** — JetBrains Darcula color scheme, forced dark mode regardless of system appearance.

## Requirements

- macOS (Apple Silicon or Intel)
- Zig 0.15.2+

## Building

```sh
zig build
```

This produces two binaries in `zig-out/bin/`:
- `zest` — the GUI/CLI application
- `zest-indexer` — the background indexing daemon

## Running

```sh
# Open current directory
zig build run -- .

# Open a specific path
zig build run -- ~/Documents
```

## Testing

```sh
zig build test
```

All core and index tests use an in-memory fake filesystem — no real FS or UI required.

## Architecture

```
zest (GUI)  ─── mmap read-only ──┐
zest (GUI)  ─── mmap read-only ──┤── ~/Library/Application Support/zest/index.zst
zest (GUI)  ─── mmap read-only ──┘
                                      ▲
                                      │ atomic rename
                                      │
                               zest-indexer (launchd agent)
                                 - Watches $HOME via FSEvents
                                 - Builds index → atomic swap
                                 - Runs as launchd background agent
```

The index uses a columnar binary format optimized for SIMD scanning. Multiple `zest` instances share a single read-only mmap'd index. The indexer rebuilds atomically so readers never see partial state.

## Project Structure

```
src/
├── main.zig              # CLI entry point
├── app.zig               # Application controller
├── core/
│   ├── types.zig          # FileEntry, FileKind, FileCategory, etc.
│   ├── fs_provider.zig    # FileSystemProvider vtable interface
│   ├── real_fs.zig        # Real filesystem implementation
│   ├── fake_fs.zig        # In-memory fake for tests
│   ├── file_types.zig     # Extension → category mapping
│   ├── navigator.zig      # Path navigation with back/forward/up
│   └── pins.zig           # Pin manager (JSON persistence)
├── index/
│   ├── format.zig         # Binary index format
│   ├── builder.zig        # Builds index from filesystem scan
│   ├── reader.zig         # Mmap'd read-only index access
│   ├── search.zig         # SIMD substring search
│   ├── bitmap.zig         # Roaring bitmap for category filtering
│   ├── fsevents.zig       # FSEvents C interop
│   └── daemon.zig         # Background indexer (zest-indexer)
├── ui/
│   ├── theme.zig          # Darcula color constants
│   └── appkit.zig         # Native AppKit UI via zig-objc
└── config/
    └── config.zig         # Paths, defaults, exclude patterns
```

## License

MIT
