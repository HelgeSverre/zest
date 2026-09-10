#!/usr/bin/env bash
# Adapted from Sourcefour's release workflow. Does not publish or install.
set -euo pipefail
cd "$(dirname "$0")/../.."
mode=notarized
case "${1:-}" in
  --unsigned) mode=unsigned ;;
  --signed-only) mode=signed ;;
  '') ;;
  *) echo 'Usage: package-macos-pkg.sh [--unsigned|--signed-only]' >&2; exit 2 ;;
esac
if [[ "$mode" != unsigned ]]; then
  : "${APPLE_APPLICATION_SIGNING_IDENTITY:?Set Developer ID Application identity}"
  : "${APPLE_INSTALLER_SIGNING_IDENTITY:?Set Developer ID Installer identity}"
  : "${APPLE_TEAM_ID:?Set Apple team ID}"
fi
if [[ "$mode" == notarized ]]; then
  : "${APPLE_NOTARY_KEY_PATH:?Set path to App Store Connect team API .p8 key}"
  : "${APPLE_NOTARY_KEY_ID:?Set API Key ID}"
  : "${APPLE_NOTARY_ISSUER_ID:?Set team API Issuer ID}"
  test -f "$APPLE_NOTARY_KEY_PATH"
fi
bash scripts/package.sh
app="$PWD/dist/Zest.app"
output="$(mktemp -d "$PWD/dist/installer.XXXXXX")"
package="$output/zest-universal-apple-darwin.pkg"
keychain=()
if [[ -n "${APPLE_SIGNING_KEYCHAIN:-}" ]]; then keychain=(--keychain "$APPLE_SIGNING_KEYCHAIN"); fi
if [[ "$mode" == unsigned ]]; then
  package="$output/zest-universal-apple-darwin-LOCAL-ONLY.pkg"
  productbuild --component "$app" /Applications "$package"
else
  for executable in "$app/Contents/Helpers/zest-indexer" "$app/Contents/Helpers/zest-query" "$app/Contents/MacOS/Zest"; do
    codesign --force --sign "$APPLE_APPLICATION_SIGNING_IDENTITY" ${keychain[@]+"${keychain[@]}"} --options runtime --timestamp "$executable"
  done
  codesign --force --sign "$APPLE_APPLICATION_SIGNING_IDENTITY" ${keychain[@]+"${keychain[@]}"} --options runtime --timestamp "$app"
  node scripts/verify-release.mjs "$app"
  details="$(codesign --display --verbose=4 "$app" 2>&1)"
  [[ "$details" == *"TeamIdentifier=$APPLE_TEAM_ID"* ]] || { echo 'Wrong signing team' >&2; exit 1; }
  productbuild --sign "$APPLE_INSTALLER_SIGNING_IDENTITY" ${keychain[@]+"${keychain[@]}"} --timestamp --component "$app" /Applications "$package"
  pkgutil --check-signature "$package"
fi
if [[ "$mode" == notarized ]]; then
  notary=(--key "$APPLE_NOTARY_KEY_PATH" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID")
  result="$output/notarization-submit.json"
  if ! xcrun notarytool submit "$package" "${notary[@]}" --wait --timeout "${APPLE_NOTARY_TIMEOUT:-45m}" --output-format json > "$result"; then
    echo 'Notarization submission failed; inspect diagnostics.' >&2
  fi
  status="$(jq -r '.status // empty' "$result")"
  submission="$(jq -r '.id // empty' "$result")"
  if [[ "$status" != Accepted ]]; then
    if [[ -n "$submission" ]]; then xcrun notarytool log "$submission" "${notary[@]}" "$output/notarization-log.json" || true; fi
    echo "Notarization not accepted: $status. Diagnostics: $output" >&2
    exit 1
  fi
  xcrun stapler staple "$package"
  xcrun stapler validate "$package"
  pkgutil --check-signature "$package"
  spctl --assess --type install --verbose=4 "$package"
fi
pkgutil --payload-files "$package" | grep -Fx './Zest.app/Contents/MacOS/Zest' >/dev/null
(cd "$output" && shasum -a 256 "$(basename "$package")" > "$(basename "$package").sha256")
jq -n --arg commit "$(git rev-parse HEAD)" --arg mode "$mode" --arg dirty "$(git status --porcelain)" \
  '{commit: $commit, mode: $mode, dirty: ($dirty != "")}' > "$output/build-manifest.json"
echo "Created $package"
[[ "$mode" == notarized ]] || echo 'NOT FOR PUBLIC DISTRIBUTION: this package is not notarized.'
