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
            // Save is automatic (autosave-in-place); undo lives in the
            // document session, wired via window-local shortcuts.
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {}
            AboutCommands()
            // Format menu: the embed-editing keyboard grammar. ⌘↩ toggles
            // the block under the caret between rendered and source
            // (commit-and-close on the way out, same contract as Escape).
            CommandMenu("Format") {
                Button("Edit Source") {
                    NotificationCenter.default.post(
                        name: AppDelegate.toggleEditSourceNotification, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            // View menu: the handoff's panel toggles (⌘0 sidebar, ⌥⌘0
            // outline), delivered to the key window via notifications.
            CommandGroup(before: .sidebar) {
                Button("Show/Hide Sidebar") {
                    NotificationCenter.default.post(name: AppDelegate.toggleSidebarNotification, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
                Button("Show/Hide Outline") {
                    NotificationCenter.default.post(name: AppDelegate.toggleOutlineNotification, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
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
