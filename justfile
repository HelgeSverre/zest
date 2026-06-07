# Zest — unified commands.
# Every recipe runs against both Zig and Swift at once; no language split.

_default:
    @just --list

# Build everything: Zig binaries (zest, zest-indexer) + static lib (libzest-core.a) + Swift app.
build:
    zig build
    swift build

# Run all tests: Zig unit tests + Swift unit tests.
test:
    zig build test
    swift test

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

# Remove build output and caches (Zig + Swift PM).
clean:
    rm -rf zig-out .zig-cache .build
