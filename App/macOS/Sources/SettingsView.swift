import AppKit
import SwiftUI

/// The appearance preference: follow the system, or pin light/dark.
/// Persisted in UserDefaults ("QuoinAppearance") and applied to
/// `NSApp.appearance` at launch and on change.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies this preference app-wide. The screenshot-automation pin
    /// (`-QuoinForceDarkMode`) wins over the stored preference so CI
    /// captures stay deterministic.
    static func applyStored() {
        guard !UserDefaults.standard.bool(forKey: "QuoinForceDarkMode") else {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            return
        }
        let stored = UserDefaults.standard.string(forKey: "QuoinAppearance") ?? ""
        NSApp.appearance = (AppAppearance(rawValue: stored) ?? .system).nsAppearance
    }
}

/// The Settings window (Quoin ▸ Settings…, ⌘,): classic macOS preferences
/// layout — right-aligned label column, horizontal radio group, footnote
/// captions. Scope follows the design handoff: Graphite is THE visual
/// direction (dark mode is its inversion, the accent follows the system
/// accent color), and the status bar is specced as "hideable in Settings".
struct SettingsView: View {
    @AppStorage("QuoinAppearance") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("QuoinShowStatusBar") private var showStatusBar = true
    @AppStorage("QuoinReviewerName") private var reviewerName = ""
    @AppStorage("QuoinLaunchBehavior") private var launchBehavior = "restore"

    var body: some View {
        Form {
            Picker("Appearance:", selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            LabeledContent("") {
                Text("The accent color follows System Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            Toggle("Show status bar", isOn: $showStatusBar)

            Picker("When Quoin opens:", selection: $launchBehavior) {
                Text("Open the folders from last time").tag("restore")
                Text("Start with an empty window").tag("empty")
            }
            .pickerStyle(.radioGroup)

            LabeledContent("") {
                Text("Each window remembers its own folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            TextField("Review as:", text: $reviewerName, prompt: Text(NSUserName()))
                .frame(maxWidth: 220)

            LabeledContent("") {
                Text("Comments and suggestions you create are attributed to this name.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            LabeledContent("") {
                Text("Current section and word count, at the foot of the window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .fixedSize()
        .onChange(of: appearanceRaw) {
            AppAppearance.applyStored()
        }
    }
}
