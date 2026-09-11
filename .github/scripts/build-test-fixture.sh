#!/usr/bin/env bash
# Shared by regular CI and release gates; no reliance on a runner's real index.
set -euo pipefail
cd "$(dirname "$0")/../.."
# CI: RUNNER_TEMP + GITHUB_ENV are set and the vars are appended there (raw
# KEY=value, GitHub takes the value literally). Local: `eval "$(bash $0)"`.
fixture_directory="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zest-ci.XXXXXX")"
fixture_home="$fixture_directory/home"
fixture_root="$fixture_directory/files"
mkdir -p "$fixture_home/Library/Application Support" \
  "$fixture_root/src" "$fixture_root/docs" "$fixture_root/nested"
printf 'const answer: u8 = 42;\n' > "$fixture_root/main.zig"
printf 'pub fn nested() void {}\n' > "$fixture_root/src/nested.zig"
printf 'fixture image\n' > "$fixture_root/photo.png"
printf 'fixture document\n' > "$fixture_root/report.pdf"
printf 'nested document\n' > "$fixture_root/docs/notes.txt"
printf '# Fixture\n' > "$fixture_root/nested/readme.md"
zig build indexer -Doptimize=ReleaseFast
HOME="$fixture_home" ./zig-out/bin/zest-indexer --full-scan "$fixture_root"
index_path="$fixture_home/Library/Application Support/zest/index.zst"
test -s "$index_path"
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "ZEST_TEST_INDEX_PATH=$index_path"
    echo "ZEST_TEST_INDEX_SCOPE=$fixture_root"
  } >> "$GITHUB_ENV"
else
  printf 'export ZEST_TEST_INDEX_PATH=%q\n' "$index_path"
  printf 'export ZEST_TEST_INDEX_SCOPE=%q\n' "$fixture_root"
fi
