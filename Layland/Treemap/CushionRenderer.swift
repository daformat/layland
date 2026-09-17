import CoreGraphics
import Dispatch
import Foundation

/// Rasterises a `TreemapLayout` with cushion shading straight into a pixel buffer.
///
/// Each leaf's surface is the sum of parabolic ridges of all its ancestors, so the surface
/// gradient at a pixel is linear in x and y (the coefficients travel with the cell). Shading is
/// Lambertian from a fixed light. Leaves tile the image, so every pixel is written exactly once
/// and the work parallelises trivially across cells.
enum CushionRenderer {
    struct Lighting: Sendable {
        var ambient: Float = 0.40
        var diffuse: Float = 0.60
        /// Direction towards the light in image space (x right, y down, z out of the screen).
        var direction = SIMD3<Float>(-0.45, -0.45, 0.78)
    }

    private struct Target: @unchecked Sendable {
        let pixels: UnsafeMutablePointer<UInt32>
        let width: Int
        let height: Int
    }

    /// Leaves paint their `layout.paintRect`, so with a margin the background shows through as
    /// an even grid between large cells and around clusters of small ones.
    static func render(_ layout: TreemapLayout, palette: TreemapPalette, lighting: Lighting = Lighting()) -> CGImage? {
        let width = Int(layout.pixelSize.width)
        let height = Int(layout.pixelSize.height)
        guard width > 0, height > 0 else { return nil }
        let count = width * height
        guard let raw = malloc(count * 4) else { return nil }
        let target = Target(pixels: raw.bindMemory(to: UInt32.self, capacity: count), width: width, height: height)
        target.pixels.initialize(repeating: pack(palette.background), count: count)

        let light = lighting.direction / (lighting.direction * lighting.direction).sum().squareRoot()
        // Shade of a flat (untilted) surface: normalising by it keeps flat areas at the palette colour.
        let flatShade = lighting.ambient + lighting.diffuse * light.z
        let cells = layout.cells
        let chunkSize = 1024
        let chunks = (cells.count + chunkSize - 1) / chunkSize
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let start = chunk * chunkSize
            let end = min(start + chunkSize, cells.count)
            for index in start ..< end {
                let cell = cells[index]
                guard cell.isLeaf else { continue }
                if cell.node < 0 {
                    hatch(layout.paintRect(of: cell), color: palette.color(cell.colorSlot), dark: palette.isDark, into: target)
                } else {
                    rasterize(cell, in: layout.paintRect(of: cell), color: palette.color(cell.colorSlot), light: light, lighting: lighting, flatShade: flatShade, into: target)
                }
            }
        }

        guard let provider = CGDataProvider(dataInfo: nil, data: raw, size: count * 4, releaseData: { _, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
        }) else {
            free(raw)
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    @inline(__always)
    private static func pack(_ color: SIMD3<Float>) -> UInt32 {
        let clamped = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 255 + 0.5
        return 0xFF00_0000 | UInt32(clamped.x) << 16 | UInt32(clamped.y) << 8 | UInt32(clamped.z)
    }

    /// Free / other space: flat diagonal hatching in two tones a few percent apart.
    private static func hatch(_ rect: CGRect, color: SIMD3<Float>, dark: Bool, into target: Target) {
        let x0 = max(0, Int(rect.minX)), x1 = min(target.width, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(target.height, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return }
        let a = pack(color)
        let b = pack(color + SIMD3(repeating: dark ? 0.022 : -0.026))
        let period = 14
        for y in y0 ..< y1 {
            let row = target.pixels + y * target.width
            for x in x0 ..< x1 {
                row[x] = ((x + y) / period) & 1 == 0 ? a : b
            }
        }
    }

    /// Highlights blend towards white. Shadows scale by √shade (≈ darkening in linear light) and
    /// let the weaker channels fall faster than the dominant one, like a multiply blend, so they
    /// deepen in saturation instead of turning grey. `logRatio` is log(channel / max channel).
    @inline(__always)
    private static func shaded(_ color: SIMD3<Float>, logRatio: SIMD3<Float>, _ shade: Float) -> SIMD3<Float> {
        if shade >= 1 {
            return color + (SIMD3(repeating: 1) - color) * min(1, (shade - 1) * 1.6)
        }
        let a = (1 - shade) * 1.4
        let tint = SIMD3(exp(a * logRatio.x), exp(a * logRatio.y), exp(a * logRatio.z))
        return color * shade.squareRoot() * tint
    }

    private static func rasterize(_ cell: TreemapCell, in rect: CGRect, color: SIMD3<Float>, light: SIMD3<Float>, lighting: Lighting, flatShade: Float, into target: Target) {
        let x0 = max(0, Int(rect.minX)), x1 = min(target.width, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(target.height, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return }
        let s = cell.cushion
        let peak = max(color.x, max(color.y, color.z), 1e-3)
        let ratio = pointwiseMax(color / peak, SIMD3(repeating: 1e-3))
        let logRatio = SIMD3(log(ratio.x), log(ratio.y), log(ratio.z))

        for y in y0 ..< y1 {
            let ny = -(s.z * (Float(y) + 0.5) + s.w)
            let row = target.pixels + y * target.width
            var nx = -(s.x * (Float(x0) + 0.5) + s.y)
            for x in x0 ..< x1 {
                let dot = nx * light.x + ny * light.y + light.z
                let shade = lighting.ambient + lighting.diffuse * max(0, dot / (nx * nx + ny * ny + 1).squareRoot())
                row[x] = pack(shaded(color, logRatio: logRatio, shade / flatShade))
                nx -= s.x
            }
        }
    }
}

@inline(__always)
private func simd_clamp(_ value: SIMD3<Float>, _ lower: SIMD3<Float>, _ upper: SIMD3<Float>) -> SIMD3<Float> {
    pointwiseMin(pointwiseMax(value, lower), upper)
}
