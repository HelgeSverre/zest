#!/usr/bin/env bash
# Build a Universal app; no installation, registration, signing secrets or uploads.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in zig swift jq lipo plutil iconutil node; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
version="$(jq -er '.version' release.json)"
build_number="$(jq -er '.build' release.json)"
minimum_macos="$(jq -er '.minimumSystemVersion' release.json)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[1-9][0-9]*$ && "$minimum_macos" == 14.0 ]] || exit 1
export MACOSX_DEPLOYMENT_TARGET="$minimum_macos"
app_binaries=()
helper_binaries=()
query_binaries=()
for arch in arm64 x86_64; do
  zig_arch="$arch"
  [[ "$arch" != arm64 ]] || zig_arch=aarch64
  prefix="$PWD/zig-out/release-$arch"
  zig build core indexer query -Doptimize=ReleaseFast "-Dtarget=$zig_arch-macos.$minimum_macos" -Dcpu=baseline --prefix "$prefix"
  # SwiftPM doesn't track the external Zig archive as a link input.
  touch Sources/CZestCore/empty.c
  export ZEST_CORE_LIB_DIR="$prefix/lib"
  swift_args=(--configuration release --arch "$arch" --scratch-path ".build/release-$arch" --disable-automatic-resolution)
  swift build "${swift_args[@]}" --product Zest
  bin="$(swift build "${swift_args[@]}" --show-bin-path)"
  app_binaries+=("$bin/Zest")
  helper_binaries+=("$prefix/bin/zest-indexer")
  query_binaries+=("$prefix/bin/zest-query")
done
mkdir -p dist
stage="$(mktemp -d "$PWD/dist/package.XXXXXX")"
app="$stage/Zest.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
lipo -create "${app_binaries[@]}" -output "$app/Contents/MacOS/Zest"
lipo -create "${helper_binaries[@]}" -output "$app/Contents/Helpers/zest-indexer"
lipo -create "${query_binaries[@]}" -output "$app/Contents/Helpers/zest-query"
cp macos/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
cp macos/dev.zest.app.indexer.plist "$app/Contents/Library/LaunchAgents/"
swift scripts/make-icon.swift "$stage"
iconutil -c icns "$stage/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp docs/RELEASE.md "$app/Contents/Resources/Installation and Removal.txt"
notices="$app/Contents/Resources/ThirdPartyNotices.txt"
for license in LICENSE Vendor/HighlightQueries/LICENSE-* Vendor/TreeSitterSema/LICENSE \
  .build/release-arm64/checkouts/swift-tree-sitter/LICENSE \
  .build/release-arm64/checkouts/tree-sitter/LICENSE \
  .build/release-arm64/checkouts/tree-sitter/lib/src/unicode/LICENSE \
  .build/release-arm64/checkouts/tree-sitter-json/LICENSE \
  .build/release-arm64/checkouts/tree-sitter-markdown/LICENSE; do
  printf '\n%s\n\n' "$license" >> "$notices"
  cat "$license" >> "$notices"
done
for helper in zest-indexer zest-query; do
  codesign --force --sign - --identifier "dev.zest.app.$helper" "$app/Contents/Helpers/$helper"
done
codesign --force --sign - "$app"
node scripts/verify-release.mjs "$app"
# Preserve older candidates rather than recursively deleting build output.
if [[ -e dist/Zest.app ]]; then mv dist/Zest.app "$stage/Previous-Zest.app"; fi
mv "$app" dist/Zest.app
echo "Built dist/Zest.app (Universal, ad-hoc signed, local use only)"
