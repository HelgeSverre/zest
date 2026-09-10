import Foundation

/// Shared bounded subprocess runner for CLI control and permission verification.
enum IndexerProcess {
  /// Draining output before waiting prevents a full pipe from deadlocking the
  /// child. A timeout keeps an unresponsive launchctl from wedging controls.
  static func run(_ executable: URL, arguments: [String], timeout timeoutSeconds: TimeInterval = 90)
    throws -> String
  {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    let forceStop = DispatchWorkItem {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeoutSeconds, execute: timeout)
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeoutSeconds + 2, execute: forceStop)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    forceStop.cancel()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationReason == .exit && process.terminationStatus == 0 else {
      throw NSError(
        domain: "ZestIndexer", code: Int(process.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey: output.isEmpty
            ? "Indexer command failed or timed out." : output
        ])
    }
    return output
  }
}
