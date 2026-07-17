# Zest — unified commands.
# Every recipe runs against both Zig and Swift at once; no language split.

_default:
    @just --list

# Build everything: Zig binaries (zest, zest-indexer) + static lib (libzest-core.a) + Swift app.
# The core lib is rebuilt ReleaseFast last — the Swift app links zig-out/lib, and a
# Debug engine is ~19x slower on real queries (82.8s vs 4.5s for a 1-char search).
build:
    zig build
    zig build core -Doptimize=ReleaseFast
    swift build

# Run all tests: Zig unit tests + Swift unit tests.
# (`zig build test` installs a Debug lib as a side effect; restore ReleaseFast
# before swift test so the Swift suite — and the next `swift run` — use it.)
test:
    zig build test
    zig build core -Doptimize=ReleaseFast
    swift test

# Benchmark the C-ABI engine (zest_query/histogram/ext_breakdown) against the
# real index. Median over 7 samples; see benchmarks/bench_capi.zig.
bench-capi:
    zig build core -Doptimize=ReleaseFast --prefix zig-out/release
    mkdir -p zig-out/bin
    zig build-exe benchmarks/bench_capi.zig zig-out/release/lib/libzest-core.a -lc -OReleaseFast -femit-bin=zig-out/bin/bench-capi
    ./zig-out/bin/bench-capi

# Format all sources: `zig fmt` over src/ + `swift-format` over Sources/.
format:
    zig fmt src
    swift-format format --in-place --recursive Sources

# Lint all sources (zig compile-check + swift compile-check + swift-format + swiftlint).
# Steps: zig build, swift build, swift-format lint --recursive Sources, swiftlint lint.
lint:
    @echo "→ zig build (compile check)"
    zig build
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

# Wipe the generated search index (index.zst). Leaves user data
# (pins.json, folder_colors.json, filters.json) untouched. Rebuild with `just index`.
wipe-index:
    rm -f ~/Library/Application\ Support/zest/index.zst

# Remove build output and caches (Zig + Swift PM).
clean:
    rm -rf zig-out .zig-cache .build
