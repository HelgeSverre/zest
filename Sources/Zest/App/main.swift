import AppKit

// Must run before anything reads Bundle.main (version, helper paths, SMAppService).
BundleIdentity.reexecThroughRealPath()

let action: LaunchAction
switch LaunchOptions.parse(
  Array(CommandLine.arguments.dropFirst()), cwd: FileManager.default.currentDirectoryPath)
{
case .success(let a): action = a
case .failure(let err):
  FileHandle.standardError.write(Data((err.message + "\n").utf8))
  exit(err.exitCode)
}

switch action {
case .help:
  print(LaunchOptions.usage, terminator: "")
  exit(0)
case .version:
  print(LaunchOptions.version)
  exit(0)
case .indexer(let command):
  // Packaged-service diagnostics; no GUI or scanning. `status` is read-only.
  do {
    try BundledIndexerService.validateBundle(at: Bundle.main.bundleURL)
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zest-indexer")
    print(try BundledIndexerService(helper: helper).execute([command]))
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
  }
case .snapshot(let path, let size):
  // Dev verification: renders the UI off-screen to a PNG and exits (no event loop).
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  Snapshot.capture(RootViewController(), to: path, size: size)
  exit(0)
case .bench(let iterations, let json):
  // Dev benchmark: drives the real UI headlessly against the index and exits.
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  exit(Bench.run(iterations: iterations, json: json))
case .browse(let path):
  // Window policy: every `zest PATH` invocation is its own process and window.
  // To reuse a running instance instead, this is the one place to change:
  // forward `path` via NSWorkspace.shared.open(_:withApplicationAt:) and exit,
  // and handle it in AppDelegate.application(_:open:).
  let app = NSApplication.shared
  let delegate = AppDelegate(startPath: path)
  app.delegate = delegate
  app.setActivationPolicy(.regular)  // show in Dock / accept focus when unbundled
  app.run()
}
