import AppKit
import ClawdmeterCore
import SwiftUI

@MainActor
final class StatusItemController {
    private struct Appearance: Equatable {
        var mood = Mood.asleep
        var sweating = false
        var animate = true
        var orange = true
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
    private var outsideClickMonitor: Any?
    private var lastClosed = Date.distantPast
    private var menuOpen = false
    private let hotKey = HotKey()

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
        item.button?.image = MenuBarIcon.blank
        // Resizing the popover while the gear menu is open makes macOS close the menu.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuOpen = false
                if self?.popover.isShown == true { self?.fitPopover() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastClosed = .now
                self?.stopWatchingOutsideClicks()
            }
        }
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }
        HotKey.action = { [weak self] in
            NSApp.activate()
            self?.toggle()
        }
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
        _ = (model.installStatus, model.installError, model.updater.available, model.updater.status)
        hotKey.register(model.shortcut)
        scheduleStaleRefresh()
        render()
        if popover.isShown { DispatchQueue.main.async { self.fitPopover() } }
    }

    private func fitPopover() {
        guard !menuOpen else { return }
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
            mood: model.mood,
            sweating: model.sweating,
            animate: model.animate,
            orange: model.orangeIcon,
            title: title(),
            tooltip: tooltip()
        )
        guard appearance != rendered, let button = item.button else { return }
        let old = rendered
        rendered = appearance
        // Only touch what changed: a title change re-lays out the whole status item.
        if old?.title != appearance.title { button.attributedTitle = appearance.title }
        if old?.tooltip != appearance.tooltip { button.toolTip = appearance.tooltip }
        if old?.mood != appearance.mood || old?.sweating != appearance.sweating || old?.animate != appearance.animate
            || old?.orange != appearance.orange || old?.title != appearance.title {
            restartAnimation()
        }
    }

    /// Clawd is drawn by a layer whose frames are a Core Animation keyframe animation,
    /// so the render server drives every mood and this process stays asleep.
    private func restartAnimation() {
        iconLayer?.removeFromSuperlayer()
        iconLayer = nil
        guard let state = rendered, let button = item.button, let cell = button.cell as? NSButtonCell else { return }
        button.wantsLayer = true
        button.layoutSubtreeIfNeeded()

        var body = MenuBarIcon.claudeOrange
        if !state.orange {
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                body = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
            }
        }
        let animation = MenuBarIcon.animation(state.mood)
        let frames = animation.frames
            .map { state.sweating ? MenuBarIcon.withSweat($0) : $0 }
            .compactMap { MenuBarIcon.cgImage($0, body: body) }

        let layer = CALayer()
        layer.frame = cell.imageRect(forBounds: button.bounds)
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .nearest
        layer.contents = frames.first
        layer.opacity = state.mood == .asleep ? 0.45 : 1

        if state.animate, frames.count > 1 {
            let keyframes = CAKeyframeAnimation(keyPath: "contents")
            keyframes.values = frames
            keyframes.calculationMode = .discrete
            keyframes.duration = animation.frameDuration * Double(frames.count)
            keyframes.repeatCount = animation.repeats ? .infinity : 1
            keyframes.isRemovedOnCompletion = false
            keyframes.fillMode = .forwards
            layer.add(keyframes, forKey: "mood")
        }

        button.layer?.addSublayer(layer)
        iconLayer = layer
    }

    private func title() -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let result = NSMutableAttributedString()
        func append(_ text: String, color: NSColor = .labelColor) {
            let spaced = result.length == 0 ? text : " " + text
            result.append(NSAttributedString(string: spaced, attributes: [.font: font, .foregroundColor: color]))
        }

        if model.aggregate.state == .waiting {
            append("●", color: .systemYellow)
        }
        if model.showCount, model.sessions.count > 1 {
            append("\(model.sessions.count)")
        }
        if model.showLimit, let limits = model.limits, let headline = limits.headline {
            let used = headline.window.usedPercentage
            let color: NSColor = limits.isStale() ? .tertiaryLabelColor
                : used >= 90 ? .systemRed : used >= 70 ? .systemOrange : .labelColor
            append("\(headline.label) \(Int(used.rounded(.down)))%", color: color)
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
            // A click on the icon first closes the popover (it's outside it), then fires this
            // action; reopening right away would make it flicker, so treat it as the close.
            guard Date.now.timeIntervalSince(lastClosed) > 0.3 else { return }
            model.reload()
            fitPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            watchOutsideClicks()
        }
    }

    /// After the gear menu closes, the popover is no longer key and `.transient` stops
    /// dismissing it, so clicks in other apps close it explicitly while it's open.
    private func watchOutsideClicks() {
        stopWatchingOutsideClicks()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }
}
