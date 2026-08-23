import Foundation

/// Renders a curve as ASCII. Four polynomial coefficients cannot be tuned by feel, so this is a
/// first-class part of the tool rather than a debugging aid.
public enum Plot {
    public static func render(
        _ model: CurveModel,
        maxRawSpeed: Double,
        width: Int = 72,
        height: Int = 20
    ) -> String {
        let width = max(20, width)
        let height = max(6, height)

        let samples: [(x: Double, y: Double)] = (0..<width).map { column in
            let raw = maxRawSpeed * Double(column) / Double(width - 1)
            return (raw, model.multiplier(rawSpeed: raw))
        }

        let finite = samples.map(\.y).filter(\.isFinite)
        let maxY = max(finite.max() ?? 1, 1e-9)
        let minY = min(finite.min() ?? 0, 0)
        let span = max(maxY - minY, 1e-9)

        var grid = Array(repeating: Array(repeating: Character(" "), count: width), count: height)

        for (column, sample) in samples.enumerated() {
            guard sample.y.isFinite else {
                // A curve whose parameters drive the square-root radicand negative produces NaN in
                // the kernel too. Showing the gap is more honest than clamping it away.
                grid[height - 1][column] = "?"
                continue
            }
            let fraction = (sample.y - minY) / span
            let row = height - 1 - Int((fraction * Double(height - 1)).rounded())
            grid[min(max(row, 0), height - 1)][column] = "•"
        }

        // Vertical markers where the curve changes segment.
        func mark(_ rawSpeed: Double?, _ character: Character) {
            guard let rawSpeed, rawSpeed > 0, rawSpeed <= maxRawSpeed else { return }
            let column = Int((rawSpeed / maxRawSpeed * Double(width - 1)).rounded())
            guard column >= 0, column < width else { return }
            for row in 0..<height where grid[row][column] == " " {
                grid[row][column] = character
            }
        }
        mark(model.kneeRawSpeed, "|")
        mark(model.taperRawSpeed, ":")

        let labelWidth = 8
        var lines: [String] = []
        for (row, cells) in grid.enumerated() {
            let value = maxY - (maxY - minY) * Double(row) / Double(height - 1)
            let label = String(format: "%\(labelWidth).2f", value)
            lines.append("\(label) ┤\(String(cells))")
        }
        lines.append(String(repeating: " ", count: labelWidth) + " └" + String(repeating: "─", count: width))

        // X axis labels at both ends and the midpoint.
        var axis = Array(repeating: Character(" "), count: labelWidth + 2 + width)
        func place(_ text: String, atColumn column: Int) {
            let start = min(max(labelWidth + 2 + column - text.count / 2, 0), axis.count - text.count)
            for (i, character) in text.enumerated() { axis[start + i] = character }
        }
        place("0", atColumn: 0)
        place(Format.number((maxRawSpeed / 2).rounded()), atColumn: width / 2)
        place(Format.number(maxRawSpeed.rounded()), atColumn: width - 1)
        lines.append(String(axis))

        return lines.joined(separator: "\n")
    }

    /// The legend under the plot: what the axes are and where the segments change.
    public static func legend(_ model: CurveModel) -> String {
        var lines = [
            "  y: pointer multiplier (deltas are scaled by this)",
            "  x: device speed (counts per report)",
            "  acceleration index \(Format.number(model.acceleration)), "
                + "resolution \(Format.number(model.resolution))",
        ]
        if let knee = model.kneeRawSpeed {
            lines.append("  | knee  at \(Format.number(knee.rounded())) — polynomial ramp ends, straight line begins")
        } else {
            lines.append("  no knee (kneeSpeed 0) — the polynomial runs the whole range")
        }
        if let taper = model.taperRawSpeed {
            lines.append("  : taper at \(Format.number(taper.rounded())) — straight line ends, square-root taper begins")
        } else {
            lines.append("  no taper (taperSpeed 0) — nothing flattens the top end")
        }
        return lines.joined(separator: "\n")
    }

    /// A few sampled multipliers, for when exact numbers matter more than the shape.
    public static func table(_ model: CurveModel, maxRawSpeed: Double, rows: Int = 8) -> String {
        var lines = ["  speed   multiplier"]
        for i in 0...rows {
            let raw = maxRawSpeed * Double(i) / Double(rows)
            let m = model.multiplier(rawSpeed: raw)
            let speed = String(format: "%6.1f", raw)
            let multiplier = m.isFinite ? String(format: "%.4f", m) : "NaN"
            lines.append("  \(speed)   \(multiplier)")
        }
        return lines.joined(separator: "\n")
    }
}
