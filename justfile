# Unified Zig and Swift commands.

_default:
    @just --list

# Build all binaries and relink the Swift app with the ReleaseFast core.
build:
    zig build
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    swift build

# Run Zig and Swift tests with the ReleaseFast core.
test:
    zig build test
    zig build core -Doptimize=ReleaseFast
    touch Sources/CZestCore/empty.c
    swift test

# Benchmark the C ABI against the real index.
bench-capi:
    zig build core -Doptimize=ReleaseFast --prefix zig-out/release
    mkdir -p zig-out/bin
    zig build-exe benchmarks/bench_capi.zig zig-out/release/lib/libzest-core.a -lc -OReleaseFast -femit-bin=zig-out/bin/bench-capi
    ./zig-out/bin/bench-capi

# Benchmark search against a deterministic in-memory corpus.
bench-search:
    mkdir -p zig-out/bin
    zig build-exe -OReleaseFast --dep zest -Mroot=benchmarks/bench_search.zig -OReleaseFast -Mzest=src/engine.zig -lc -femit-bin=zig-out/bin/bench-search
    ./zig-out/bin/bench-search

# Format all sources: `zig fmt` over src/ + `swift-format` over Sources/.
format:
    zig fmt src
    swift-format format --in-place --recursive Sources

# Compile-check and lint Zig and Swift sources.
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
run: build
    swift run Zest

# Build + run the Swift app in Release (faster folder switching).
run-fast: build
    swift run -c release Zest

# Build the search index, then run a full scan of $HOME.
index:
    zig build indexer -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer --full-scan ~

# Install the indexer as a launchd background daemon.
install-daemon:
    zig build indexer -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer install

# Uninstall the launchd daemon.
uninstall-daemon:
    ./zig-out/bin/zest-indexer uninstall

# Open the index data folder in Finder.
open-index:
    open ~/Library/Application\ Support/zest/

# Wipe the generated index while preserving user data.
wipe-index:
    rm -f ~/Library/Application\ Support/zest/index.zst

# Remove build output and caches (Zig + Swift PM).
clean:
    rm -rf zig-out .zig-cache .build
