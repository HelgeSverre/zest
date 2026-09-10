import SwiftUI

enum IndexerOnboardingStep: Int, CaseIterable {
  case welcome, access, verify
  var title: String { ["Welcome", "Enable access", "Ready to index"][rawValue] }
  var subtitle: String {
    ["A little permission", "One change in Settings", "We’ll check for you"][rawValue]
  }
}

final class IndexerOnboardingModel: ObservableObject {
  @Published var step: IndexerOnboardingStep = .welcome
  @Published var status: IndexerAccessStatus?
  @Published var settingsOpened = false
  @Published var settingsError = false
  @Published var pathCopied = false
  @Published var completed = false
  var canFinish: Bool { status == .verified && !completed }
  var waiting: Bool { status == nil || status == .denied }
  var primaryTitle: String {
    switch step {
    case .welcome: return "Set up access"
    case .access: return settingsOpened || status == .verified ? "Continue" : "Open System Settings"
    case .verify: return "Done"
    }
  }
  var statusTitle: String {
    canFinish ? "Access verified" : waiting ? "Waiting for access" : "We couldn’t verify access"
  }
  var statusDescription: String {
    if canFinish {
      return
        "The installed indexer can read a protected folder. You’re ready to start background indexing."
    }
    return waiting
      ? "Enable zest-indexer in Full Disk Access. We’ll pick up the change when you return."
      : "Check that the installed helper is enabled in Settings. We’ll keep trying, or you can skip for now."
  }
  func back() {
    guard !completed, let previous = IndexerOnboardingStep(rawValue: step.rawValue - 1) else {
      return
    }
    step = previous
  }
}

/// Explicit design tokens preserve the approved graphite/lime onboarding in either app appearance.
enum OnboardingPalette {
  static let surface = color(0x1B1F23), rail = color(0x171B1E), raised = color(0x242A2F)
  static let line = color(0x394248), text = color(0xEEF0F2), muted = color(0xA0A8AE)
  static let accent = color(0xB8EF71), ink = color(0x182310)
  static func color(_ hex: UInt32) -> Color {
    Color(
      red: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
  }
}

struct IndexerOnboardingView: View {
  @ObservedObject var model: IndexerOnboardingModel
  let helper: URL
  let onNext: () -> Void
  let onSkip: () -> Void
  let onSettings: () -> Void
  let onReveal: () -> Void
  let onCopy: () -> Void
  private typealias Palette = OnboardingPalette

  var body: some View {
    VStack(spacing: 0) {
      Text("Set up Zest").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
        .frame(maxWidth: .infinity).frame(height: 42).background(Palette.color(0x202529))
      HStack(spacing: 0) {
        sidebar
        Rectangle().fill(Color.white.opacity(0.04)).frame(width: 1)
        VStack(spacing: 0) {
          Group {
            switch model.step {
            case .welcome: welcome
            case .access: access
            case .verify: verification
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(.horizontal, 38).padding(.top, 35).padding(.bottom, 24)
          footer
        }
      }
    }
    .font(.system(size: 13)).foregroundStyle(Palette.text)
    .frame(width: 860, height: 650).background(Palette.surface)
    .environment(\.colorScheme, .dark)
    .ignoresSafeArea()
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "sparkle").font(.system(size: 24)).foregroundStyle(Palette.accent)
        Text("zest").font(.system(size: 22, weight: .semibold)).tracking(-1)
      }
      Text("BACKGROUND INDEXING").font(.system(size: 10)).tracking(1.2)
        .foregroundStyle(Palette.muted).padding(.top, 36).padding(.bottom, 19)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(IndexerOnboardingStep.allCases, id: \.rawValue) { step in
          stepLabel(step)
          if step != .verify {
            Rectangle().fill(Palette.line).frame(width: 1, height: 22)
              .padding(.leading, 13).padding(.vertical, 3)
          }
        }
      }
      Spacer()
      HStack(spacing: 7) {
        Circle().fill(Palette.muted).frame(width: 6, height: 6)
        Text("Indexer paused during setup").font(.system(size: 10))
      }.foregroundStyle(Palette.muted)
    }
    .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 24)
    .frame(width: 205).frame(maxHeight: .infinity).background(Palette.rail)
  }

  private func stepLabel(_ step: IndexerOnboardingStep) -> some View {
    let active = model.step == step
    let complete = model.step.rawValue > step.rawValue
    return HStack(spacing: 12) {
      Text(complete ? "✓" : String(step.rawValue + 1)).font(.system(size: 11, weight: .semibold))
        .foregroundStyle(active ? Palette.ink : complete ? Palette.accent : Palette.muted)
        .frame(width: 28, height: 28).background(active ? Palette.accent : .clear, in: Circle())
        .overlay(Circle().strokeBorder(active ? Palette.accent : Palette.line, lineWidth: 1))
      VStack(alignment: .leading, spacing: 3) {
        Text(step.title).font(.system(size: 13, weight: active ? .medium : .regular))
          .foregroundStyle(active ? Palette.text : Palette.muted)
        Text(step.subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted)
      }
    }.accessibilityElement(children: .combine)
      .accessibilityLabel(
        "Step \(step.rawValue + 1): \(step.title)\(active ? ", current step" : complete ? ", completed" : "")"
      )
  }

  private func heading(_ eyebrow: String, _ title: String, _ description: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(eyebrow.uppercased()).font(.system(size: 10, weight: .semibold))
        .tracking(1.5).foregroundStyle(Palette.accent).padding(.bottom, 8)
      Text(title).font(.system(size: 29, weight: .semibold)).tracking(-1)
        .lineSpacing(1).fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
        .accessibilityAddTraits(.isHeader)
      Text(description).font(.system(size: 13)).lineSpacing(4)
        .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 410, alignment: .leading)
    }
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 0) {
      heading(
        "Make yourself at home", "Your files. Always\nwithin reach.",
        "Let Zest keep your file index up to date in the background. A one-time permission helps it see your protected folders, too."
      )
      welcomeIllustration.frame(height: 178).frame(maxWidth: .infinity).padding(.top, 16).padding(
        .bottom, 12)
      VStack(alignment: .leading, spacing: 10) {
        benefit("One setup instead of separate folder prompts.")
        benefit("Filenames and metadata indexed locally on your Mac.")
      }
      Text(
        "Full Disk Access also allows access to protected app data.\nYour scan exclusions still apply. You can revoke access anytime."
      )
      .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3).padding(.top, 16)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func benefit(_ title: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark").foregroundStyle(Palette.accent)
      Text(title).foregroundStyle(Palette.color(0xC9CED2))
    }.font(.system(size: 12))
  }

  private var welcomeIllustration: some View {
    ZStack {
      Circle().stroke(Palette.color(0x3C4935), lineWidth: 1).frame(width: 148, height: 148)
      Circle().stroke(Palette.color(0x3A4433), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .frame(width: 112, height: 112)
      ZStack {
        Image(systemName: "folder.fill").font(.system(size: 72))
          .foregroundStyle(
            LinearGradient(
              colors: [Palette.color(0xB7E586), Palette.color(0x8DB65E)], startPoint: .top,
              endPoint: .bottom)
          )
          .shadow(color: .black.opacity(0.2), radius: 8, y: 6)
        Text("Z").font(.system(size: 23, weight: .bold)).foregroundStyle(Palette.color(0x34521A))
          .offset(
            y: 5)
      }
      filePill("Documents", "doc.text").rotationEffect(.degrees(-6)).offset(x: -121, y: -42)
      filePill("Desktop", "desktopcomputer").rotationEffect(.degrees(5)).offset(x: 109, y: 4)
      filePill("Downloads", "arrow.down").rotationEffect(.degrees(-3)).offset(x: -91, y: 61)
    }.accessibilityHidden(true)
  }

  private func filePill(_ name: String, _ symbol: String) -> some View {
    Label(name, systemImage: symbol).font(.system(size: 11))
      .foregroundStyle(Palette.color(0xC5D0C0)).padding(.horizontal, 11).padding(.vertical, 8)
      .background(Palette.color(0x242B29), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.color(0x424D40)))
      .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
  }

  private var access: some View {
    VStack(alignment: .leading, spacing: 0) {
      heading(
        "One change in macOS", "Give the indexer access.",
        "Open Full Disk Access, add zest-indexer, then turn on its switch. macOS may ask you to authenticate."
      )
      settingsIllustration.padding(.top, 24).padding(.bottom, 16)
      Text("**Find the right file.** In the add-file dialog, press ⇧⌘G and paste this path.")
        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Installed helper").font(.system(size: 10)).foregroundStyle(Palette.muted)
          Text(helper.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Button(action: onCopy) {
          Image(systemName: model.pathCopied ? "checkmark" : "doc.on.doc")
        }.buttonStyle(.plain).foregroundStyle(model.pathCopied ? Palette.accent : Palette.muted)
          .help(model.pathCopied ? "Path copied" : "Copy helper path")
          .accessibilityLabel(model.pathCopied ? "Path copied" : "Copy helper path")
      }
      .padding(12).background(Palette.rail, in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line)).padding(.top, 12)
      HStack(spacing: 18) {
        Button("Show in Finder", action: onReveal)
        if model.settingsOpened { Button("Open Settings again", action: onSettings) }
      }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent).padding(
        .top, 12)
      Text(
        model.settingsError
          ? "Open System Settings manually → Privacy & Security → Full Disk Access, then continue."
          : "Already enabled? Continue — we’ll verify access in the next step."
      )
      .font(.system(size: 11)).foregroundStyle(model.settingsError ? .orange : Palette.muted)
      .lineSpacing(3).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var settingsIllustration: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "chevron.left").foregroundStyle(Palette.muted)
        Text("Full Disk Access").fontWeight(.semibold)
        Spacer()
        Text("Illustration").font(.system(size: 9)).foregroundStyle(Palette.muted)
          .padding(.horizontal, 5).padding(.vertical, 2)
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
      }.font(.system(size: 12)).padding(.horizontal, 15).padding(.vertical, 11)
      Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
      VStack(alignment: .leading, spacing: 12) {
        Text("Allow the apps below to access protected files.").font(.system(size: 11))
          .foregroundStyle(Palette.muted)
        HStack(spacing: 10) {
          Image(systemName: "terminal").font(.system(size: 23)).foregroundStyle(Palette.text)
          VStack(alignment: .leading, spacing: 3) {
            Text("zest-indexer").font(.system(size: 12))
            Text("Zest’s background indexer").font(.system(size: 10)).foregroundStyle(Palette.muted)
          }
          Spacer()
          // Illustration only: permission can only be changed in System Settings.
          Capsule().fill(Palette.color(0x81B84E)).frame(width: 34, height: 20)
            .overlay(Circle().fill(.white).frame(width: 16, height: 16).offset(x: 7))
        }.padding(10).background(Palette.color(0x29302B), in: RoundedRectangle(cornerRadius: 7))
          .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.color(0x465048)))
        HStack {
          Image(systemName: "plus").font(.system(size: 12)).frame(width: 28, height: 22)
            .background(Palette.color(0x333C43), in: RoundedRectangle(cornerRadius: 4))
          Spacer()
          Text("Add the helper, then enable its switch").font(.system(size: 10)).foregroundStyle(
            Palette.muted)
        }
      }.padding(15)
    }.background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.color(0x475057)))
      .shadow(color: .black.opacity(0.15), radius: 10, y: 8)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Illustration: add zest-indexer to Full Disk Access and turn on its switch in System Settings."
      )
  }

  private var verification: some View {
    VStack(alignment: .leading, spacing: 0) {
      heading(
        "The last little check", "Let’s make sure it worked.",
        "Zest checks the installed indexer’s access automatically. There’s nothing to restart.")
      VStack(spacing: 0) {
        ZStack {
          Circle().fill(model.canFinish ? Palette.color(0x242D22) : Palette.raised)
          Circle().strokeBorder(
            model.canFinish ? Palette.color(0x4A5840) : Palette.line,
            style: StrokeStyle(lineWidth: 1, dash: model.waiting ? [3, 3] : []))
          Image(
            systemName: model.canFinish
              ? "checkmark" : model.waiting ? "ellipsis" : "exclamationmark"
          )
          .font(.system(size: 30, weight: .medium))
          .foregroundStyle(
            model.canFinish ? Palette.accent : model.waiting ? Palette.muted : .orange)
        }.frame(width: 84, height: 84).padding(.bottom, 18).accessibilityHidden(true)
        Text(model.statusTitle).font(.system(size: 18, weight: .medium)).padding(.bottom, 7)
        Text(model.statusDescription).font(.system(size: 12)).lineSpacing(4)
          .foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 315)
          .fixedSize(horizontal: false, vertical: true)
      }.frame(maxWidth: .infinity).padding(.top, 30).padding(.bottom, 26)
      VStack(spacing: 0) {
        checkRow("Installed background helper", "✓ Ready", Palette.accent)
        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        checkRow(
          "Protected-folder access",
          model.canFinish ? "✓ Verified" : model.waiting ? "Checking…" : "Not verified",
          model.canFinish ? Palette.accent : Palette.muted)
      }.padding(.horizontal, 15).background(
        Palette.color(0x202723), in: RoundedRectangle(cornerRadius: 9)
      )
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.color(0x39423D)))
      Text(
        model.canFinish
          ? "This confirms folder access, not access to every location on disk."
          : "Checking automatically · Indexing hasn’t started yet"
      )
      .font(.system(size: 10)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(
        .top, 13)
      if !model.canFinish {
        Button("Open Full Disk Access Settings", action: onSettings)
          .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
          .frame(maxWidth: .infinity).padding(.top, 15)
      }
    }
  }

  private func checkRow(_ title: String, _ status: String, _ color: Color) -> some View {
    HStack {
      Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
      Spacer()
      Text(status).font(.system(size: 10)).foregroundStyle(color)
    }.padding(.vertical, 11)
  }

  private var footer: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
      HStack(spacing: 9) {
        Button("Skip for now", action: onSkip).buttonStyle(.plain)
          .font(.system(size: 12)).foregroundStyle(Palette.muted)
        Spacer()
        if model.step != .welcome {
          Button("Back", action: model.back).buttonStyle(OnboardingButtonStyle())
        }
        Button(action: onNext) {
          HStack(spacing: 8) {
            Text(model.primaryTitle)
            if model.step != .verify {
              Image(
                systemName: model.primaryTitle == "Open System Settings"
                  ? "arrow.up.right" : "arrow.right")
            }
          }
        }.buttonStyle(OnboardingButtonStyle(primary: true))
          .disabled(model.step == .verify && !model.canFinish).keyboardShortcut(.defaultAction)
      }.padding(.horizontal, 28).frame(height: 73)
    }
  }
}

struct OnboardingButtonStyle: ButtonStyle {
  var primary = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12, weight: .semibold))
      .padding(.horizontal, 14).frame(height: 34)
      .foregroundStyle(primary ? OnboardingPalette.ink : OnboardingPalette.text)
      .background(
        primary ? OnboardingPalette.accent : OnboardingPalette.color(0x2A3035),
        in: RoundedRectangle(cornerRadius: 7)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 7).strokeBorder(
          primary ? OnboardingPalette.accent : OnboardingPalette.color(0x424B52))
      )
      .brightness(configuration.isPressed ? -0.08 : 0).opacity(enabled ? 1 : 0.35)
      .contentShape(RoundedRectangle(cornerRadius: 7))
  }
}
