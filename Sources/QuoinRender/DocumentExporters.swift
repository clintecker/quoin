#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreText
import CoreGraphics
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// RTF and PDF exports, produced from the same attributed rendering as the
/// screen (the element spec doubles as the print stylesheet).
public enum DocumentExporters {

    public enum ExportError: Error {
        case conversionFailed
    }

    // MARK: - RTF

    public static func rtf(from document: QuoinDocument, theme: Theme = Theme()) throws -> Data {
        let renderer = AttributedRenderer(theme: theme)
        let rendered = renderer.render(document)
        let range = NSRange(location: 0, length: rendered.attributed.length)
        guard let data = try? rendered.attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            throw ExportError.conversionFailed
        }
        return data
    }

    // MARK: - PDF

    /// US Letter with 54pt margins; CoreText paginates the same attributed
    /// output that the reading surface shows. (Attachment images are not
    /// drawn by CoreText yet — the image-aware pagination pass comes with
    /// print support.)
    public static func pdf(
        from document: QuoinDocument,
        theme: Theme = Theme(),
        title: String = "Document"
    ) throws -> Data {
        let renderer = AttributedRenderer(theme: theme)
        let rendered = renderer.render(document)
        let attributed = rendered.attributed

        var pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 54
        let contentRect = pageRect.insetBy(dx: margin, dy: margin)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &pageRect, [
                kCGPDFContextTitle: title,
                kCGPDFContextCreator: "Quoin",
              ] as CFDictionary)
        else {
            throw ExportError.conversionFailed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        let total = attributed.length

        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            // Always advance; a zero-progress frame (e.g. an oversized
            // attachment) must not loop forever.
            location += max(visible.length, 1)
        } while location < total

        context.closePDF()
        return data as Data
    }
}
#endif
