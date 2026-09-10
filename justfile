# Unified Zig and Swift commands.

_default:
    @just --list

# Build and verify a local-only Universal app.
[group('release')]
package:
    bash scripts/package.sh

# Build a local-only installer package.
[group('release')]
pkg:
    bash .github/scripts/package-macos-pkg.sh --unsigned

# Build a Developer ID signed candidate (not notarized, not published).
[group('release')]
package-signed:
    bash .github/scripts/package-macos-pkg.sh --signed-only

# Explicitly submit the signed PKG to Apple, staple, and verify it. No publishing.
[group('release')]
package-notarized:
    bash .github/scripts/package-macos-pkg.sh

# Use existing local identities and the ignored signing/ folder; submits to Apple.
[group('release')]
pkg-local:
    bash scripts/package-local-signed.sh

# Build all binaries and relink the Swift app with the ReleaseFast core.
[group('dev')]
build:
    zig build
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    swift build

# Format all sources: `zig fmt` over src/ + `swift-format` over Sources/.
[group('dev')]
format:
    zig fmt src
    swift-format format --in-place --recursive Sources

# Compile-check and lint Zig and Swift sources.
[group('dev')]
lint:
    @echo "→ zig build (compile check)"
    zig build
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    @echo "→ swift build (compile check)"
    swift build
    @echo "→ swift-format lint"
    swift-format lint --recursive Sources
    @echo "→ swiftlint"
    swiftlint lint

# Build + run the Swift app in Debug.
[group('dev')]
run: build
    swift run Zest

# Build + run the Swift app in Release (faster folder switching).
[group('dev')]
run-fast: build
    swift run -c release Zest

# Run Zig and Swift tests with the ReleaseFast core.
[group('test')]
test:
    zig build test
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    swift test

# Benchmark the C ABI against the real index.
[group('test')]
bench-capi:
    zig build core -Doptimize=ReleaseFast --prefix zig-out/release
    mkdir -p zig-out/bin
    zig build-exe benchmarks/bench_capi.zig zig-out/release/lib/libzest-core.a -lc -OReleaseFast -femit-bin=zig-out/bin/bench-capi
    ./zig-out/bin/bench-capi

# Benchmark search against a deterministic in-memory corpus.
[group('test')]
bench-search:
    mkdir -p zig-out/bin
    zig build-exe -OReleaseFast --dep zest -Mroot=benchmarks/bench_search.zig -OReleaseFast -Mzest=src/engine.zig -lc -femit-bin=zig-out/bin/bench-search
    ./zig-out/bin/bench-search

# Exercise live FSEvents and failure recovery in an isolated temporary home.
[group('test')]
test-daemon:
    zig build indexer query -Doptimize=ReleaseFast
    node scripts/test-daemon.mjs

# Build the search index, then run a full scan of $HOME.
[group('index')]
index:
    zig build indexer -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer --full-scan ~

# Build the read-only index query CLI.
[group('index')]
query-build:
    zig build query -Doptimize=ReleaseFast

# Install the indexer as a launchd background daemon.
[group('index')]
install-daemon:
    zig build indexer -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer install

# Uninstall the launchd daemon.
[group('index')]
uninstall-daemon:
    ./zig-out/bin/zest-indexer uninstall

# Open the index data folder in Finder.
[group('index')]
open-index:
    open ~/Library/Application\ Support/zest/

# Wipe the generated index while preserving user data.
[group('index')]
wipe-index:
    rm -f ~/Library/Application\ Support/zest/index.zst

# Remove build output and caches (Zig + Swift PM).
[group('index')]
clean:
    rm -rf zig-out .zig-cache .build
