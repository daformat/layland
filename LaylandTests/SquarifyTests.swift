import CoreGraphics
import Testing
@testable import Layland

@Suite("Squarify")
struct SquarifyTests {
    private func check(weights: [Double], bounds: CGRect) {
        let rects = Squarify.layout(weights: weights, in: bounds)
        #expect(rects.count == weights.count)
        let total = weights.reduce(0, +)
        let area = Double(bounds.width * bounds.height)

        for (weight, rect) in zip(weights, rects) {
            let expected = weight / total * area
            #expect(abs(Double(rect.width * rect.height) - expected) < 1e-6 * area + 1e-9,
                    "area of weight \(weight) is \(rect.width * rect.height), expected \(expected)")
            #expect(bounds.insetBy(dx: -1e-6, dy: -1e-6).contains(rect))
        }
        for i in rects.indices {
            for j in rects.indices where i < j {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 1e-6, "rects \(i) and \(j) overlap")
            }
        }
        let covered = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(covered - area) < 1e-6 * area)
    }

    @Test("areas are proportional to weights and fill the bounds")
    func proportionalAreas() {
        check(weights: [6, 6, 4, 3, 2, 2, 1], bounds: CGRect(x: 0, y: 0, width: 600, height: 400))
        check(weights: [100], bounds: CGRect(x: 10, y: 20, width: 30, height: 40))
        check(weights: [5, 5, 5, 5], bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        check(weights: [1000, 1, 1, 1, 1, 1], bounds: CGRect(x: 3, y: 7, width: 1920, height: 1080))
    }

    @Test("a wide range of weights still tiles exactly")
    func wideRange() {
        var weights = (0 ..< 200).map { 1e9 / Double($0 + 1) }
        weights.sort(by: >)
        check(weights: weights, bounds: CGRect(x: 0, y: 0, width: 800, height: 500))
    }

    @Test("classic example matches the paper's layout")
    func classicExample() {
        // Bruls et al., figure 5: 6,6,4,3,2,2,1 in a 6x4 rectangle.
        let rects = Squarify.layout(weights: [6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 6, height: 4))
        let expected: [(CGFloat, CGFloat)] = [(3, 2), (3, 2), (12 / 7, 7 / 3), (9 / 7, 7 / 3), (1.2, 5 / 3), (1.2, 5 / 3), (0.6, 5 / 3)]
        for (rect, size) in zip(rects, expected) {
            #expect(abs(rect.width - size.0) < 1e-9 && abs(rect.height - size.1) < 1e-9, "\(rect) vs \(size)")
        }
    }

    @Test("zero weights and empty input are handled")
    func degenerateInputs() {
        #expect(Squarify.layout(weights: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        let rects = Squarify.layout(weights: [4, 0, 4], in: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(rects[1] == .zero)
        #expect(abs(rects[0].width * rects[0].height - 50) < 1e-9)
        #expect(abs(rects[2].width * rects[2].height - 50) < 1e-9)
        #expect(Squarify.layout(weights: [1, 2], in: .zero).allSatisfy { $0 == .zero })
    }
}
