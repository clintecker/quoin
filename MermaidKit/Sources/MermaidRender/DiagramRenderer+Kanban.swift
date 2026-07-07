#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreText
import CoreGraphics
import MermaidLayout

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension DiagramRenderer {

    static func draw(_ layout: KanbanLayout, theme: DiagramTheme, in context: CGContext) {
        // Column headers: tinted pill with the column title.
        for column in layout.columns {
            let tint = categoricalColor(column.colorIndex)
            context.saveGState()
            context.setFillColor(resolvedCGColor(tint.withAlphaComponent(0.22)))
            context.addPath(CGPath(roundedRect: column.headerFrame, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            context.restoreGState()
            drawText(column.title,
                     center: CGPoint(x: column.headerFrame.midX, y: column.headerFrame.midY + 1),
                     size: 11.5, weight: .semibold, color: theme.ink, in: context)
        }

        // Cards: a subtle card body with a coloured left rail, wrapped text,
        // and an optional ticket chip at the bottom.
        for card in layout.cards {
            let tint = categoricalColor(card.colorIndex)
            context.saveGState()
            context.setFillColor(resolvedCGColor(theme.ink.withAlphaComponent(0.05)))
            context.addPath(CGPath(roundedRect: card.frame, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            // Left accent rail.
            context.setFillColor(resolvedCGColor(tint.withAlphaComponent(0.85)))
            context.fill(CGRect(x: card.frame.minX, y: card.frame.minY + 4, width: 3, height: card.frame.height - 8))
            context.restoreGState()

            var textY = card.frame.minY + 9 + 7
            for line in card.lines {
                drawTextLeft(line, at: CGPoint(x: card.frame.minX + 12, y: textY),
                             size: 11, color: theme.ink, in: context)
                textY += 15
            }
            if let ticket = card.ticket {
                drawTextLeft(ticket, at: CGPoint(x: card.frame.minX + 12, y: card.frame.maxY - 9),
                             size: 8.5, weight: .medium, color: theme.tertiaryTextColor, in: context)
            }
        }
    }
}
#endif
