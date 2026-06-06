_default:
    @just --list

# Build both binaries
build:
    zig build

# Run all tests
test:
    zig build test

# Build the search index (scans home directory)
index:
    zig build indexer -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer --full-scan ~

# Launch the app, Debug (fast to compile; folder switching ~80ms)
run *args='.':
    zig build
    ./zig-out/bin/zest {{args}}

# Launch the app, ReleaseFast (slower to compile; folder switching ~6ms)
run-fast *args='.':
    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/zest {{args}}

# Build everything (ReleaseFast) + index + launch app
dev:
    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer --full-scan ~
    ./zig-out/bin/zest .

# Install the background indexer daemon (launchd)
install-daemon:
    zig build indexer -Doptimize=ReleaseFast
    ./zig-out/bin/zest-indexer install

# Uninstall the background indexer daemon
uninstall-daemon:
    ./zig-out/bin/zest-indexer uninstall

# Open the index data folder in Finder
open-index:
    open ~/Library/Application\ Support/zest/

# Run search benchmark (ReleaseFast)
bench query:
    zig build -Doptimize=ReleaseFast
    ./zig-out/bin/zest --benchmark "{{query}}"

# Remove build output and local cache
clean:
    rm -rf zig-out .zig-cache
