import AppKit

/// Headless end-to-end UI benchmark: `Zest --bench [--iterations N] [--json]`.
/// Builds the real `RootViewController` in an off-screen window (same trick as
/// `Snapshot`), drives the real `AppCoordinator` through a scripted scenario,
/// and times each step twice: "query" is mutation → fresh rows delivered on
/// main (the second `onChange` of that generation, `isLoading == false`);
/// "render" is a forced full layout + draw of the window afterwards. The Zig
/// engine alone is `just bench-capi`; this measures everything above it.
enum Bench {
  private struct Step {
    let name: String
    let run: (AppCoordinator) -> Void
  }

  private static let home = FileManager.default.homeDirectoryForCurrentUser.path
  private static let steps: [Step] = [
    .init(name: "open ~") { $0.navigate(to: home) },
    .init(name: "open ~/Library") { $0.navigate(to: home + "/Library") },
    .init(name: "open ~/Library/Application Support") {
      $0.navigate(to: home + "/Library/Application Support")
    },
    .init(name: "back to ~") { $0.navigate(to: home) },
    .init(name: "type 'r'") { $0.commitSearch("r") },
    .init(name: "type 're'") { $0.commitSearch("re") },
    .init(name: "type 'rea'") { $0.commitSearch("rea") },
    .init(name: "type 'read'") { $0.commitSearch("read") },
    .init(name: "type 'readme'") { $0.commitSearch("readme") },
    .init(name: "filter cat:code") { $0.commitSearch("cat:code") },
    .init(name: "clear search") { $0.commitSearch("") },
  ]

  /// Returns the process exit code.
  static func run(iterations: Int, json: Bool) -> Int32 {
    // Start at "/" so the first step is a real navigation into $HOME.
    let vc = RootViewController(coordinator: AppCoordinator(startPath: "/"))
    let coordinator = vc.coordinator
    guard coordinator.core != nil else {
      log(
        "bench ERROR: no index at ~/Library/Application Support/zest/index.zst — run `just index`")
      return 1
    }
    let size = NSSize(width: 1180, height: 760)
    let window = NSWindow(
      contentRect: NSRect(x: -30_000, y: 0, width: size.width, height: size.height),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentViewController = vc  // loads the view; wires the original onChange
    window.setContentSize(size)
    window.orderFront(nil)
    guard let content = window.contentView,
      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
    else {
      log("bench ERROR: no contentView")
      return 1
    }

    // Chain onto RootViewController's onChange: it fires with isLoading true
    // immediately and false once the fresh rows for this generation land.
    var landed = false
    let original = coordinator.onChange
    coordinator.onChange = {
      original?()
      if !coordinator.isLoading { landed = true }
    }
    // Drain the initial query kicked by viewDidLoad + let layout settle.
    RunLoopPump.run(0.35)
    _ = waitUntilLanded { landed }

    var query = [[Double]](repeating: [], count: steps.count)
    var render = [[Double]](repeating: [], count: steps.count)
    var rows = [Int](repeating: 0, count: steps.count)
    let wallStart = now()
    for i in 1...max(1, iterations) {
      for (s, step) in steps.enumerated() {
        landed = false
        let t0 = now()
        step.run(coordinator)
        guard waitUntilLanded({ landed }) else {
          log("bench ERROR: step '\(step.name)' timed out (iteration \(i))")
          return 1
        }
        let t1 = now()
        content.layoutSubtreeIfNeeded()
        content.cacheDisplay(in: content.bounds, to: rep)
        let t2 = now()
        query[s].append(t1 - t0)
        render[s].append(t2 - t1)
        rows[s] = coordinator.results().count
      }
      // Unmeasured reset so the next iteration's first step is a real change.
      landed = false
      coordinator.navigate(to: "/")
      _ = waitUntilLanded { landed }
    }
    let wall = now() - wallStart
    window.orderOut(nil)

    let results = steps.indices.map { s -> [String: Any] in
      [
        "step": steps[s].name, "rows": rows[s],
        "query_ms_median": percentile(query[s], 0.5), "query_ms_p90": percentile(query[s], 0.9),
        "render_ms_median": percentile(render[s], 0.5), "render_ms_p90": percentile(render[s], 0.9),
      ]
    }
    if json {
      let data = try! JSONSerialization.data(
        withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
      print(String(decoding: data, as: UTF8.self))
    } else {
      let w = steps.map(\.name.count).max() ?? 0
      let header = "step".padding(toLength: w, withPad: " ", startingAt: 0)
      print("\(header)  query med   query p90  render med  render p90    rows")
      for r in results {
        let name = (r["step"] as! String).padding(toLength: w, withPad: " ", startingAt: 0)
        let cols = [
          "query_ms_median", "query_ms_p90", "render_ms_median", "render_ms_p90",
        ].map { String(format: "%9.1f", r[$0] as! Double) }
        print(
          "\(name)  \(cols.joined(separator: "   "))  \(String(format: "%6d", r["rows"] as! Int))")
      }
      print(
        String(
          format: "\n%d iterations, %d steps, total wall %.2f s", max(1, iterations), steps.count,
          wall / 1000))
    }
    return 0
  }

  /// Pump the main run loop in 1 ms slices until the fresh rows land.
  private static func waitUntilLanded(_ landed: () -> Bool, timeout: TimeInterval = 30) -> Bool {
    RunLoopPump.until(timeout: timeout, landed)
  }

  /// Monotonic milliseconds.
  private static func now() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
  }

  private static func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s[Int((Double(s.count - 1) * p).rounded())]
  }

  private static func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
  }
}
