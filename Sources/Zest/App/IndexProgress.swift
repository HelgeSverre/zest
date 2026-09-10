import AppKit
import SwiftUI

struct IndexProgressSnapshot: Codable, Equatable {
  let version: Int
  let runId: String
  let pid: Int32
  let startedAt: Double
  let updatedAt: Double
  let elapsedMs: UInt64
  let phase: String
  let count: UInt64
  let currentPath: String
  let written: UInt64
  let total: UInt64
  let message: String

  private enum CodingKeys: String, CodingKey {
    case version, pid, phase, count, written, total, message
    case runId = "run_id"
    case startedAt = "started_at"
    case updatedAt = "updated_at"
    case elapsedMs = "elapsed_ms"
    case currentPath = "current_path"
  }

  var valid: Bool {
    version == 1 && pid > 0 && !runId.isEmpty && runId.count <= 64
      && ["scanning", "building", "writing", "published", "failed"].contains(phase)
      && startedAt.isFinite && updatedAt.isFinite && updatedAt >= startedAt
      && count <= UInt64(Int.max) && written <= total
  }

  func isFresh(at now: Date) -> Bool {
    (-5...12).contains(now.timeIntervalSince1970 - updatedAt)
  }

  var fraction: Double? {
    guard phase == "writing", total > 0 else { return nil }
    return min(1, Double(written) / Double(total))
  }
}

enum IndexProgressPhase { case idle, scanning, building, writing, loading, ready, interrupted }

final class IndexProgressModel: ObservableObject {
  @Published private(set) var phase: IndexProgressPhase = .idle
  @Published private(set) var snapshot: IndexProgressSnapshot?
  @Published private(set) var firstRun: Bool
  @Published var dismissed = false
  @Published private(set) var detail = ""
  private var readySince: Date?
  private var loadedCount: UInt64?

  init(hasIndex: Bool) { firstRun = !hasIndex }
  var showsOverlay: Bool { firstRun && !dismissed }
  var fraction: Double? { phase == .writing ? snapshot?.fraction : phase == .ready ? 1 : nil }
  var count: UInt64 { phase == .ready ? loadedCount ?? snapshot?.count ?? 0 : snapshot?.count ?? 0 }
  var elapsed: String {
    let seconds = (snapshot?.elapsedMs ?? 0) / 1000
    return String(format: "%02llu:%02llu", seconds / 60, seconds % 60)
  }
  var active: Bool { [.scanning, .building, .writing, .loading].contains(phase) }
  var statusText: String? {
    if firstRun {
      switch phase {
      case .idle: return "Set up your first index…"
      case .interrupted: return "Index interrupted · View details"
      case .ready: return "Your files are ready"
      default: return "Creating first index · View progress"
      }
    }
    switch phase {
    case .scanning: return "Updating index · \(count.formatted()) found"
    case .building: return "Updating index · Building"
    case .writing: return "Updating index · Saving"
    case .interrupted: return "Index update interrupted · Retry"
    default: return nil
    }
  }

  /// Completion is owned by the reader/query, never inferred from a progress
  /// percentage, a published snapshot, or a nonzero number of discovered files.
  func update(
    _ incoming: IndexProgressSnapshot?, usableIndex: Bool, now: Date = Date(),
    indexCount: UInt64? = nil, indexModified: Double? = nil,
    alive: (Int32) -> Bool
  ) {
    if let incoming, incoming.valid { snapshot = incoming }
    if usableIndex { loadedCount = indexCount ?? loadedCount }
    if usableIndex && firstRun {
      phase = .ready
      readySince = readySince ?? now
      if now.timeIntervalSince(readySince!) >= 1.2 { firstRun = false }
      return
    }
    guard let snapshot else {
      phase = .idle
      return
    }
    // Old crash/failure records must not override a newer successfully loaded index.
    if usableIndex, let indexModified, snapshot.updatedAt < indexModified,
      snapshot.phase == "failed" || snapshot.phase == "published" || !snapshot.isFresh(at: now)
        || !alive(snapshot.pid)
    {
      phase = .ready
      detail = ""
      return
    }
    if snapshot.phase == "published" {
      phase = usableIndex ? .ready : snapshot.isFresh(at: now) ? .loading : .interrupted
      detail = "The index was saved, but Zest couldn’t load it. Try indexing again."
    } else if snapshot.phase == "failed" {
      phase = .interrupted
      detail =
        "The indexer couldn’t finish: \(snapshot.message). The daemon will retry automatically if it is still running."
    } else if !snapshot.isFresh(at: now) || !alive(snapshot.pid) {
      phase = .interrupted
      detail = "The indexer stopped reporting progress. It may have stopped or become unresponsive."
    } else {
      switch snapshot.phase {
      case "scanning": phase = .scanning
      case "building": phase = .building
      case "writing": phase = .writing
      default: phase = .idle
      }
      detail = ""
    }
  }
}

/// One bounded background read per second; no launchctl invocation per tick.
final class IndexProgressMonitor {
  private let directory: URL
  private let queue = DispatchQueue(label: "dev.zest.progress-reader", qos: .utility)
  private var timer: Timer?
  private var reading = false
  private var generation = 0
  var onUpdate: ((IndexProgressSnapshot?) -> Void)?

  init(
    directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/zest")
  ) {
    self.directory = directory
  }
  deinit { timer?.invalidate() }

  func start() {
    stop()
    poll()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    timer.tolerance = 0.2
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  func stop() {
    generation += 1
    timer?.invalidate()
    timer = nil
  }
  private func poll() {
    guard !reading else { return }
    reading = true
    let directory = directory
    let generation = generation
    queue.async { [weak self] in
      let snapshot = Self.read(directory: directory)
      DispatchQueue.main.async {
        guard let self else { return }
        self.reading = false
        guard self.generation == generation else { return }
        self.onUpdate?(snapshot)
      }
    }
  }

  static func processAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
  }

  static func read(directory: URL, now: Date = Date(), alive: (Int32) -> Bool = processAlive)
    -> IndexProgressSnapshot?
  {
    let fm = FileManager.default
    let urls =
      (try? fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])) ?? []
    let candidates = urls.filter {
      $0.lastPathComponent.hasPrefix("progress-") && $0.pathExtension == "json"
    }
    .compactMap { url -> (URL, Date)? in
      guard
        let info = try? url.resourceValues(forKeys: [
          .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]),
        info.isRegularFile == true, info.isSymbolicLink != true,
        let size = info.fileSize, size <= 32_768,
        let date = info.contentModificationDate
      else { return nil }
      return (url, date)
    }.sorted { $0.1 > $1.1 }.prefix(32)
    let snapshots = candidates.compactMap { url, _ -> IndexProgressSnapshot? in
      guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
      defer { try? handle.close() }
      guard let data = try? handle.read(upToCount: 32_769), data.count <= 32_768,
        let value = try? JSONDecoder().decode(IndexProgressSnapshot.self, from: data), value.valid,
        value.updatedAt <= now.timeIntervalSince1970 + 5
      else { return nil }
      return value
    }
    // A live scan wins over a stopped older process's terminal snapshot.
    let active = snapshots.filter {
      !["failed", "published"].contains($0.phase) && $0.isFresh(at: now) && alive($0.pid)
    }
    return (active.isEmpty ? snapshots : active).max { $0.updatedAt < $1.updatedAt }
  }
}
