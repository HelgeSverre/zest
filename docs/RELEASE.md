# Zest release runbook

Zest 0.1 targets macOS 14+ on Apple Silicon and Intel. The installer contains a
Universal app and two Universal helpers. No automatic updater is included.

## Install, enable indexing, and remove

1. Install the signed, notarized PKG into Applications.
2. Open Zest and choose Set Up Indexer. The installer never starts a scan.
3. Follow the existing three-panel Full Disk Access guide. Its Finder/copy buttons
   point to the bundled helper in Zest.app/Contents/Helpers/zest-indexer.
4. Done requires a successful protected-folder operation; Skip explicitly allows
   indexing accessible locations only. Neither outcome guarantees access to every
   file. The GUI may separately need permission to preview protected files.
5. Zest registers its bundled per-user LaunchAgent through SMAppService. If macOS
   requires background-item approval, Zest explains it and opens Login Items.
   Full Disk Access and background approval are separate permissions.
6. The progress overlay remains until the index is loaded and searchable.

The helper stays inside the app. No release helper is copied into Application
Support, and the app does not fall back to arbitrary binaries or checkout paths.
A fresh launch only reads service status; it does not register, migrate, or start
indexing. Setup can migrate the old development LaunchAgent explicitly, stopping
it and removing its registration/copied executable while retaining user data.

Index > Stop Indexer unregisters the packaged helper and stays stopped across
logins. Start registers it again. Disable Background Indexing unregisters it too,
with confirmation. Disable before removing Zest; then move the app to Trash.
The index, pins, and preferences remain in ~/Library/Application Support/zest.
Delete that folder manually only if you want to erase those data as well. Remove
obsolete Full Disk Access entries in System Settings yourself.

Manual updates replace the entire app, including its helper. macOS owns the
service registration; Zest has no separate executable upgrade/rollback machinery.
The signed upgrade, relocation, running-process replacement, and trash-removal
cases must be tested on supported OS versions before public release.

The development CLI still supports install/start/stop/restart/uninstall using its
legacy dev.zest.indexer label. Its stop is temporary until next login. The packaged
service uses dev.zest.app.indexer, preventing the two registration systems from
silently taking over each other's jobs. Do not install the development daemon
alongside the packaged one.

## Local packaging

Prerequisites: Zig 0.16.0, Xcode command-line tools, Swift, Node.js, jq, and just.
Version/build metadata live in release.json; the bundle identifier is dev.zest.app.
Both Swift and Zig explicitly target macOS 14. The optimized Zig builds use the
baseline CPU for each architecture; lipo combines the final binaries.

- just app-package: ad-hoc Universal dist/Zest.app; local testing only.
- just pkg-unsigned: unsigned LOCAL-ONLY PKG; no credentials or uploads.
- just pkg-signed: Developer ID signed PKG; no notarization or publication.
- just pkg-notarized: signed PKG, explicit Apple submission, stapling and validation.
- just pkg-local: same notarized workflow using installed Liseth identities and
  the ignored signing/ folder's AuthKey_*.p8 and issuer-uuid.txt.

Sourcefour's separation is retained: scripts/package.sh assembles the app;
.github/scripts/package-macos-pkg.sh signs/packages/notarizes it. No Rust tooling
is needed in this Swift/Zig project. A shared verifier checks the ad-hoc and
distribution-signed app. Previous local candidates are preserved under dist/.

The PKG uses an explicit non-relocatable component and always targets
/Applications/Zest.app. Installer must not redirect an update into a checkout or
downloaded app with the same bundle ID. CI registers such a competing copy before
installing, and checks the installed app at the intended path. Package metadata
also enforces macOS 14+ and atomically replaces the app bundle on upgrade.

The public artifact name is zest-universal-apple-darwin.pkg with a matching
.sha256 file. A signed-only artifact is NOT ready for distribution. Successful
notarization is checked explicitly, diagnostic logs are retained on failure,
and pkgutil/stapler/Gatekeeper checks run before checksumming the final package.

## Apple signing and notarization

Existing Developer ID identities for Liseth Solutions AS (team 9Z2L5FBZS3) are
reused. An Application certificate signs the app/helper code; an Installer
certificate signs the PKG. These identify the developer, not a single app:
a new CSR/certificate is not required just to add Zest.

For local signing the private certificate keys stay in Keychain. The notarization
team API key stays in the ignored signing/ directory (directory 0700, files 0600).
Never commit .p8, .p12, private keys, passwords, or a populated environment file.

1Password Personal vault:
- Zest Release Signing: team/identity/bundle metadata, API Key ID and Issuer ID,
  and the notary_api_key attachment.
- Sourcefour Release Signing: shared application_p12 / installer_p12 attachments
  and their concealed passwords. Zest's item references these instead of
  duplicating certificate secrets.
- Zest item ID: o7ainekfvhgbjvznbv4svu36d4.
- Shared certificate item ID: skzstdog6eyqnkcihzrfizklru.

The Zest key attachment was read back and cryptographically compared with the
local key. Keep 1Password as the durable backup; the ignored local folder is
only a working copy.

When transferring binary certificate attachments from 1Password, use
`op read --out-file` into a private temporary directory, then base64-encode the
file. Do not pipe binary attachments through text stdout: it can corrupt PKCS#12
bytes. Validate the bundle/password before updating GitHub. The shared Keychain
exports use legacy PKCS#12 encryption; OpenSSL 3 validation needs `-legacy`.

For GitHub Actions, configure the same names as Sourcefour. Do not copy values
into workflow YAML or paste secrets into chat.

Repository secrets:
- APPLE_APPLICATION_CERTIFICATE_BASE64
- APPLE_APPLICATION_CERTIFICATE_PASSWORD
- APPLE_INSTALLER_CERTIFICATE_BASE64
- APPLE_INSTALLER_CERTIFICATE_PASSWORD
- APPLE_NOTARY_KEY_BASE64

Repository variables:
- APPLE_APPLICATION_SIGNING_IDENTITY
- APPLE_INSTALLER_SIGNING_IDENTITY
- APPLE_TEAM_ID
- APPLE_NOTARY_KEY_ID
- APPLE_NOTARY_ISSUER_ID

The signing workflow imports certificates into an ephemeral keychain and cleans
up both keychain and API key even after failure. Pull-request CI has no signing
credentials. Local workflows can use existing Keychain identities without
exporting them or changing the keychain search list.

## Tests and publication gate

just test runs Zig and native Swift tests. just test-daemon exercises live
FSEvents, ignored-tree churn, recovery and concurrent scans in disposable homes.
scripts/verify-release.mjs checks bundle signatures, both architectures and OS
minimums, Mach-O structural validity after signing, dynamic dependencies, required
resources, and a real isolated scan/query on every architecture the host can run
(including Intel through Rosetta when available). Pass --all-architectures to
require both runtime checks, and --render-ui to render the packaged GUI too.
It never registers a service or changes privacy access. Both Zig executables
reserve header padding so signing cannot overwrite x86_64 code (Zig issue 23704).

The verifier also calls `Zest --indexer-status` from the actual app bundle to
exercise macOS ServiceManagement, including a missing registration record on a
fresh install. This read-only diagnostic prints the indexer state or reports the
underlying error on stderr with a nonzero exit code. The Index menu exposes
genuine status errors through Show Status Error; a valid, unregistered bundle
offers setup instead of requiring another reinstall.

Pushing a version-matching tag runs the test/sign/notarize workflow and creates a
DRAFT prerelease only after successful packaging. No tag or release is pushed by
local packaging. Publishing the draft remains a separate explicit action.

## Homebrew distribution

The cask lives in HelgeSverre/homebrew-tap as Casks/zest.rb and installs the same
notarized Universal PKG, exposing zest, zest-query, and zest-indexer on PATH.
The indexer executable includes legacy development-service commands; use the
app's Index menu to manage its SMAppService background registration instead.
After verifying and publishing the release, run:

```sh
node scripts/publish-cask.mjs 0.1.1
brew install --cask helgesverre/tap/zest
```

The publisher downloads the actual release PKG and checksum, verifies them,
renders the cask, and updates only that tap file using the authenticated gh user.
It is deliberately a separate publication step, not a cross-repository token
hidden in the signing job. Re-running it with the same artifact is a no-op.
For Homebrew-managed installs, run `brew update` then `brew upgrade --cask zest`.
A PKG installed directly is not registered with Homebrew, even when the app exists
in Applications. If upgrade reports "Cask 'zest' is not installed", use
`brew install --cask helgesverre/tap/zest` to switch to Homebrew, or install the new
PKG directly to keep managing updates manually. A direct PKG does not create the
Homebrew terminal links; its executables remain inside Zest.app.

Disable indexing and quit Zest before upgrades or removal; uninstall removes the
app/receipt but retains index and preferences. Reopen the app after upgrading and
start indexing or complete setup from the Index menu.
Full Disk Access remains an explicit user choice after installation.

For each patch release, update release.json (version and build), add
docs/releases/VERSION.md without a duplicate title, and update the README's
download and release-notes links. Verify the signed/notarized artifacts before
publishing the draft, then update the cask and run the Homebrew smoke workflow.
Do not move published tags or replace existing release artifacts.

Before making that draft public:
- [ ] Test the browser-downloaded, quarantined PKG on a clean account/Mac, without
      Terminal or IDE Full Disk Access.
- [ ] Test macOS 14 and supported current versions on both ARM and Intel.
- [ ] Test grant/deny/skip/revoke/re-grant and close-at-each-step onboarding.
- [ ] Test background approval/disable, logout/login, reboot, sleep/wake.
- [ ] Test the actual signed SMAppService registration, stop/start/restart,
      approval handling, legacy migration, and app removal/relocation.
- [ ] Test upgrade while scanning and while disabled; preserve FDA and user data.
- [ ] Verify protected-file previews separately from helper directory access.
- [ ] Report incomplete scan coverage in the UI (permission-denied trees are
      currently skipped without a persistent coverage summary).
- [ ] Check multi-day resource use and diagnostic retention; legacy daemon.log
      still needs bounded rotation (bundled service uses launchd diagnostics).
- [ ] Test low disk, stale indexes, interrupted scans, and failure recovery.
- [ ] Approve the generated icon and finish bundled-license provenance review,
      including the vendored Sema grammar.
- [ ] Configure GitHub signing secrets/variables; verify the workflow remotely.
- [ ] Add release notes and website download links only after acceptance.

Apple references:
- https://developer.apple.com/help/account/certificates/create-developer-id-certificates
- https://developer.apple.com/documentation/servicemanagement/smappservice
- https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
