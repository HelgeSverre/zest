#!/usr/bin/env bash
# Remove an installed Zest.app the way a user would: quit, unregister the
# packaged indexer, delete the app, forget the installer receipt.
# Keeps the index and preferences (see scripts/nuke.sh for a full wipe).
set -uo pipefail
app=/Applications/Zest.app
pkill -x Zest 2>/dev/null || true
# Builds before 0.1.2 ignore unknown flags and open the GUI instead, so check
# the usage text is actually compiled into the installed binary first.
if [[ -x "$app/Contents/MacOS/Zest" ]] && grep -q -- '--indexer-uninstall' "$app/Contents/MacOS/Zest"; then
  "$app/Contents/MacOS/Zest" --indexer-uninstall >/dev/null || echo 'warning: could not unregister the bundled indexer' >&2
elif [[ -e "$app" ]]; then
  echo 'note: installed Zest predates --indexer-uninstall; only booting the agent out for this session' >&2
fi
launchctl bootout "gui/$(id -u)/dev.zest.app.indexer" 2>/dev/null || true
if [[ -e "$app" ]]; then
  # The installer package writes the app as root, so remove it with whichever
  # privilege escalation is available: a TTY sudo, else a graphical prompt.
  rm -rf "$app" 2>/dev/null ||
    sudo rm -rf "$app" 2>/dev/null ||
    osascript -e 'do shell script "rm -rf /Applications/Zest.app" with administrator privileges' >/dev/null 2>&1 || true
fi
sudo pkgutil --forget dev.zest.app >/dev/null 2>&1 ||
  osascript -e 'do shell script "/usr/sbin/pkgutil --forget dev.zest.app" with administrator privileges' >/dev/null 2>&1 || true
# Never claim success we did not achieve: the caller may be a clean-slate test.
if [[ -e "$app" ]]; then
  echo "error: $app still present; remove it manually (it is owned by root)." >&2
  exit 1
fi
echo "Removed $app (index and preferences kept)."
