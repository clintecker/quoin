import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct QuoinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindow()
        }
        .defaultSize(width: 1180, height: 760) // handoff: default ~1180×760pt
        .commands {
            // Save is automatic (autosave-in-place). Undo/Redo are REAL
            // menu items (an Edit menu without Undo reads as broken) —
            // they route to the key window's document session.
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NotificationCenter.default.post(name: AppDelegate.undoNotification, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    NotificationCenter.default.post(name: AppDelegate.redoNotification, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            AboutCommands()
            // Format menu: the whole formatting grammar lives in the menu
            // bar (discoverable), not only behind invisible shortcuts.
            FormatCommands()
            // View menu: the handoff's panel toggles (⌘0 sidebar, ⌥⌘0
            // outline) + focus mode, delivered to the key window via
            // notifications.
            CommandGroup(before: .sidebar) {
                Button("Show/Hide Sidebar") {
                    NotificationCenter.default.post(name: AppDelegate.toggleSidebarNotification, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("Show/Hide Outline") {
                    NotificationCenter.default.post(name: AppDelegate.toggleOutlineNotification, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                Button("Toggle Focus Mode") {
                    NotificationCenter.default.post(name: AppDelegate.toggleFocusModeNotification, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Typewriter Scrolling") {
                    NotificationCenter.default.post(name: AppDelegate.toggleTypewriterNotification, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Sentence Focus") {
                    NotificationCenter.default.post(name: AppDelegate.toggleSentenceFocusNotification, object: nil)
                }
                Divider()
            }
            CommandGroup(after: .importExport) {
                Button("Export…") {
                    NotificationCenter.default.post(name: AppDelegate.exportNotification, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            // Help menu: real content, not just search (launch ledger L5/L14).
            CommandGroup(replacing: .help) {
                Button("Markdown Guide") {
                    NotificationCenter.default.post(name: AppDelegate.openGuideNotification, object: nil)
                }
                Button("Welcome to Quoin") {
                    NotificationCenter.default.post(name: AppDelegate.openWelcomeNotification, object: nil)
                }
                Divider()
                Button("Report an Issue…") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let os = ProcessInfo.processInfo.operatingSystemVersionString
                    let body = "\n\n—\nQuoin \(version) · macOS \(os)"
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "https://github.com/clintecker/quoin/issues/new?body=\(body)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Quoin ▸ Settings… (⌘,): appearance + editor preferences.
        Settings {
            SettingsView()
        }

        // Quoin ▸ About Quoin: the custom about window.
        Window("About Quoin", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The key window's editing state, published by ReaderScreen so menu
/// titles can follow it (Edit Source ↔ Done Editing).
struct QuoinIsEditingBlockKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var quoinIsEditingBlock: Bool? {
        get { self[QuoinIsEditingBlockKey.self] }
        set { self[QuoinIsEditingBlockKey.self] = newValue }
    }
}

/// Format menu: the formatting grammar as real, discoverable menu items.
/// The Edit Source title follows the focused window's editing state — a
/// menu item that mislabels its action reads as broken.
private struct FormatCommands: Commands {
    @FocusedValue(\.quoinIsEditingBlock) private var isEditingBlock

    private func post(_ name: Notification.Name, format: String? = nil) {
        NotificationCenter.default.post(
            name: name, object: nil,
            userInfo: format.map { ["format": $0] })
    }

    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") { post(AppDelegate.formatNotification, format: "bold") }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { post(AppDelegate.formatNotification, format: "italic") }
                .keyboardShortcut("i", modifiers: .command)
            Button("Highlight") { post(AppDelegate.formatNotification, format: "highlight") }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Add Link") { post(AppDelegate.formatNotification, format: "link") }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Move Block Up") {
                NotificationCenter.default.post(
                    name: AppDelegate.moveBlockNotification, object: nil,
                    userInfo: ["direction": "up"])
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move Block Down") {
                NotificationCenter.default.post(
                    name: AppDelegate.moveBlockNotification, object: nil,
                    userInfo: ["direction": "down"])
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button(isEditingBlock == true ? "Done Editing" : "Edit Source") {
                post(AppDelegate.toggleEditSourceNotification)
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

/// Replaces the standard About item with the custom window. A separate
/// `Commands` type because `openWindow` is only available through the
/// environment.
private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Quoin") { openWindow(id: "about") }
        }
    }
}

/// Handles Finder "Open With Quoin" for individual files.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openDocumentNotification = Notification.Name("quoin.openDocument")
    static let toggleSidebarNotification = Notification.Name("quoin.toggleSidebar")
    static let toggleOutlineNotification = Notification.Name("quoin.toggleOutline")
    static let toggleEditSourceNotification = Notification.Name("quoin.toggleEditSource")
    static let toggleFocusModeNotification = Notification.Name("quoin.toggleFocusMode")
    static let toggleTypewriterNotification = Notification.Name("quoin.toggleTypewriter")
    static let toggleSentenceFocusNotification = Notification.Name("quoin.toggleSentenceFocus")
    static let moveBlockNotification = Notification.Name("quoin.moveBlock")
    static let openGuideNotification = Notification.Name("quoin.openGuide")
    static let openWelcomeNotification = Notification.Name("quoin.openWelcome")
    static let formatNotification = Notification.Name("quoin.format")
    static let undoNotification = Notification.Name("quoin.undo")
    static let redoNotification = Notification.Name("quoin.redo")
    static let exportNotification = Notification.Name("quoin.export")

    /// ⌘Q inside the autosave debounce window used to drop the last
    /// keystrokes — drain every live session before the process dies.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await ReaderModel.flushAllSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quoin has its own document tabs; the system window-tab items
        // ("Show Tab Bar" etc.) would only confuse the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Apply the stored appearance preference (System / Light / Dark).
        // The screenshot-automation pin (-QuoinForceDarkMode YES) wins over
        // the preference inside applyStored, so CI captures stay
        // deterministic.
        AppAppearance.applyStored()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(
                name: Self.openDocumentNotification,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }
}

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}
