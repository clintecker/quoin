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

extension DiagramRenderer {

    static func draw(_ layout: GanttLayout, theme: Theme, in context: CGContext) {
        if let title = layout.title {
            drawText(title, center: CGPoint(x: layout.size.width / 2, y: 14),
                     size: 12.5, weight: .semibold, color: theme.ink, in: context)
        }

        // Section tint bands behind everything, in the section's palette color.
        for band in layout.sections {
            context.saveGState()
            context.setFillColor(resolvedCGColor(categoricalColor(band.colorIndex).withAlphaComponent(0.10)))
            context.fill(band.frame)
            context.restoreGState()
        }

        // Day grid: hairline verticals with a small index label at the base.
        for tick in layout.ticks {
            context.saveGState()
            context.setStrokeColor(resolvedCGColor(theme.hairline))
            context.setLineWidth(1)
            context.beginPath()
            context.move(to: CGPoint(x: tick.x, y: tick.top))
            context.addLine(to: CGPoint(x: tick.x, y: tick.bottom))
            context.strokePath()
            context.restoreGState()
            drawText(tick.label, center: CGPoint(x: tick.x, y: tick.bottom + 9),
                     size: 9, color: theme.tertiaryTextColor, in: context)
        }

        for bar in layout.bars {
            // Task label, right-aligned into the gutter.
            let measured = measure(bar.label, size: labelSize)
            drawText(bar.label,
                     center: CGPoint(x: bar.labelPoint.x - measured.width / 2, y: bar.labelPoint.y),
                     size: labelSize, color: theme.secondaryTextColor, in: context)

            let fill = ganttFill(bar.status, theme: theme)
            context.saveGState()
            context.setFillColor(resolvedCGColor(fill))
            if bar.isMilestone {
                // A diamond centered in the bar's box.
                let f = bar.frame
                context.beginPath()
                context.move(to: CGPoint(x: f.midX, y: f.minY))
                context.addLine(to: CGPoint(x: f.maxX, y: f.midY))
                context.addLine(to: CGPoint(x: f.midX, y: f.maxY))
                context.addLine(to: CGPoint(x: f.minX, y: f.midY))
                context.closePath()
                context.fillPath()
            } else {
                context.addPath(CGPath(roundedRect: bar.frame, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
                if bar.status == .critical {
                    context.setStrokeColor(resolvedCGColor(PlatformColor.systemRed))
                    context.setLineWidth(1.5)
                    context.addPath(CGPath(roundedRect: bar.frame.insetBy(dx: 0.75, dy: 0.75),
                                           cornerWidth: 3, cornerHeight: 3, transform: nil))
                    context.strokePath()
                }
            }
            context.restoreGState()
        }
    }
}
#endif
