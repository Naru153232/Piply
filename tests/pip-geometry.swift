import AppKit

@main
struct GeometryTests {
    @MainActor
    static func main() {
        let maximum = CGSize(width: 1920, height: 1080)
        let cases: [(CGSize, CGFloat, CGSize)] = [
            (CGSize(width: 1920, height: 1080), 480, CGSize(width: 480, height: 270)),
            (CGSize(width: 600, height: 1200), 480, CGSize(width: 480, height: 960)),
            (CGSize(width: 300, height: 1800), 480, CGSize(width: 180, height: 1080)),
            (CGSize(width: 2400, height: 600), 480, CGSize(width: 480, height: 120)),
            (CGSize(width: 1000, height: 1000), 480, CGSize(width: 480, height: 480))
        ]
        for (source, width, expected) in cases {
            let result = PiPGeometry.fittedSize(source: source, preferredWidth: width, maximum: maximum)!
            precondition(abs(result.width - expected.width) < 0.001)
            precondition(abs(result.height - expected.height) < 0.001)
            precondition(abs(result.width / result.height - source.width / source.height) < 0.00001)
        }
        precondition(PiPGeometry.fittedSize(source: .zero, preferredWidth: 480, maximum: maximum) == nil)
        let enlarged = PiPGeometry.fittedSize(source: CGSize(width: 1920, height: 1080), preferredWidth: 3840)!
        precondition(enlarged == CGSize(width: 3840, height: 2160))
        print("PiP geometry: 7 cases passed")
    }
}
