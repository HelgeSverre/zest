import Darwin
import Foundation

/// Homebrew installs `zest` as a symlink into `Zest.app/Contents/MacOS/Zest`.
/// dyld reports the *invoked* path, so a symlinked launch makes `Bundle.main`
/// the symlink's directory: Info.plist reads return nil (version prints
/// `0.0.0-dev`) and `SMAppService`/`Contents/Helpers` lookups fail outright.
/// Nothing can repair the main bundle after launch, so re-exec through the
/// resolved path instead and let dyld find the real bundle.
enum BundleIdentity {
  /// The path this process was launched with, symlinks unresolved.
  static var invokedPath: String {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
      return CommandLine.arguments.first ?? ""
    }
    return String(cString: buffer)
  }

  /// The path to re-exec, or nil when the invoked path is already canonical.
  /// Resolving is idempotent, so the re-exec'd process gets nil and stops.
  static func reexecTarget(invoked: String) -> String? {
    guard invoked.hasPrefix("/") else { return nil }
    let resolved = URL(fileURLWithPath: invoked).resolvingSymlinksInPath().path
    return resolved == invoked ? nil : resolved
  }

  /// Replace this process with the same command at its resolved path. Returns
  /// only if no re-exec was needed or `execv` failed; the caller continues with
  /// degraded bundle identity rather than refusing to run.
  static func reexecThroughRealPath() {
    guard let target = reexecTarget(invoked: invokedPath) else { return }
    var arguments = CommandLine.arguments
    arguments[0] = target
    var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers where pointer != nil { free(pointer) } }
    execv(target, &pointers)
  }
}
