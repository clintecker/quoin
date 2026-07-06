import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramLayoutEngine {

    /// Lays out a packet diagram on a 32-bit grid: each field is a box spanning
    /// its bit range, wrapping into row segments when it crosses a 32-bit
    /// boundary. Pure geometry — the renderer only draws.
    public static func layout(_ packet: PacketDiagram, measure: DiagramTextMeasurer) -> PacketLayout {
        let bitsPerRow = 32
        let margin: CGFloat = 14
        let titleHeight: CGFloat = packet.title == nil ? 0 : 26
        let bitWidth: CGFloat = 19
        let rowHeight: CGFloat = 38
        let rowGap: CGFloat = 6
        let top = margin + titleHeight

        var segments: [PacketLayout.Segment] = []
        var maxRow = 0
        for (index, field) in packet.fields.enumerated() {
            var bit = field.startBit
            while bit <= field.endBit {
                let row = bit / bitsPerRow
                let col = bit % bitsPerRow
                let segmentEnd = min(field.endBit, row * bitsPerRow + bitsPerRow - 1)
                let cells = segmentEnd - bit + 1
                let frame = CGRect(
                    x: margin + CGFloat(col) * bitWidth,
                    y: top + CGFloat(row) * (rowHeight + rowGap),
                    width: CGFloat(cells) * bitWidth,
                    height: rowHeight
                )
                let showLabel = frame.width >= measure(field.label, labelFontSize).width + 6
                segments.append(PacketLayout.Segment(
                    label: field.label, showLabel: showLabel, frame: frame,
                    startBit: bit, endBit: segmentEnd, colorIndex: index
                ))
                maxRow = max(maxRow, row)
                bit = segmentEnd + 1
            }
        }

        let width = margin + CGFloat(bitsPerRow) * bitWidth + margin
        let height = top + CGFloat(maxRow + 1) * (rowHeight + rowGap) - rowGap + margin

        return PacketLayout(
            size: CGSize(width: width, height: height),
            title: packet.title,
            bitsPerRow: bitsPerRow,
            segments: segments
        )
    }
}
