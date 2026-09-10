#!/usr/bin/env bash
# Local convenience wrapper. Reads ignored metadata, never prints key contents.
set -euo pipefail
cd "$(dirname "$0")/.."
export APPLE_APPLICATION_SIGNING_IDENTITY="${APPLE_APPLICATION_SIGNING_IDENTITY:-Developer ID Application: Liseth Solutions AS (9Z2L5FBZS3)}"
export APPLE_INSTALLER_SIGNING_IDENTITY="${APPLE_INSTALLER_SIGNING_IDENTITY:-Developer ID Installer: Liseth Solutions AS (9Z2L5FBZS3)}"
export APPLE_TEAM_ID="${APPLE_TEAM_ID:-9Z2L5FBZS3}"
if [[ -z "${APPLE_NOTARY_KEY_PATH:-}" ]]; then
  shopt -s nullglob
  keys=("$PWD"/signing/AuthKey_*.p8)
  [[ ${#keys[@]} == 1 ]] || { echo 'Set APPLE_NOTARY_KEY_PATH; expected exactly one signing/AuthKey_*.p8.' >&2; exit 1; }
  export APPLE_NOTARY_KEY_PATH="${keys[0]}"
fi
key_name="$(basename "$APPLE_NOTARY_KEY_PATH" .p8)"
export APPLE_NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-${key_name#AuthKey_}}"
if [[ -z "${APPLE_NOTARY_ISSUER_ID:-}" ]]; then
  APPLE_NOTARY_ISSUER_ID="$(tr -d '\r\n' < signing/issuer-uuid.txt)"
  export APPLE_NOTARY_ISSUER_ID
fi
bash .github/scripts/package-macos-pkg.sh "$@"
