import AppKit
import ClawdmeterCore
import SwiftUI

@MainActor
final class StatusItemController {
    private struct Appearance: Equatable {
        var animating = false
        var orange = true
        var dimmed = false
        var title = NSAttributedString()
        var tooltip = ""
    }

    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let hosting: NSHostingController<PopoverView>
    private var rendered: Appearance?
    private var staleTimer: Timer?
    private var iconLayer: CALayer?
    private var appearanceObservation: NSKeyValueObservation?

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = []
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hosting
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.restartAnimation() }
        }
        observe()
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        _ = (model.installStatus, model.installError)
        scheduleStaleRefresh()
        render()
        if popover.isShown { DispatchQueue.main.async { self.fitPopover() } }
    }

    private func fitPopover() {
        let size = hosting.sizeThatFits(in: NSSize(width: 320, height: 10_000))
        if popover.contentSize != size { popover.contentSize = size }
    }

    /// One-shot timer at the moment limits go stale, instead of polling.
    private func scheduleStaleRefresh() {
        staleTimer?.invalidate()
        staleTimer = nil
        guard model.showLimit, let limits = model.limits, !limits.isStale() else { return }
        let fireAt = limits.updatedAt.addingTimeInterval(RateLimits.staleAfter + 1)
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    private func render() {
        let appearance = Appearance(
            animating: model.aggregate.state == .working && model.animate,
            orange: model.orangeIcon,
            dimmed: model.sessions.isEmpty,
            title: title(),
            tooltip: tooltip()
        )
        guard appearance != rendered, let button = item.button else { return }
        let old = rendered
        rendered = appearance
        // Only touch what changed: a title change re-lays out the whole status item.
        if old?.animating != appearance.animating || old?.orange != appearance.orange {
            button.image = appearance.animating ? MenuBarIcon.blank : MenuBarIcon.image(frame: 0, orange: appearance.orange)
            restartAnimation()
        }
        if old?.dimmed != appearance.dimmed { button.appearsDisabled = appearance.dimmed }
        if old?.title != appearance.title {
            button.attributedTitle = appearance.title
            if appearance.animating { restartAnimation() }
        }
        if old?.tooltip != appearance.tooltip { button.toolTip = appearance.tooltip }
    }

    /// The scuttle runs as a Core Animation keyframe animation, so the render server
    /// drives it and this process stays asleep while Claude works.
    private func restartAnimation() {
        iconLayer?.removeFromSuperlayer()
        iconLayer = nil
        guard let state = rendered, state.animating, let button = item.button,
              let cell = button.cell as? NSButtonCell else { return }
        button.wantsLayer = true
        button.layoutSubtreeIfNeeded()

        let frames = (0..<MenuBarIcon.frameCount).compactMap {
            MenuBarIcon.image(frame: $0, orange: true).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let layer = CALayer()
        layer.frame = cell.imageRect(forBounds: button.bounds)
        let mask = CALayer()
        mask.frame = layer.bounds
        mask.contentsGravity = .resizeAspect
        mask.contents = frames.first
        layer.mask = mask
        var color = MenuBarIcon.claudeOrange.cgColor
        if !state.orange {
            button.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        }
        layer.backgroundColor = color

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = 0.5
        animation.repeatCount = .infinity
        mask.add(animation, forKey: "scuttle")

        button.layer?.addSublayer(layer)
        iconLayer = layer
    }

    private func title() -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let result = NSMutableAttributedString()
        func append(_ text: String, color: NSColor = .labelColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }

        if model.aggregate.state == .waiting {
            append(" ●", color: .systemYellow)
        }
        if model.showCount, model.sessions.count > 1 {
            append(" \(model.sessions.count)")
        }
        if model.showLimit, let five = model.limits?.fiveHour {
            let stale = model.limits?.isStale() ?? true
            let color: NSColor = stale ? .tertiaryLabelColor : five.usedPercentage >= 80 ? .systemRed : .labelColor
            append(" \(Int(five.usedPercentage.rounded(.down)))%", color: color)
        }
        return result
    }

    private func tooltip() -> String {
        switch model.aggregate.state {
        case .waiting: "Claude needs you"
        case .working: "Claude is working"
        case .idle: model.sessions.isEmpty ? "No Claude Code sessions" : "Claude is idle"
        }
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.reload()
            fitPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
