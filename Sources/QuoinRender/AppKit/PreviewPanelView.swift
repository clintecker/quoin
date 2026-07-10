#if canImport(AppKit)
import AppKit

/// The side-by-side live preview for an open diagram/equation (ledger
/// #6b): a floating panel hosted INSIDE the text view at the editing
/// frame's right edge, tracking the frame's drawn geometry. The revealed
/// source wraps to its left (the renderer applies a matching tail
/// indent). Click-transparent — the caret and all editing stay in the
/// source; the panel is presentation only.
final class PreviewPanelView: NSView {

    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignTopRight
        statusLabel.font = NSFont.systemFont(ofSize: 10.5)
        statusLabel.textColor = .systemOrange
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2
        addSubview(imageView)
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // Internal layout in top-origin coordinates, matching the host text view.
    override var isFlipped: Bool { true }

    /// Lays the panel into the editing frame's right column. `frameBox` is
    /// the drawn editing frame in text-view coordinates.
    func present(
        image: NSImage, statusMessage: String?,
        in frameBox: CGRect, panelWidth: CGFloat
    ) {
        let inset: CGFloat = 12
        let chipClearance: CGFloat = 26 // the drawn ✓ done chip's row
        let statusHeight: CGFloat = statusMessage == nil ? 0 : 30
        let x = frameBox.maxX - panelWidth - inset
        let y = frameBox.minY + chipClearance
        let maxHeight = max(24, frameBox.height - chipClearance - 10)

        // Aspect-fit the image into the panel column.
        let imageSize = image.size
        var imageHeight = imageSize.height
        var imageWidth = imageSize.width
        if imageWidth > panelWidth {
            let scale = panelWidth / max(1, imageWidth)
            imageWidth = panelWidth
            imageHeight *= scale
        }
        let availableImageHeight = maxHeight - statusHeight
        if imageHeight > availableImageHeight {
            let scale = availableImageHeight / max(1, imageHeight)
            imageHeight = availableImageHeight
            imageWidth *= scale
        }

        frame = CGRect(x: x, y: y, width: panelWidth,
                       height: min(maxHeight, imageHeight + statusHeight))
        imageView.image = image
        imageView.frame = CGRect(x: panelWidth - imageWidth, y: 0,
                                 width: imageWidth, height: imageHeight)
        statusLabel.stringValue = statusMessage ?? ""
        statusLabel.isHidden = statusMessage == nil
        if statusMessage != nil {
            statusLabel.frame = CGRect(x: 0, y: imageHeight + 4,
                                       width: panelWidth, height: statusHeight - 6)
        }
        isHidden = false
    }
}
#endif
