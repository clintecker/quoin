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
    }
}

/// Handles Finder "Open With Quoin" for individual files.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openDocumentNotification = Notification.Name("quoin.openDocument")
    static let toggleSidebarNotification = Notification.Name("quoin.toggleSidebar")
    static let toggleOutlineNotification = Notification.Name("quoin.toggleOutline")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quoin has its own document tabs; the system window-tab items
        // ("Show Tab Bar" etc.) would only confuse the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Screenshot automation: -QuoinForceDarkMode YES pins the app to
        // dark appearance (the AppleInterfaceStyle default doesn't reach
        // SwiftUI apps launched by the UI-test runner).
        if UserDefaults.standard.bool(forKey: "QuoinForceDarkMode") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
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
