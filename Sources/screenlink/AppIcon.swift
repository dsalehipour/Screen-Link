import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The home-screen icon, drawn on demand rather than shipped as a set of PNGs.
///
/// Android asks for a 192 and a 512, iOS wants a 180, and browsers want something for the tab.
/// Rendering from one description keeps those from drifting apart, and keeps binary artwork out of
/// the repository.
///
/// The mark is a pointer inside a screen: seeing the Mac is half of it, driving it is the half worth
/// drawing. Knocking the pointer out of a solid field keeps it legible at 16 px, where an outline
/// within an outline turns to mush. Everything sits inside the middle 75% so Android can mask it to
/// a circle, a squircle or anything else without clipping the glyph.
enum AppIcon {
    private static let background = (r: 0.043, g: 0.051, b: 0.063)  // --bg #0b0d10
    private static let accent = (r: 0.247, g: 0.725, b: 0.314)      // --accent #3fb950

    /// A pointer, as a fraction of its own height, tip at the origin.
    private static let pointer: [(CGFloat, CGFloat)] = [
        (0, 0), (0, 0.735), (0.185, 0.575), (0.31, 0.90),
        (0.44, 0.845), (0.315, 0.53), (0.55, 0.515),
    ]

    static func png(size: Int) -> Data? {
        let side = max(16, min(1024, size))
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        draw(in: context, side: CGFloat(side))

        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    private static func draw(in context: CGContext, side: CGFloat) {
        let backgroundColor = CGColor(red: background.r, green: background.g, blue: background.b, alpha: 1)
        context.setFillColor(backgroundColor)
        // Square to the edges: the platform applies its own mask, and rounding here first would
        // leave dark corners outside it.
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        // Drawn in the same top-left origin the SVG uses, so the two cannot drift apart.
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: side / 100, y: -side / 100)

        context.setFillColor(CGColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 20, y: 28, width: 60, height: 44),
                               cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()

        context.setFillColor(backgroundColor)
        context.addPath(pointerPath(tip: CGPoint(x: 40, y: 36), height: 30))
        context.fillPath()
    }

    private static func pointerPath(tip: CGPoint, height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for (index, point) in pointer.enumerated() {
            let at = CGPoint(x: tip.x + point.0 * height, y: tip.y + point.1 * height)
            index == 0 ? path.move(to: at) : path.addLine(to: at)
        }
        path.closeSubpath()
        return path
    }

    /// The same mark for the browser tab, where a vector stays crisp at 16 px and costs nothing.
    /// Rounded here because nothing masks a favicon.
    static var svg: String {
        let points = pointer
            .map { "\(50 - 10 + $0.0 * 30) \(36 + $0.1 * 30)" }
            .joined(separator: "L")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\
        <rect width="100" height="100" rx="22" fill="#0b0d10"/>\
        <rect x="20" y="28" width="60" height="44" rx="8" fill="#3fb950"/>\
        <path d="M\(points)Z" fill="#0b0d10"/></svg>
        """
    }

    /// Declared `any maskable` so Android uses it as an adaptive icon instead of dropping a squished
    /// square onto a white circle. `start_url` carries no token: a device that has been approved
    /// once presents its own credential, which is what launching from the home screen relies on.
    static func manifest() -> [String: Any] {
        [
            "name": "screenlink",
            "short_name": "screenlink",
            "description": "See and control your Mac",
            "start_url": "/",
            "scope": "/",
            "display": "standalone",
            "background_color": "#0b0d10",
            "theme_color": "#14181d",
            "icons": [192, 512].map { size in
                [
                    "src": "/icon-\(size).png",
                    "sizes": "\(size)x\(size)",
                    "type": "image/png",
                    "purpose": "any maskable",
                ]
            },
        ]
    }
}
