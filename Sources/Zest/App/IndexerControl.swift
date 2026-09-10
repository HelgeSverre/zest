import Foundation

/// The shared menu/onboarding workflow is independent of registration ownership.
protocol IndexerControl {
  func state() throws -> IndexerState
  func execute(_ arguments: [String]) throws -> String
}

struct CommandLineIndexerService: IndexerControl {
  let helper: URL
  func execute(_ arguments: [String]) throws -> String {
    try IndexerProcess.run(helper, arguments: arguments)
  }
  func state() throws -> IndexerState {
    let output = try execute(["status"]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let state = IndexerState(rawValue: output) else {
      throw NSError(
        domain: "ZestIndexer", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The indexer returned an unrecognized status. Rebuild or update zest-indexer."
        ])
    }
    return state
  }
}
