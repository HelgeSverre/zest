import SwiftUI

/// Shares the approved onboarding tokens; only real telemetry drives this view.
struct FirstIndexProgressView: View {
  @ObservedObject var model: IndexProgressModel
  let onBackground: () -> Void
  let onRetry: () -> Void
  let onSetup: () -> Void
  private typealias Palette = OnboardingPalette

  private var title: String {
    switch model.phase {
    case .idle: return "Your files, within reach."
    case .scanning: return "Getting to know your files."
    case .building, .writing: return "Turning files into fast search."
    case .loading: return "Just opening the door."
    case .ready: return "Your files are ready."
    case .interrupted: return "The scan was interrupted."
    }
  }
  private var subtitle: String {
    switch model.phase {
    case .idle:
      return
        "Set up background indexing to start finding your files. Your first index will appear here."
    case .scanning:
      return "Zest is creating your first search index. Larger collections can take a few minutes."
    case .building, .writing:
      return
        "Discovery is complete. Zest is building the index that makes finding your files feel instant."
    case .loading: return "Your index has been saved. Zest is loading it before showing your files."
    case .ready:
      return "Your first index is loaded. From now on, Zest keeps it up to date in the background."
    case .interrupted:
      return "Zest couldn’t finish the first index. Your files haven’t been changed."
    }
  }
  private var phaseText: String {
    switch model.phase {
    case .idle: return "Waiting for setup"
    case .scanning: return "Scanning your files"
    case .building: return "Building the search index"
    case .writing:
      return model.fraction == 1 ? "Finishing and publishing the index" : "Writing the search index"
    case .loading: return "Opening the new index"
    case .ready: return "First index complete"
    case .interrupted: return "No index available yet"
    }
  }
  private var activity: String {
    switch model.phase {
    case .scanning:
      let path = model.snapshot?.currentPath ?? ""
      return path.isEmpty
        ? "Discovering accessible folders…" : (path as NSString).abbreviatingWithTildeInPath
    case .building: return "Organizing entries for fast, local search"
    case .writing: return "Saving the first index on this Mac"
    case .loading: return "Loading searchable results into Zest"
    case .ready: return "Your results are loaded and ready"
    case .interrupted: return model.detail
    case .idle: return "Use Set Up Indexer to get started"
    }
  }

  var body: some View {
    ZStack {
      Color.black.opacity(0.65).contentShape(Rectangle()).onTapGesture {}
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("A LITTLE SETUP. A FASTER EVERYDAY.")
              .font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(
                Palette.accent)
            Spacer(minLength: 8)
            Circle().fill(model.phase == .interrupted ? .orange : Palette.accent).frame(
              width: 5, height: 5)
            Text(
              model.phase == .interrupted
                ? "Needs attention"
                : model.phase == .ready ? "Index loaded" : model.active ? "Working" : "Not started"
            )
            .font(.system(size: 10)).foregroundStyle(Palette.muted)
          }.padding(.bottom, 25)
          HStack(spacing: 18) {
            ZStack {
              RoundedRectangle(cornerRadius: 17).fill(Palette.color(0x252F22))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Palette.color(0x455539)))
              Image(
                systemName: model.phase == .ready
                  ? "checkmark" : model.phase == .interrupted ? "exclamationmark" : "folder.fill"
              )
              .font(.system(size: 28, weight: .medium))
              .foregroundStyle(model.phase == .interrupted ? .orange : Palette.accent)
            }.frame(width: 64, height: 64).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
              Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
              Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
          }
          phaseRail.padding(.top, 23).padding(.bottom, 25)
          HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
              Text(model.count.formatted()).font(.system(size: 33, weight: .medium)).tracking(-1)
                .monospacedDigit()
              Text(
                model.phase == .ready || model.phase == .loading
                  ? "files & folders indexed" : "files & folders discovered"
              )
              .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
              Text(model.elapsed).font(.system(size: 12)).monospacedDigit()
              Text(model.phase == .ready ? "total time" : "elapsed").font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            }
          }.padding(.bottom, 13)
          IndexProgressBar(fraction: model.fraction, active: model.active && model.showsOverlay)
            .accessibilityLabel(phaseText)
          HStack {
            Text(phaseText)
            Spacer()
            Text(
              model.fraction.map {
                "\(Int($0 * 100))%\(model.phase == .writing ? " of this step" : "")"
              } ?? (model.active ? "Working…" : "")
            )
            .foregroundStyle(Palette.accent)
          }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 9)
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.phase == .interrupted ? "exclamationmark.circle" : "folder")
              .foregroundStyle(Palette.accent).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
              Text(
                model.phase == .scanning
                  ? "Currently exploring"
                  : model.phase == .interrupted ? "What happened" : "Working locally"
              )
              .font(.system(size: 10)).foregroundStyle(Palette.muted)
              Text(activity).font(.system(size: 10, design: .monospaced))
                .lineLimit(3).truncationMode(.middle).help(activity)
            }
            Spacer(minLength: 0)
          }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.rail, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line)).padding(.top, 21)
          Text(
            model.phase == .interrupted
              ? "Check indexer access and available disk space. Nothing will appear in search until the first index completes."
              : "Your files stay right where they are. Zest records filenames and metadata locally. Your scan exclusions still apply."
          )
          .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true).padding(.top, 17)
        }.padding(.horizontal, 34).padding(.top, 29).padding(.bottom, 25)
        Rectangle().fill(Palette.line).frame(height: 1)
        HStack(spacing: 9) {
          Text(
            model.phase == .ready
              ? "Future updates happen quietly" : "Updates live · No need to refresh"
          )
          .font(.system(size: 10)).foregroundStyle(Palette.muted)
          Spacer(minLength: 5)
          if model.phase == .interrupted {
            Button("Set up access…", action: onSetup).buttonStyle(OnboardingButtonStyle())
            Button("Retry indexing", action: onRetry).buttonStyle(
              OnboardingButtonStyle(primary: true))
          } else if model.phase == .idle {
            Button("Set Up Indexer…", action: onSetup).buttonStyle(
              OnboardingButtonStyle(primary: true))
          } else {
            Button(
              model.phase == .ready ? "Open Zest →" : "Run in background", action: onBackground
            )
            .buttonStyle(OnboardingButtonStyle(primary: model.phase == .ready))
          }
        }.padding(.horizontal, 24).padding(.vertical, 15)
      }
      .foregroundStyle(Palette.text).frame(width: 540)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.color(0x434C4F)))
      .shadow(color: .black.opacity(0.45), radius: 30, y: 20)
      .padding(20)
    }.environment(\.colorScheme, .dark)
  }

  private var phaseRail: some View {
    let current =
      model.phase == .building || model.phase == .writing
      ? 1 : model.phase == .loading || model.phase == .ready ? 2 : 0
    return HStack(spacing: 10) {
      ForEach(0..<3) { index in
        HStack(spacing: 6) {
          Text(index < current || model.phase == .ready ? "✓" : "\(index + 1)")
            .font(.system(size: 9)).frame(width: 17, height: 17)
            .foregroundStyle(index == current ? Palette.ink : Palette.accent)
            .background(index == current ? Palette.accent : .clear, in: Circle())
            .overlay(Circle().strokeBorder(index == current ? Palette.accent : Palette.line))
          Text(["Discover files", "Build index", "Ready to search"][index])
            .font(.system(size: 10)).foregroundStyle(
              index == current ? Palette.text : Palette.muted)
        }.fixedSize(horizontal: true, vertical: false)
        if index < 2 { Rectangle().fill(Palette.line).frame(height: 1) }
      }
    }.accessibilityElement(children: .combine)
  }
}

/// Native drawing keeps determinate and indeterminate bars faithful in captures.
struct IndexProgressBar: View {
  let fraction: Double?
  var active = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(
      .animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active || fraction != nil)
    ) { context in
      GeometryReader { geometry in
        let width = geometry.size.width
        let position =
          context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.7) / 2.7
        ZStack(alignment: .leading) {
          Capsule().fill(OnboardingPalette.color(0x323D30))
          if let fraction {
            Capsule().fill(OnboardingPalette.accent).frame(width: width * max(0, min(1, fraction)))
          } else if active {
            Capsule().fill(OnboardingPalette.accent.opacity(reduceMotion ? 0.35 : 1))
              .frame(width: width * (reduceMotion ? 1 : 0.32))
              .offset(x: reduceMotion ? 0 : width * (position * 1.32 - 0.32))
          }
        }.clipShape(Capsule())
      }
    }.frame(height: 6)
      .accessibilityElement(children: .ignore)
      .accessibilityValue(
        fraction.map { "\(Int($0 * 100)) percent of this step" }
          ?? (active ? "Working; total unknown" : "Not running"))
  }
}
