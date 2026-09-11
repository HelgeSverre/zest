# Zig engine + Swift app.

_default:
    @just --list

# ── build ────────────────────────────────────────────────────────────────

# Build Zig binaries, ReleaseFast core, and the Swift app.
[group('build')]
build:
    zig build
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    swift build

# Compile-check and lint Zig + Swift.
[group('build')]
lint:
    zig build
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    swift build
    swift-format lint --recursive Sources
    swiftlint lint

# Format Zig + Swift sources.
[group('build')]
format:
    zig fmt src
    swift-format format --in-place --recursive Sources

# Remove Zig and SwiftPM build output.
[group('build')]
clean:
    rm -rf zig-out .zig-cache .build

# Run the app in Debug.
[group('build')]
dev: build
    swift run Zest

# Run the app in Release.
[group('build')]
run: build
    swift run -c release Zest

# ── test ─────────────────────────────────────────────────────────────────

# Zig + Swift unit tests (ReleaseFast core).
[group('test')]
test:
    zig build test
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    swift test

# Live FSEvents + failure recovery in a temp home.
[group('test')]
test-daemon:
    zig build indexer query -Doptimize=ReleaseFast
    node scripts/test-daemon.mjs

# Headless AppKit UI tests (needs an index).
[group('test')]
test-ui:
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    swift test --filter UITests

# ── bench ────────────────────────────────────────────────────────────────

# Benchmark the C ABI against the real index.
[group('bench')]
bench-capi:
    zig build core -Doptimize=ReleaseFast --prefix zig-out/release
    mkdir -p zig-out/bin
    zig build-exe benchmarks/bench_capi.zig zig-out/release/lib/libzest-core.a -lc -OReleaseFast -femit-bin=zig-out/bin/bench-capi
    ./zig-out/bin/bench-capi

# Benchmark search against a synthetic corpus.
[group('bench')]
bench-search:
    mkdir -p zig-out/bin
    zig build-exe -OReleaseFast --dep zest -Mroot=benchmarks/bench_search.zig -OReleaseFast -Mzest=src/engine.zig -lc -femit-bin=zig-out/bin/bench-search
    ./zig-out/bin/bench-search

# Benchmark the Swift UI end to end (needs an index).
[group('bench')]
bench-app: build
    swift build -c release
    ./.build/release/Zest --bench

# ── index ────────────────────────────────────────────────────────────────

# Build the indexer and full-scan $HOME.
[group('index')]
index:
    zig build indexer -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer --full-scan ~

# Open the index folder in Finder.
[group('index')]
index-open:
    open ~/Library/Application\ Support/zest/

# Delete the index (keeps user data).
[group('index')]
index-wipe:
    rm -f ~/Library/Application\ Support/zest/index.zst

# Build the zest-query CLI.
[group('index')]
query-build:
    zig build query -Doptimize=ReleaseFast

# ── daemon ───────────────────────────────────────────────────────────────

# Install the indexer as a launchd agent.
[group('daemon')]
daemon-install:
    zig build indexer -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer install

# Remove the launchd agent.
[group('daemon')]
daemon-uninstall:
    ./zig-out/bin/zest-indexer uninstall

# ── release ──────────────────────────────────────────────────────────────

# Ad-hoc Universal dist/Zest.app (local only).
[group('release')]
app-package:
    bash scripts/package.sh

# Unsigned PKG (local only).
[group('release')]
pkg-unsigned:
    bash .github/scripts/package-macos-pkg.sh --unsigned

# Developer ID signed PKG, not notarized.
[group('release')]
pkg-signed:
    bash .github/scripts/package-macos-pkg.sh --signed-only

# Signed PKG, submitted to Apple, stapled, verified.
[group('release')]
pkg-notarized:
    bash .github/scripts/package-macos-pkg.sh

# Notarized PKG using local identities and the ignored signing/ folder.
[group('release')]
pkg-local:
    bash scripts/package-local-signed.sh

# ── install ──────────────────────────────────────────────────────────────

# Build an unsigned PKG and install it to /Applications like a real release (sudo).
[group('install')]
install:
    bash .github/scripts/package-macos-pkg.sh --unsigned
    sudo installer -pkg "$(ls -t dist/installer.*/zest-universal-apple-darwin-LOCAL-ONLY.pkg | head -1)" -target /
    /Applications/Zest.app/Contents/MacOS/Zest --version

# Quit, unregister the bundled indexer, delete /Applications/Zest.app and its receipt.
[group('install')]
uninstall:
    bash scripts/uninstall.sh

# Clean slate: uninstall + every dev.zest launchd job, the index, user data, and defaults.
[group('install')]
nuke:
    bash scripts/nuke.sh
