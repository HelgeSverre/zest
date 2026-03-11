# Build both binaries
build:
    zig build

# Run all tests
test:
    zig build test

# Build the search index (scans home directory)
index:
    zig build
    ./zig-out/bin/zest-indexer --full-scan ~

# Launch the app (current directory)
run *args='.':
    zig build
    ./zig-out/bin/zest {{args}}

# Build index + launch app
dev:
    zig build
    ./zig-out/bin/zest-indexer --full-scan ~
    ./zig-out/bin/zest .

# Install the background indexer daemon (launchd)
install-daemon:
    zig build
    ./zig-out/bin/zest-indexer install

# Uninstall the background indexer daemon
uninstall-daemon:
    ./zig-out/bin/zest-indexer uninstall

# Open the index data folder in Finder
open-index:
    open ~/Library/Application\ Support/zest/

# Run search benchmark
bench query:
    zig build
    ./zig-out/bin/zest --benchmark "{{query}}"
