import AppKit

enum Mood: Equatable {
    case asleep, idle, working, waiting, compacting, done
}

/// Clawd as pixel art. `X` body, `z` snore, `o` shade, `p` pencil, `e` eye.
@MainActor
enum MenuBarIcon {
    static let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let dropBlue = NSColor(srgbRed: 0.38, green: 0.70, blue: 0.98, alpha: 1)
    static let shade = NSColor(srgbRed: 0.745, green: 0.408, blue: 0.302, alpha: 1)
    static let pencil = NSColor(srgbRed: 0.545, green: 0.545, blue: 0.545, alpha: 1)
    static let pointSize = NSSize(width: 36, height: 22)

    /// Most frames use the terminal's half-blocks, 1.5×3 pt cells on a 22×8 grid. Fine frames
    /// are the animated Clawd art at 1 pt per cell. Both fill the menu bar's height.
    struct Sprite: Hashable {
        let rows: [String]
        var fine = false

        /// Cell size and grid origin in pixels of the 2x image.
        var cell: (width: Int, height: Int) { fine ? (2, 2) : (3, 6) }
        /// Centers the body on the menu bar text; the tallest poses lose a row or two at the top.
        var origin: (x: Int, y: Int) { fine ? (3, -8) : (0, -4) }
        /// A teardrop beside Clawd's head, narrow on top, in cells.
        var drop: [CGRect] {
            fine ? [CGRect(x: 22, y: 5, width: 1, height: 2), CGRect(x: 21, y: 7, width: 3, height: 3)]
                 : [CGRect(x: 18, y: 2, width: 1, height: 1), CGRect(x: 17, y: 3, width: 3, height: 1)]
        }
    }

    struct Animation {
        let frames: [Sprite]
        let durations: [TimeInterval]
        let repeats: Bool

        init(_ frames: [[String]], fine: Bool = false, durations: [TimeInterval], repeats: Bool) {
            self.frames = frames.map { Sprite(rows: $0, fine: fine) }
            self.durations = durations
            self.repeats = repeats
        }

        var total: TimeInterval { durations.reduce(0, +) }

        /// The frame showing `elapsed` seconds into the animation.
        func frame(at elapsed: TimeInterval) -> Int {
            var t = repeats ? elapsed.truncatingRemainder(dividingBy: total) : min(elapsed, total)
            for (index, duration) in durations.enumerated() {
                if t < duration { return index }
                t -= duration
            }
            return frames.count - 1
        }
    }

    private static let base = [
        "......................",
        "......................",
        "...XXXXXXXXXXXX.......",
        "...XX.XXXXXX.XX.......",
        ".XXXXXXXXXXXXXXXX.....",
        "...XXXXXXXXXXXX.......",
        "....X.X....X.X........",
        "......................",
    ]
    private static let blink = [
        "......................",
        "......................",
        "...XXXXXXXXXXXX.......",
        "...XXXXXXXXXXXX.......",
        ".XXXXXXXXXXXXXXXX.....",
        "...XXXXXXXXXXXX.......",
        "....X.X....X.X........",
        "......................",
    ]
    private static let scuttle = [
        "......................",
        "......................",
        "...XXXXXXXXXXXX.......",
        ".XXXX.XXXXXX.XXXX.....",
        "...XXXXXXXXXXXX.......",
        "...XXXXXXXXXXXX.......",
        ".....X.X..X.X.........",
        "......................",
    ]
    private static let wave = [
        "......................",
        ".X..............X.....",
        ".XXXXXXXXXXXXXXXX.....",
        "...XX.XXXXXX.XX.......",
        "...XXXXXXXXXXXX.......",
        "...XXXXXXXXXXXX.......",
        "....X.X....X.X........",
        "......................",
    ]
    private static let hop = [
        "......................",
        "...XXXXXXXXXXXX.......",
        ".XXXX.XXXXXX.XXXX.....",
        "...XXXXXXXXXXXX.......",
        "...XXXXXXXXXXXX.......",
        "...X.X......X.X.......",
        "......................",
        "......................",
    ]
    private static let squish = [
        "......................",
        "......................",
        "......................",
        "..XXXXXXXXXXXXXX......",
        "XXXX.XXXXXXXX.XXXX....",
        "..XXXXXXXXXXXXXX......",
        "....X.X....X.X........",
        "......................",
    ]

    static func animation(_ mood: Mood) -> Animation {
        switch mood {
        case .asleep:
            Animation(ClawdArt.sleeping, fine: true, durations: [1.6, 1.6], repeats: true)
        case .idle:
            // A blink every few seconds, with an occasional double blink.
            Animation([base, blink, base, blink, base, blink],
                      durations: [3.6, 0.14, 4.2, 0.12, 0.18, 0.12], repeats: true)
        case .working:
            Animation(ClawdArt.working, fine: true, durations: ClawdArt.workingDurations, repeats: true)
        case .waiting:
            Animation([wave, base], durations: [0.35, 0.35], repeats: true)
        case .compacting:
            Animation([base, squish], durations: [0.45, 0.45], repeats: true)
        case .done:
            Animation([base, hop, base, hop, base], durations: [0.12, 0.16, 0.12, 0.16, 0.5], repeats: true)
        }
    }

    private struct CacheKey: Hashable {
        let sprite: Sprite
        let sweat: Bool
        let color: [CGFloat]
    }

    private static var cache: [CacheKey: CGImage] = [:]

    static func cgImage(_ sprite: Sprite, body: NSColor, sweat: Bool = false) -> CGImage? {
        let rgb = body.usingColorSpace(.sRGB) ?? body
        let key = CacheKey(sprite: sprite, sweat: sweat,
                           color: [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent])
        if let cached = cache[key] { return cached }

        let width = Int(pointSize.width) * 2, height = Int(pointSize.height) * 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Drawn in top-down pixels.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let (w, h) = sprite.cell
        let (left, top) = sprite.origin
        func cell(_ x: Int, _ y: Int, width: Int = 1, height: Int = 1) -> CGRect {
            CGRect(x: left + x * w, y: top + y * h, width: width * w, height: height * h)
        }
        if sweat {
            // Under anything Clawd draws there.
            context.setFillColor(dropBlue.cgColor)
            context.fill(sprite.drop.map { cell(Int($0.minX), Int($0.minY), width: Int($0.width), height: Int($0.height)) })
        }
        let orange = body == claudeOrange
        for (y, row) in sprite.rows.enumerated() {
            for (x, char) in row.enumerated() {
                let color: NSColor? = switch char {
                case "X": rgb
                case "z": rgb.withAlphaComponent(rgb.alphaComponent * 0.6)
                case "o": orange ? shade : rgb.withAlphaComponent(rgb.alphaComponent * 0.7)
                case "p": orange ? pencil : rgb.withAlphaComponent(rgb.alphaComponent * 0.5)
                // Eyes are holes when Clawd matches the menu bar.
                case "e": orange ? .black : nil
                default: nil
                }
                guard let color else { continue }
                context.setFillColor(color.cgColor)
                context.fill(cell(x, y))
            }
        }
        let image = context.makeImage()
        cache[key] = image
        return image
    }

    /// Static image, for SwiftUI headers and the like.
    static func image(_ sprite: Sprite? = nil, sweat: Bool = false, orange: Bool = true) -> NSImage {
        let cg = cgImage(sprite ?? Sprite(rows: base), body: orange ? claudeOrange : .black, sweat: sweat)
        let image = cg.map { NSImage(cgImage: $0, size: pointSize) } ?? NSImage(size: pointSize)
        image.isTemplate = !orange
        return image
    }

    /// Same footprint as a frame; the visible icon is drawn by a layer on top.
    static let blank: NSImage = {
        let blank = NSImage(size: pointSize)
        blank.isTemplate = true
        return blank
    }()
}
