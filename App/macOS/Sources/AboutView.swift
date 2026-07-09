import AppKit
import SwiftUI

/// The custom About window (Quoin ▸ About Quoin). More context than the
/// standard panel: what Quoin is, the engines inside it, and where the
/// pieces live.
struct AboutView: View {

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, build != short { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)

            VStack(spacing: 3) {
                Text("Quoin")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(version)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("A native WYSIWYG markdown editor.\nPlain files on disk — no lock-in, no cloud, no JavaScript.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 260)

            VStack(alignment: .leading, spacing: 6) {
                engineRow("Markdown", "swift-markdown (cmark-gfm), byte-lossless round-trip")
                engineRow("Diagrams", "MermaidKit — native Mermaid rendering, all 30 diagram types")
                engineRow("Math", "native math typesetting, no web view")
                engineRow("Text", "TextKit 2, SF Pro Rounded")
            }
            .font(.system(size: 11))

            Divider()
                .frame(width: 260)

            VStack(spacing: 4) {
                Link("MermaidKit on GitHub", destination: URL(string: "https://github.com/clintecker/MermaidKit")!)
                    .font(.system(size: 11))
                Text("© 2026 Clint Ecker")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 360)
        .fixedSize()
    }

    private func engineRow(_ label: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .fontWeight(.semibold)
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(detail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
