#!/usr/bin/env bash
# Remove an installed Zest.app the way a user would: quit, unregister the
# packaged indexer, delete the app, forget the installer receipt.
# Keeps the index and preferences (see scripts/nuke.sh for a full wipe).
set -uo pipefail
app=/Applications/Zest.app
pkill -x Zest 2>/dev/null || true
if [[ -x "$app/Contents/MacOS/Zest" ]]; then
  "$app/Contents/MacOS/Zest" --indexer-uninstall >/dev/null || echo 'warning: could not unregister the bundled indexer' >&2
fi
launchctl bootout "gui/$(id -u)/dev.zest.app.indexer" 2>/dev/null || true
if [[ -e "$app" ]]; then
  # The installer package writes the app as root.
  rm -rf "$app" 2>/dev/null || sudo rm -rf "$app"
fi
sudo pkgutil --forget dev.zest.app >/dev/null 2>&1 || true
echo "Removed $app (index and preferences kept)."
