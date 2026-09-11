#!/usr/bin/env bash
# Clean slate: packaged app, development daemon, every dev.zest.* launchd job,
# the index and user data, and the app's defaults. For fresh-install testing.
set -uo pipefail
cd "$(dirname "$0")/.."
uid="$(id -u)"
bash scripts/uninstall.sh
[[ -x zig-out/bin/zest-indexer ]] && ./zig-out/bin/zest-indexer uninstall >/dev/null 2>&1
# Anything still loaded: dev daemon, stale test jobs, Full Disk Access probes.
launchctl print "gui/$uid" | grep -o 'dev\.zest\.[A-Za-z0-9.-]*' | sort -u \
  | while read -r job; do launchctl bootout "gui/$uid/$job" 2>/dev/null; done
rm -f "$HOME"/Library/LaunchAgents/dev.zest.*.plist
rm -rf "$HOME/Library/Application Support/zest"
defaults delete dev.zest.app >/dev/null 2>&1
rm -f "$HOME"/Library/Preferences/dev.zest.*.plist
launchctl list 2>/dev/null | grep -q 'dev\.zest' && echo 'warning: a dev.zest job is still loaded' >&2
echo 'Zest wiped: app, launchd jobs, index, user data, preferences.'
