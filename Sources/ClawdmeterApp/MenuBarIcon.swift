import AppKit

enum Mood: Equatable {
    case asleep, idle, working, waiting, compacting, done
}

/// Clawd drawn from the same half-block shape Claude Code shows in the terminal, so each
/// cell is a tall 1×2 pt pixel. `X` body, `z` snore, `d` sweat drop.
@MainActor
enum MenuBarIcon {
    static let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let dropBlue = NSColor(srgbRed: 0.38, green: 0.70, blue: 0.98, alpha: 1)
    static let pointSize = NSSize(width: 22, height: 16)
    /// Cell size in points; the terminal's half-blocks are twice as tall as they are wide.
    static let cell = CGSize(width: 1, height: 2)

    struct Animation {
        let frames: [[String]]
        let durations: [TimeInterval]
        let repeats: Bool

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
    private static let asleep = [
        "......................",
        "......................",
        "...XXXXXXXXXXXX.......",
        "...XXXXXXXXXXXX.......",
        ".XXXXXXXXXXXXXXXX.....",
        "...XXXXXXXXXXXX.......",
        "....X.X....X.X........",
        "......................",
    ]
    private static let snoring = [
        "..................zzz.",
        "....................z.",
        "...XXXXXXXXXXXX...z...",
        "...XXXXXXXXXXXX...zzz.",
        ".XXXXXXXXXXXXXXXX.....",
        "...XXXXXXXXXXXX.......",
        "....X.X....X.X........",
        "......................",
    ]

    static func animation(_ mood: Mood) -> Animation {
        switch mood {
        case .asleep:
            Animation(frames: [asleep, snoring], durations: [1.6, 1.6], repeats: true)
        case .idle:
            // A blink every few seconds, with an occasional double blink.
            Animation(frames: [base, blink, base, blink, base, blink],
                      durations: [3.6, 0.14, 4.2, 0.12, 0.18, 0.12], repeats: true)
        case .working:
            Animation(frames: [base, scuttle], durations: [0.25, 0.25], repeats: true)
        case .waiting:
            Animation(frames: [wave, base], durations: [0.35, 0.35], repeats: true)
        case .compacting:
            Animation(frames: [base, squish], durations: [0.45, 0.45], repeats: true)
        case .done:
            Animation(frames: [base, hop, base, hop, base], durations: [0.12, 0.16, 0.12, 0.16, 0.5], repeats: true)
        }
    }

    /// A teardrop beside Clawd's head: narrow on top, wide below.
    static func withSweat(_ rows: [String]) -> [String] {
        rows.enumerated().map { y, row in
            let cells: [Int] = y == 2 ? [18] : y == 3 ? [17, 18, 19] : []
            var chars = Array(row)
            for x in cells where chars[x] == "." { chars[x] = "d" }
            return String(chars)
        }
    }

    private static var cache: [String: CGImage] = [:]

    static func cgImage(_ rows: [String], body: NSColor) -> CGImage? {
        let rgb = body.usingColorSpace(.sRGB) ?? body
        let key = rows.joined() + "\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent)"
        if let cached = cache[key] { return cached }

        let scale = 2
        let w = Int(cell.width) * scale, h = Int(cell.height) * scale
        let width = rows[0].count * w, height = rows.count * h
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (y, row) in rows.enumerated() {
            for (x, char) in row.enumerated() {
                let color: NSColor? = switch char {
                case "X": rgb
                case "z": rgb.withAlphaComponent(rgb.alphaComponent * 0.6)
                case "d": dropBlue
                default: nil
                }
                guard let color else { continue }
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x * w, y: height - (y + 1) * h, width: w, height: h))
            }
        }
        let image = context.makeImage()
        cache[key] = image
        return image
    }

    /// Static image, for SwiftUI headers and the like.
    static func image(_ rows: [String]? = nil, orange: Bool = true) -> NSImage {
        let cg = cgImage(rows ?? base, body: orange ? claudeOrange : .black)
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
