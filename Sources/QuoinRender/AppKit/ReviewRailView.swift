#if canImport(AppKit)
import AppKit
import QuoinCore

/// The review rail (suggestions design §3.5, mockup-approved 2026-07-14):
/// comment/suggestion cards in the editor's right margin, hosted INSIDE the
/// text view (document space — cards scroll with their marks), each anchored
/// to its mark's line and stacked without overlap. Cards resolve through the
/// same path as the context menu; ✓/✕ wear the ✓ done capsule grammar.
/// Quoin design language throughout: hairlines on flat surfaces, 40% ink
/// captions, no shadows, no avatars.
final class ReviewRailView: NSView {

    static let railWidth: CGFloat = 250
    static let cardGap: CGFloat = 10
    /// The rail shows only when the window leaves this much room right of
    /// the content; narrower windows collapse it (context menu still works).
    static let minimumWindowWidth: CGFloat = 980

    struct Placed {
        let item: ReviewItem
        /// Document-space Y of the mark's line (the card's ideal top).
        let anchorY: CGFloat
    }

    var onResolve: ((ByteRange, SuggestionResolver.Action) -> Void)?
    /// Card body clicked: bring the mark into view.
    var onFocus: ((ByteRange) -> Void)?

    private var cards: [ReviewCardView] = []
    private(set) var linkedRange: ByteRange?

    override var isFlipped: Bool { true }

    /// Rebuilds the cards. Idempotent per (items, width); geometry-only
    /// changes reuse the card views and just re-stack.
    func update(placed: [Placed], theme: Theme) {
        // Rebuild views when the item list changed; else re-anchor only.
        let itemsChanged = cards.map(\.item) != placed.map(\.item)
        if itemsChanged {
            cards.forEach { $0.removeFromSuperview() }
            cards = placed.map { entry in
                let card = ReviewCardView(item: entry.item, theme: theme)
                card.onResolve = { [weak self] range, action in self?.onResolve?(range, action) }
                card.onFocus = { [weak self] range in self?.onFocus?(range) }
                addSubview(card)
                return card
            }
        }
        var cursor: CGFloat = 0
        for (index, entry) in placed.enumerated() where index < cards.count {
            let card = cards[index]
            let size = card.layoutAndSize(width: Self.railWidth)
            let y = max(entry.anchorY, cursor)
            card.frame = CGRect(x: 0, y: y, width: Self.railWidth, height: size)
            cursor = y + size + Self.cardGap
        }
        setLinked(linkedRange)
        frame.size.height = max(frame.size.height, cursor)
    }

    /// Caret-in-mark linkage: exactly one card highlights.
    func setLinked(_ range: ByteRange?) {
        linkedRange = range
        for card in cards {
            card.setLinked(range != nil && card.item.markRange == range)
        }
    }
}

/// One card. Manual layout (top-origin) — the rail re-stacks per reflow, so
/// Auto Layout would fight the anchoring.
final class ReviewCardView: NSView {

    let item: ReviewItem
    var onResolve: ((ByteRange, SuggestionResolver.Action) -> Void)?
    var onFocus: ((ByteRange) -> Void)?

    private let byLabel = NSTextField(labelWithString: "")
    private let aiBadge = NSTextField(labelWithString: "AI")
    private let atLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private var replyViews: [(hairline: NSView, by: NSTextField, body: NSTextField)] = []
    private let acceptButton = CapsuleButton()
    private let rejectButton = CapsuleButton()
    private let theme: Theme

    override var isFlipped: Bool { true }

    init(item: ReviewItem, theme: Theme) {
        self.item = item
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        byLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        aiBadge.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
        aiBadge.alignment = .center
        aiBadge.wantsLayer = true
        aiBadge.layer?.cornerRadius = 4
        atLabel.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        bodyLabel.font = NSFont.systemFont(ofSize: 11.5)
        bodyLabel.attributedStringValue = Self.bodyText(for: item, theme: theme)
        addSubview(byLabel); addSubview(aiBadge); addSubview(atLabel); addSubview(bodyLabel)

        byLabel.stringValue = item.by ?? Self.kindLabel(for: item)
        aiBadge.isHidden = item.by != "AI"
        atLabel.stringValue = Self.timeLabel(item.at)

        for reply in item.replies {
            let hairline = NSView(); hairline.wantsLayer = true
            let by = NSTextField(labelWithString: reply.by ?? "reply")
            by.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let body = NSTextField(wrappingLabelWithString: reply.body)
            body.font = NSFont.systemFont(ofSize: 11)
            addSubview(hairline); addSubview(by); addSubview(body)
            replyViews.append((hairline, by, body))
        }

        if !item.isResolved {
            if item.isSuggestion {
                acceptButton.configure(title: "✓ Accept", prominent: true, theme: theme)
                rejectButton.configure(title: "✕ Reject", prominent: false, theme: theme)
                acceptButton.onPress = { [weak self] in
                    guard let self else { return }
                    self.onResolve?(self.item.markRange, .accept)
                }
                rejectButton.onPress = { [weak self] in
                    guard let self else { return }
                    self.onResolve?(self.item.markRange, .reject)
                }
                addSubview(acceptButton); addSubview(rejectButton)
            } else {
                rejectButton.configure(title: "✕ Dismiss", prominent: false, theme: theme)
                rejectButton.onPress = { [weak self] in
                    guard let self else { return }
                    self.onResolve?(self.item.markRange, .accept) // comments: remove either way
                }
                addSubview(rejectButton)
            }
        } else {
            alphaValue = 0.55
        }
        applyChrome(linked: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    private static func kindLabel(for item: ReviewItem) -> String {
        switch item.body {
        case .comment: return "Comment"
        case .insertion: return "Insertion"
        case .deletion: return "Deletion"
        case .substitution: return "Replace"
        }
    }

    private static func timeLabel(_ at: String?) -> String {
        guard let at, let date = ISO8601DateFormatter().date(from: at)
            ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: at) }()
        else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func bodyText(for item: ReviewItem, theme: Theme) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: theme.textColor,
        ]
        let output = NSMutableAttributedString()
        func tinted(_ text: String, fill: PlatformColor, strike: Bool = false) -> NSAttributedString {
            var attrs = base
            attrs[.backgroundColor] = fill
            if strike {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = theme.ink.withAlphaComponent(0.55)
            }
            return NSAttributedString(string: text, attributes: attrs)
        }
        switch item.body {
        case .comment(let text, let anchor):
            if let anchor {
                output.append(tinted(anchor, fill: theme.suggestionHighlightFill))
                output.append(NSAttributedString(string: " — ", attributes: base))
            }
            output.append(NSAttributedString(string: text, attributes: base))
        case .insertion(let text):
            output.append(NSAttributedString(string: "Add: ", attributes: base))
            output.append(tinted(text, fill: theme.suggestionInsertFill))
        case .deletion(let text):
            output.append(NSAttributedString(string: "Remove: ", attributes: base))
            output.append(tinted(text, fill: theme.suggestionDeleteFill, strike: true))
        case .substitution(let old, let new):
            output.append(NSAttributedString(string: "Replace: ", attributes: base))
            output.append(tinted(old, fill: theme.suggestionDeleteFill, strike: true))
            output.append(NSAttributedString(string: " with ", attributes: base))
            output.append(tinted(new, fill: theme.suggestionInsertFill))
        }
        return output
    }

    func setLinked(_ linked: Bool) {
        applyChrome(linked: linked)
    }

    private func applyChrome(linked: Bool) {
        layer?.backgroundColor = theme.canvas.cgColor
        layer?.borderColor = linked
            ? theme.accent.cgColor
            : theme.ink.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = linked ? 1.5 : 1
        byLabel.textColor = theme.ink
        aiBadge.textColor = theme.secondaryTextColor
        aiBadge.layer?.backgroundColor = theme.inlineCodeFill.cgColor
        atLabel.textColor = theme.tertiaryTextColor
        for reply in replyViews {
            reply.hairline.layer?.backgroundColor = theme.ink.withAlphaComponent(0.12).cgColor
            reply.by.textColor = theme.ink
            reply.body.textColor = theme.textColor
        }
    }

    /// Lays out subviews for `width`, returns the resulting card height.
    func layoutAndSize(width: CGFloat) -> CGFloat {
        let inset: CGFloat = 11
        let inner = width - inset * 2
        var y: CGFloat = 9

        byLabel.sizeToFit()
        byLabel.frame.origin = CGPoint(x: inset, y: y)
        var metaX = inset + byLabel.frame.width + 5
        if !aiBadge.isHidden {
            aiBadge.sizeToFit()
            aiBadge.frame = CGRect(x: metaX, y: y + 1.5,
                                   width: aiBadge.frame.width + 8, height: 11)
            metaX += aiBadge.frame.width + 6
        }
        atLabel.sizeToFit()
        atLabel.frame.origin = CGPoint(x: metaX, y: y + 2)
        y += byLabel.frame.height + 3

        let bodyHeight = bodyLabel.attributedStringValue
            .boundingRect(with: NSSize(width: inner, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        bodyLabel.frame = CGRect(x: inset, y: y, width: inner, height: ceil(bodyHeight))
        y += ceil(bodyHeight) + 7

        for (index, reply) in replyViews.enumerated() {
            let replyItem = item.replies[index]
            let rx = inset + 9
            let rw = inner - 9
            let startY = y
            reply.by.sizeToFit()
            reply.by.frame.origin = CGPoint(x: rx, y: y)
            y += reply.by.frame.height + 2
            let h = (replyItem.body as NSString).boundingRect(
                with: NSSize(width: rw, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: NSFont.systemFont(ofSize: 11)]).height
            reply.body.frame = CGRect(x: rx, y: y, width: rw, height: ceil(h))
            y += ceil(h) + 6
            reply.hairline.frame = CGRect(x: inset, y: startY, width: 2, height: y - startY - 6)
        }

        if !item.isResolved {
            var bx = inset
            if item.isSuggestion {
                acceptButton.sizeToFitCapsule()
                acceptButton.frame.origin = CGPoint(x: bx, y: y)
                bx += acceptButton.frame.width + 6
            }
            rejectButton.sizeToFitCapsule()
            rejectButton.frame.origin = CGPoint(x: bx, y: y)
            y += rejectButton.frame.height + 9
        } else {
            y += 2
        }
        return y
    }

    override func mouseDown(with event: NSEvent) {
        // Card body click focuses the mark; buttons hit-test first.
        let point = convert(event.locationInWindow, from: nil)
        if acceptButton.superview != nil, acceptButton.frame.contains(point) {
            acceptButton.onPress?(); return
        }
        if rejectButton.superview != nil, rejectButton.frame.contains(point) {
            rejectButton.onPress?(); return
        }
        onFocus?(item.markRange)
    }
}

/// The ✓ done chip grammar as a pressable control: capsule, radius 6,
/// accent-12% fill (prominent) or 7% ink (quiet), 10.5pt medium.
final class CapsuleButton: NSView {
    var onPress: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    func configure(title: String, prominent: Bool, theme: Theme) {
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        label.stringValue = title
        label.textColor = prominent ? theme.accent : theme.secondaryTextColor
        layer?.backgroundColor = prominent
            ? theme.accent.withAlphaComponent(0.12).cgColor
            : theme.ink.withAlphaComponent(0.07).cgColor
        if label.superview == nil { addSubview(label) }
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    func sizeToFitCapsule() {
        label.sizeToFit()
        frame.size = CGSize(width: label.frame.width + 16, height: label.frame.height + 5)
        label.frame.origin = CGPoint(x: 8, y: 2.5)
    }

    override func mouseDown(with event: NSEvent) { onPress?() }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
#endif
