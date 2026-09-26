import SwiftUI

// Renders the Layland app icon: a macOS squircle holding a small cushion treemap clipped to a
// concentric inner squircle, so the content echoes the system icon shape.
//   swift scripts/makeicon.swift icon_1024.png [scheme] [--bleed]
// --bleed drops the dark frame: the treemap fills the whole squircle.
// Schemes are listed in `schemes` below; the default is the one the app ships with.

/// Squarified layout (same algorithm as the app).
func squarify(_ weights: [Double], in bounds: CGRect) -> [CGRect] {
    var rects = [CGRect](repeating: .zero, count: weights.count)
    var remaining = bounds
    var total = weights.reduce(0, +)
    var start = 0
    while start < weights.count, total > 0 {
        let area = Double(remaining.width * remaining.height)
        let scale = area / total
        let side = Double(min(remaining.width, remaining.height))
        var end = start, rowSum = 0.0, rowMin = Double.infinity, rowMax = 0.0, worst = Double.infinity
        while end < weights.count {
            let item = weights[end] * scale
            let sum = rowSum + item
            let candidate = max(side * side * max(rowMax, item) / (sum * sum), sum * sum / (side * side * min(rowMin, item)))
            if end > start, candidate > worst { break }
            rowSum = sum; rowMin = min(rowMin, item); rowMax = max(rowMax, item); worst = candidate; end += 1
        }
        let thickness = CGFloat(rowSum / side)
        if remaining.width >= remaining.height {
            var y = remaining.minY
            for i in start ..< end { let h = CGFloat(weights[i] * scale / Double(thickness)); rects[i] = CGRect(x: remaining.minX, y: y, width: thickness, height: h); y += h }
            remaining.origin.x += thickness; remaining.size.width -= thickness
        } else {
            var x = remaining.minX
            for i in start ..< end { let w = CGFloat(weights[i] * scale / Double(thickness)); rects[i] = CGRect(x: x, y: remaining.minY, width: w, height: thickness); x += w }
            remaining.origin.y += thickness; remaining.size.height -= thickness
        }
        for i in start ..< end { total -= weights[i] }
        start = end
    }
    return rects
}

/// Color schemes built from the app's Jewel palette, most saturated first (largest cells).
let schemes: [String: [UInt32]] = [
    // Five hues, one each: the shipped icon.
    "jewel": [0xE0A030, 0x2B9EB3, 0x2E9E6B, 0xD64161, 0x3F72AF],
    // Monochrome: one hue, stepped in lightness.
    "mono-blue": [0x3F72AF, 0x6A95D0, 0x2B5288, 0x8FB2E0, 0x1E3B63],
    "mono-teal": [0x2B9EB3, 0x5BBDCD, 0x1D7585, 0x86D2DE, 0x14525D],
    // Two colors: complementary pairs.
    "duo-blue-amber": [0xE0A030, 0x3F72AF, 0xEBBE6A, 0x6A95D0],
    "duo-teal-coral": [0xE07B39, 0x2B9EB3, 0xEB9F6E, 0x5BBDCD],
    // Three colors.
    "trio-cool": [0x2B9EB3, 0x3F72AF, 0x2E9E6B], // analogous
    "trio-triadic": [0xE0A030, 0x2E9E6B, 0xA26BC2], // 38° / 153° / 278°
    "trio-split": [0xE0A030, 0x2B9EB3, 0x5B5FC7], // amber + the two neighbors of its complement
    "trio-warm": [0xE0A030, 0xE07B39, 0xD64161], // analogous
]

/// Walks the cells largest first, giving each the next color of the scheme that no touching,
/// already-colored neighbor has (falls back to the plain cycle if every color is taken).
func assignColors(_ rects: [CGRect], _ scheme: [UInt32]) -> [UInt32] {
    var result: [UInt32] = []
    for (index, rect) in rects.enumerated() {
        let touching = rect.insetBy(dx: -1, dy: -1)
        let taken = Set(rects[..<index].indices.filter { rects[$0].intersects(touching) }.map { result[$0] })
        let start = index % scheme.count
        let order = (0 ..< scheme.count).map { scheme[(start + $0) % scheme.count] }
        result.append(order.first { !taken.contains($0) } ?? order[0])
    }
    return result
}

/// Darkens like the app's cushion shadows: overall by √shade, with the weaker channels falling
/// faster than the dominant one, so the color deepens instead of graying.
func deepened(_ hex: UInt32, shade: Double) -> Color {
    let rgb = [Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)].map { $0 / 255 }
    let peak = max(rgb.max()!, 1e-3)
    let a = (1 - shade) * 1.4
    let c = rgb.map { $0 * shade.squareRoot() * pow(max($0 / peak, 1e-3), a) }
    return Color(.sRGB, red: c[0], green: c[1], blue: c[2])
}

func color(_ hex: UInt32) -> Color {
    Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

/// The outer squircle offset inward by `margin`: a true parallel curve, so the gap is the same
/// everywhere, corners included. (A smaller continuous radius is not concentric: squircle
/// corners don't scale by subtracting from the radius.)
struct InsetSquircle: Shape {
    let outerRadius: CGFloat
    let margin: CGFloat

    func path(in rect: CGRect) -> Path {
        guard margin > 0 else {
            return RoundedRectangle(cornerRadius: outerRadius, style: .continuous).path(in: rect)
        }
        let outer = RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
            .path(in: rect.insetBy(dx: -margin, dy: -margin)).cgPath
        let band = outer.copy(strokingWithWidth: 2 * margin, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        return Path(outer.subtracting(band))
    }
}

struct IconView: View {
    let size: CGFloat = 1024
    // macOS icon grid: the squircle is 824 pt inside the 1024 canvas. macOS 26 masks icons with
    // a continuous corner of ≈ 26 % (fitted against the system-rendered icon); matching it keeps
    // the inner squircle concentric with what's actually on screen.
    let inset: CGFloat = 100
    var squareSize: CGFloat { size - 2 * inset }
    var outerRadius: CGFloat { squareSize * 0.26 }
    var margin: CGFloat = 68

    let weights: [Double] = [30, 22, 14, 11, 8, 7, 5, 4, 3, 3, 2.5, 2, 2, 1.5, 1.5, 1, 1, 1, 0.8, 0.7]
    let scheme: [UInt32]

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
        let inner = InsetSquircle(outerRadius: outerRadius, margin: margin)
        let mapSize = squareSize - 2 * margin
        // Laid out half a gap beyond the map so the outer cells sit flush with the inner squircle
        // (gaps only between cells): the frame is then exactly `margin` wide on sides and corners.
        let gap: CGFloat = 10
        let rects = squarify(weights, in: CGRect(x: 0, y: 0, width: mapSize, height: mapSize).insetBy(dx: -gap / 2, dy: -gap / 2))

        ZStack {
            outer
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.35), radius: 40, y: 12)
            ZStack(alignment: .topLeading) {
                Color(white: 0.06)
                ForEach(Array(zip(rects, assignColors(rects, scheme)).enumerated()), id: \.offset) { _, item in
                    let cell = item.0.insetBy(dx: gap / 2, dy: gap / 2)
                    let base = color(item.1)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(
                            stops: [
                                .init(color: base.mix(with: .white, by: 0.28), location: 0),
                                .init(color: base, location: 0.45),
                                .init(color: deepened(item.1, shade: 0.4), location: 1),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: cell.width, height: cell.height)
                        .offset(x: cell.minX, y: cell.minY)
                }
            }
            .frame(width: mapSize, height: mapSize)
            .clipShape(inner)
            .overlay(inner.stroke(Color.white.opacity(0.10), lineWidth: 6).clipShape(inner))
        }
        .frame(width: squareSize, height: squareSize)
        .frame(width: size, height: size)
    }
}

MainActor.assumeIsolated {
    let options = CommandLine.arguments.dropFirst(2)
    let name = options.first { !$0.hasPrefix("--") } ?? "jewel"
    guard let scheme = schemes[name] else { fatalError("unknown scheme \(name); one of \(schemes.keys.sorted())") }
    var icon = IconView(scheme: scheme)
    if options.contains("--bleed") { icon.margin = 0 }
    let renderer = ImageRenderer(content: icon)
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("ok \(cgImage.width)x\(cgImage.height)")
}
