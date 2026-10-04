import AppKit

enum Mood: Equatable {
    case asleep, idle, working, waiting, done
}

/// Pixel-art Clawd drawn in code. `X` body, `z` snore, `d` sweat drop.
@MainActor
enum MenuBarIcon {
    static let claudeOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let dropBlue = NSColor(srgbRed: 0.38, green: 0.70, blue: 0.98, alpha: 1)
    static let pointSize = NSSize(width: 22, height: 16)

    struct Animation {
        let frames: [[String]]
        let frameDuration: TimeInterval
        let repeats: Bool
    }

    private static let base = [
        "...........",
        "...........",
        ".XXXXXXX...",
        ".X.XXX.X...",
        "XXXXXXXXX..",
        ".XXXXXXX...",
        ".X.X.X.X...",
        "...........",
    ]
    private static let scuttle = [
        "...........",
        "X.......X..",
        "XXXXXXXXX..",
        ".X.XXX.X...",
        ".XXXXXXX...",
        ".XXXXXXX...",
        "..X.X.X.X..",
        "...........",
    ]
    private static let armsUp = [
        "...........",
        "X.......X..",
        "XXXXXXXXX..",
        ".X.XXX.X...",
        ".XXXXXXX...",
        ".XXXXXXX...",
        ".X.X.X.X...",
        "...........",
    ]
    private static let eyesClosed = [
        "...........",
        "...........",
        ".XXXXXXX...",
        ".XXXXXXX...",
        "XXXXXXXXX..",
        ".XXXXXXX...",
        ".X.X.X.X...",
        "...........",
    ]
    private static let snoring = [
        "........zzz",
        ".........z.",
        ".XXXXXXXzzz",
        ".XXXXXXX...",
        "XXXXXXXXX..",
        ".XXXXXXX...",
        ".X.X.X.X...",
        "...........",
    ]
    private static let hop = [
        "...........",
        ".XXXXXXX...",
        ".X.XXX.X...",
        "XXXXXXXXX..",
        ".XXXXXXX...",
        ".X.....X...",
        "...........",
        "...........",
    ]

    static func animation(_ mood: Mood) -> Animation {
        switch mood {
        case .asleep: Animation(frames: [base], frameDuration: 1, repeats: false)
        case .idle: Animation(frames: [eyesClosed, snoring], frameDuration: 1.4, repeats: true)
        case .working: Animation(frames: [base, scuttle], frameDuration: 0.25, repeats: true)
        case .waiting: Animation(frames: [armsUp, base], frameDuration: 0.35, repeats: true)
        case .done: Animation(frames: [base, hop, base, hop, base], frameDuration: 0.16, repeats: false)
        }
    }

    static func withSweat(_ rows: [String]) -> [String] {
        rows.enumerated().map { y, row in
            guard y == 2 || y == 3 else { return row }
            var chars = Array(row)
            if chars[9] == "." { chars[9] = "d" }
            return String(chars)
        }
    }

    private static var cache: [String: CGImage] = [:]

    static func cgImage(_ rows: [String], body: NSColor) -> CGImage? {
        let rgb = body.usingColorSpace(.sRGB) ?? body
        let key = rows.joined() + "\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent)"
        if let cached = cache[key] { return cached }

        let scale = 2, pixel = 2 * scale
        let width = rows[0].count * pixel, height = rows.count * pixel
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
                context.fill(CGRect(x: x * pixel, y: height - (y + 1) * pixel, width: pixel, height: pixel))
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
