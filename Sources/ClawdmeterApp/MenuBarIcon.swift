import AppKit

/// Pixel-art Clawd drawn in code; two frames for the scuttle animation.
@MainActor
enum MenuBarIcon {
    static let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    private static let frames: [[String]] = [
        [
            ".........",
            ".XXXXXXX.",
            ".X.XXX.X.",
            "XXXXXXXXX",
            ".XXXXXXX.",
            ".X.X.X.X.",
        ],
        [
            "X.......X",
            "XXXXXXXXX",
            ".X.XXX.X.",
            ".XXXXXXX.",
            ".XXXXXXX.",
            "..X.X.X.X",
        ],
    ]

    static var frameCount: Int { frames.count }

    private static var cache: [String: NSImage] = [:]

    /// Same footprint as a frame, used as a placeholder while the animated layer is shown.
    static let blank: NSImage = {
        let blank = NSImage(size: MenuBarIcon.image(frame: 0, orange: true).size)
        blank.isTemplate = true
        return blank
    }()

    static func image(frame: Int, orange: Bool) -> NSImage {
        let key = "\(frame)-\(orange)"
        if let cached = cache[key] { return cached }

        let rows = frames[frame % frames.count]
        let scale = 2, pixel = 2 * scale
        let width = rows[0].count * pixel, height = 16 * scale
        let top = (height - rows.count * pixel) / 2
        let color = orange ? claudeOrange : .black
        // Rasterised once, so redrawing the menu bar never re-runs drawing code.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        for (y, row) in rows.enumerated() {
            for (x, char) in row.enumerated() where char == "X" {
                NSRect(x: x * pixel, y: height - top - (y + 1) * pixel, width: pixel, height: pixel).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: width / scale, height: height / scale)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = !orange
        image.accessibilityDescription = "Claude Code status"
        cache[key] = image
        return image
    }
}
