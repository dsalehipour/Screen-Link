import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Every icon this project has, drawn on demand rather than shipped as a set of PNGs.
///
/// Android asks for a 192 and a 512, iOS wants a 180, browsers want something for the tab, the Mac
/// wants an `.icns` of ten sizes, and the menu bar wants a monochrome template. Rendering all of
/// them from one description keeps them from drifting apart, and keeps binary artwork out of the
/// repository.
///
/// The mark is a pointer inside a screen: seeing the Mac is half of it, driving it is the half worth
/// drawing. Knocking the pointer out of a solid field keeps it legible at 16 px, where an outline
/// within an outline turns to mush. Everything sits inside the middle 75% so Android can mask it to
/// a circle, a squircle or anything else without clipping the glyph.
///
/// The three destinations differ only in their framing, which is not a stylistic choice: a phone
/// masks the artwork itself and must be given full bleed, a Mac icon has to draw its own rounded
/// tile inside a fixed margin or it will look oversized next to every other icon in the Dock, and a
/// menu bar item must be a single-colour silhouette so the system can invert and tint it.
enum AppIcon {
    private static let background = (r: 0.043, g: 0.051, b: 0.063)  // --bg #0b0d10
    private static let accent = (r: 0.247, g: 0.725, b: 0.314)      // --accent #3fb950

    /// A pointer, as a fraction of its own height, tip at the origin.
    private static let pointer: [(CGFloat, CGFloat)] = [
        (0, 0), (0, 0.735), (0.185, 0.575), (0.31, 0.90),
        (0.44, 0.845), (0.315, 0.53), (0.55, 0.515),
    ]

    /// The mark itself, on a 100-unit grid with the origin at the top left. Every renderer below
    /// works from these, so the vector and the raster cannot drift apart.
    private static let screen = (x: CGFloat(20), y: CGFloat(28),
                                 width: CGFloat(60), height: CGFloat(44), radius: CGFloat(8))
    private static let markTip = CGPoint(x: 40, y: 36)
    private static let markHeight = CGFloat(30)

    /// Full bleed, for a phone home screen. The platform applies its own mask.
    static func png(size: Int) -> Data? {
        render(size: size) { context, side in
            let backgroundColor = CGColor(red: background.r, green: background.g, blue: background.b, alpha: 1)
            context.setFillColor(backgroundColor)
            // Square to the edges: rounding here first would leave dark corners outside the mask.
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            drawMark(in: context, rect: CGRect(x: 0, y: 0, width: side, height: side),
                     knockout: backgroundColor)
        }
    }

    /// The Mac's own icon: a rounded tile inside the margin every macOS icon leaves.
    ///
    /// Apple's grid puts the artwork in the middle 824 of a 1024 canvas. An icon that ignores that
    /// and fills the square looks a size too big beside everything else in the Dock and the Finder,
    /// which is the usual tell of an app that drew its icon on some other platform.
    static func macPNG(size: Int) -> Data? {
        render(size: size) { context, side in
            let tile = (CGRect(x: 0, y: 0, width: side, height: side)
                .insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024))
            let radius = tile.width * 185 / 824
            let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

            context.saveGState()
            // Grounds the tile the way the system icons are grounded. Subtle enough to disappear at
            // 16 px, where it would only muddy the edge.
            context.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            context.setFillColor(CGColor(red: background.r, green: background.g, blue: background.b, alpha: 1))
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()

            // A slight lift from top to bottom, so the tile reads as a surface rather than a hole.
            context.saveGState()
            context.addPath(shape)
            context.clip()
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: [
                CGColor(red: 0.106, green: 0.129, blue: 0.157, alpha: 1),
                CGColor(red: background.r, green: background.g, blue: background.b, alpha: 1),
            ] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY),
                                           end: CGPoint(x: 0, y: tile.minY), options: [])
            }
            context.restoreGState()

            drawMark(in: context, rect: tile,
                     knockout: CGColor(red: background.r, green: background.g, blue: background.b, alpha: 1))
        }
    }

    /// The menu bar item: the screen as an outline, the pointer solid inside it.
    ///
    /// Outlined rather than filled because that is the weight of everything else up there. The same
    /// solid mark that carries an app icon becomes a dark slab at 18 points, and reads as a blob
    /// beside the system's own items.
    ///
    /// Returned as a template, which is why it is drawn in flat black — the system inverts it for a
    /// dark menu bar and tints it when the item is highlighted, and any colour baked in here would
    /// survive that and look wrong in half the states.
    static func menuBarGlyph(side: Int) -> CGImage? {
        let box = CGFloat(side)
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let ink = CGColor(gray: 0, alpha: 1)
        // The screen is landscape, so width is the constraint. Height follows it, and the result is
        // centred in the square the menu bar hands over.
        let height = box * 44 / 60
        context.translateBy(x: 0, y: (box - height) / 2 + height)
        context.scaleBy(x: box / 60, y: -height / 44)

        let stroke: CGFloat = 5
        let tip = CGPoint(x: 21, y: 12)
        let pointerSize: CGFloat = 22

        context.setStrokeColor(ink)
        context.setLineWidth(stroke)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 60, height: 44)
            .insetBy(dx: stroke / 2, dy: stroke / 2),
                               cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.strokePath()

        // A gap punched around the pointer, so it stays legible where it would otherwise merge into
        // the frame. At 18 points there is not enough room for them to simply avoid each other.
        context.setBlendMode(.clear)
        context.addPath(pointerPath(tip: tip, height: pointerSize))
        context.setLineWidth(stroke)
        context.strokePath()

        context.setBlendMode(.normal)
        context.setFillColor(ink)
        context.addPath(pointerPath(tip: tip, height: pointerSize))
        context.fillPath()

        return context.makeImage()
    }

    // MARK: - Drawing

    private static func render(size: Int, _ body: (CGContext, CGFloat) -> Void) -> Data? {
        let side = max(16, min(1024, size))
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        body(context, CGFloat(side))

        guard let image = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Draws the screen-and-pointer into `rect`, in the same 100-unit top-left space the SVG uses so
    /// the two cannot drift apart. A nil `knockout` cuts the pointer out to transparency instead of
    /// filling it, which is what a template image needs.
    private static func drawMark(in context: CGContext, rect: CGRect,
                                 fill: CGColor? = nil, knockout: CGColor?) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / 100, y: -rect.height / 100)

        context.setFillColor(fill ?? CGColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: screen.x, y: screen.y,
                                                   width: screen.width, height: screen.height),
                               cornerWidth: screen.radius, cornerHeight: screen.radius, transform: nil))
        context.fillPath()

        if let knockout {
            context.setFillColor(knockout)
        } else {
            context.setBlendMode(.clear)
        }
        context.addPath(pointerPath(tip: markTip, height: markHeight))
        context.fillPath()
        context.restoreGState()
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
            .map { "\(n(markTip.x + $0.0 * markHeight)) \(n(markTip.y + $0.1 * markHeight))" }
            .joined(separator: "L")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">\
        <rect width="100" height="100" rx="22" fill="#0b0d10"/>\
        <rect x="\(n(screen.x))" y="\(n(screen.y))" width="\(n(screen.width))" \
        height="\(n(screen.height))" rx="\(n(screen.radius))" fill="#3fb950"/>\
        <path d="M\(points)Z" fill="#0b0d10"/></svg>
        """
    }

    /// Two decimals at most, and no trailing `.0`. Binary floating point renders coordinates like
    /// `61.349999999999994` otherwise, which is correct and unreadable.
    private static func n(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(describing: rounded)
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
