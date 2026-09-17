import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
///
/// Items are laid out in rows along the shorter side of the remaining rectangle; a row is closed
/// as soon as adding the next item would worsen the row's worst aspect ratio. Weights must be
/// sorted in descending order for the classic near-square result.
enum Squarify {
    /// Returns one rectangle per weight, in the same order. Weights must be non-negative;
    /// zero-weight items get an empty rectangle.
    static func layout(weights: [Double], in bounds: CGRect) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: weights.count)
        var remaining = bounds
        var total = weights.reduce(0, +)
        var start = 0

        while start < weights.count, total > 0 {
            let area = Double(remaining.width * remaining.height)
            guard area > 0 else { break }
            let scale = area / total
            let side = Double(min(remaining.width, remaining.height))

            // Grow the row while the worst aspect ratio keeps improving.
            var end = start
            var rowSum = 0.0, rowMin = Double.infinity, rowMax = 0.0
            var worst = Double.infinity
            while end < weights.count {
                let item = weights[end] * scale
                guard item > 0 else { end += 1; continue }
                let sum = rowSum + item
                let candidate = max(side * side * max(rowMax, item) / (sum * sum), sum * sum / (side * side * min(rowMin, item)))
                if end > start, candidate > worst { break }
                rowSum = sum
                rowMin = min(rowMin, item)
                rowMax = max(rowMax, item)
                worst = candidate
                end += 1
            }
            if end == start { break }

            // Lay the row out as a strip along the shorter side.
            let thickness = CGFloat(rowSum / side)
            if remaining.width >= remaining.height {
                var y = remaining.minY
                for index in start ..< end {
                    guard weights[index] > 0 else { continue }
                    let height = CGFloat(weights[index] * scale / Double(thickness))
                    rects[index] = CGRect(x: remaining.minX, y: y, width: thickness, height: height)
                    y += height
                }
                remaining.origin.x += thickness
                remaining.size.width -= thickness
            } else {
                var x = remaining.minX
                for index in start ..< end {
                    guard weights[index] > 0 else { continue }
                    let width = CGFloat(weights[index] * scale / Double(thickness))
                    rects[index] = CGRect(x: x, y: remaining.minY, width: width, height: thickness)
                    x += width
                }
                remaining.origin.y += thickness
                remaining.size.height -= thickness
            }

            for index in start ..< end { total -= weights[index] }
            start = end
        }
        return rects
    }
}
