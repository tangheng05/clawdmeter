import AppKit
import SwiftUI

/// Clawd for SwiftUI, played by Core Animation like the menu bar icon rather than redrawn by a timer.
struct AnimatedClawd: NSViewRepresentable {
    let mood: Mood
    var sweating = false
    var animate = true

    final class LayerView: NSView {
        var state: [AnyHashable] = []
        var clawd: CALayer?

        override func layout() {
            super.layout()
            clawd?.frame = bounds
        }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        let state: [AnyHashable] = [mood, sweating, animate]
        guard state != view.state else { return }
        view.state = state
        view.clawd?.removeFromSuperlayer()
        let layer = MenuBarIcon.layer(mood, sweating: sweating, animate: animate)
        layer.frame = view.bounds
        view.layer?.addSublayer(layer)
        view.clawd = layer
    }
}
