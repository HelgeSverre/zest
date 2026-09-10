// Render the tap entry from the exact, stapled release artifact's checksum.
import assert from 'node:assert/strict';

const [version, sha256] = process.argv.slice(2);
assert.match(version ?? '', /^\d+\.\d+\.\d+$/);
assert.match(sha256 ?? '', /^[a-f0-9]{64}$/);
process.stdout.write(`cask "zest" do
  version "${version}"
  sha256 "${sha256}"

  url "https://github.com/HelgeSverre/zest/releases/download/v#{version}/zest-universal-apple-darwin.pkg"
  name "Zest"
  desc "Fast native file browser with background indexing"
  homepage "https://github.com/HelgeSverre/zest"

  depends_on macos: :sonoma

  pkg "zest-universal-apple-darwin.pkg"
  binary "/Applications/Zest.app/Contents/Helpers/zest-query"

  uninstall launchctl: "dev.zest.app.indexer",
            quit:      "dev.zest.app",
            pkgutil:   "dev.zest.app"

  caveats <<~EOS
    Open Zest and choose Index > Set Up Indexer to enable background indexing.
    Full Disk Access is optional; without it, some locations cannot be indexed.
    Before upgrading or uninstalling, choose Index > Disable Background Indexing.
    Your index and preferences are retained on uninstall.
    This is an initial beta; see the release notes for known limitations.
  EOS
end
`);
