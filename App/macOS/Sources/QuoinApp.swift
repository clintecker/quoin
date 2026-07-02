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
        .commands {
            // Save is automatic (autosave-in-place); undo lives in the
            // document session, wired via window-local shortcuts.
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}

/// Handles Finder "Open With Quoin" for individual files.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openDocumentNotification = Notification.Name("quoin.openDocument")

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
