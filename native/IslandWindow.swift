import AppKit
import QuartzCore

enum IslandExpansionMode: String, CaseIterable {
    case hover, click, pinned

    var title: String {
        switch self {
        case .hover: return "悬停展开"
        case .click: return "仅点击"
        case .pinned: return "固定展开"
        }
    }
}

struct IslandScreenOption: Equatable {
    let id: String
    let title: String
}

struct IslandPosition: Codable, Equatable {
    var horizontalFraction: Double = 0.5
    var topOffset: Double = 8
}

/// Screen-independent placement rules, also used by the layout regression checks.
enum IslandPlacement {
    static func frame(in safe: NSRect, width: CGFloat, expanded: Bool, position: IslandPosition) -> NSRect {
        let width = min(width, max(1, safe.width - 16))
        let height = min(expanded ? 204.0 : 46.0, max(1, safe.height - 16))
        let fraction = position.horizontalFraction.isFinite ? min(1, max(0, position.horizontalFraction)) : 0.5
        let offset = position.topOffset.isFinite ? max(8, position.topOffset) : 8
        let target = NSRect(x: safe.minX + safe.width * fraction - width / 2,
                            y: safe.maxY - offset - height, width: width, height: height)
        return constrained(target, to: safe)
    }

    static func constrained(_ frame: NSRect, to safe: NSRect) -> NSRect {
        let x = min(max(safe.minX + 8, frame.minX), max(safe.minX + 8, safe.maxX - 8 - frame.width))
        let y = min(max(safe.minY + 8, frame.minY), max(safe.minY + 8, safe.maxY - 8 - frame.height))
        return NSRect(x: x.rounded(), y: y.rounded(), width: frame.width, height: frame.height)
    }

    static func position(afterDragging frame: NSRect, in safe: NSRect) -> IslandPosition {
        var target = frame
        if abs(safe.maxY - frame.maxY - 8) <= 28 {
            target.origin.y = safe.maxY - 8 - frame.height
            if abs(frame.midX - safe.midX) <= 28 { target.origin.x = safe.midX - frame.width / 2 }
        }
        target = constrained(target, to: safe)
        return IslandPosition(horizontalFraction: Double((target.midX - safe.minX) / max(1, safe.width)),
                              topOffset: Double(safe.maxY - target.maxY))
    }
}

private struct IslandContent: Equatable {
    let text, title, state, previous, next: String
    let connected, paused: Bool
    let rate: Double
}

enum IslandTheme: String, CaseIterable {
    case graphite
    case ocean
    case forest
    case rose
    case amber

    var title: String {
        switch self {
        case .graphite: return "暗夜"
        case .ocean: return "海蓝"
        case .forest: return "森青"
        case .rose: return "玫瑰"
        case .amber: return "琥珀"
        }
    }

    var tint: NSColor {
        switch self {
        case .graphite: return NSColor(srgbRed: 0.018, green: 0.022, blue: 0.03, alpha: 1)
        case .ocean: return NSColor(srgbRed: 0.008, green: 0.065, blue: 0.11, alpha: 1)
        case .forest: return NSColor(srgbRed: 0.008, green: 0.075, blue: 0.045, alpha: 1)
        case .rose: return NSColor(srgbRed: 0.10, green: 0.012, blue: 0.052, alpha: 1)
        case .amber: return NSColor(srgbRed: 0.105, green: 0.05, blue: 0.006, alpha: 1)
        }
    }

    var accent: NSColor {
        switch self {
        case .graphite: return .systemBlue
        case .ocean: return .systemCyan
        case .forest: return .systemGreen
        case .rose: return .systemPink
        case .amber: return .systemOrange
        }
    }
}

private final class IslandPanel: CaptionGlassPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IslandRootView: NSView {
    private let surface = NSVisualEffectView()
    private let tint = NSView()
    private let contentContainer = NSView()
    private weak var nativeGlass: NSView?
    private let brand = NSTextField(labelWithString: "B 站")
    private let brandBackground = NSView()
    private let statusDot = NSView()
    private let status = NSTextField(labelWithString: "等待连接")
    private let title = NSTextField(labelWithString: "")
    private let previous = NSTextField(labelWithString: "")
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let next = NSTextField(labelWithString: "")
    private let playbackButton = NSButton()
    private let speedButton = NSButton()
    private let divider = NSView()
    private let dragHint = NSTextField(labelWithString: "拖动调整位置")
    private var hoverArea: NSTrackingArea?
    private var controlPending = false
    private var currentRate: Double = 1
    private var lastContent: IslandContent?
    private var pointerOrigin: NSPoint?
    private var didDrag = false

    var onHover: ((Bool) -> Void)?
    var onPointerBegan: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onPointerEnded: ((Bool, NSPoint) -> Void)?
    var onMenuTracking: ((Bool) -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onSetPlaybackRate: ((Double) -> Void)?
    var glassTransparency: Double = 45 {
        didSet { applyTransparency() }
    }
    var glassMaterial: GlassMaterial = .clear
    var theme: IslandTheme = .graphite {
        didSet { applyTheme() }
    }
    var expanded = false {
        didSet {
            previous.isHidden = !expanded
            next.isHidden = !expanded
            title.isHidden = !expanded
            status.isHidden = !expanded
            divider.isHidden = !expanded
            brandBackground.isHidden = !expanded
            dragHint.isHidden = !expanded
            caption.alignment = .center
            caption.font = .systemFont(ofSize: expanded ? 17 : 14, weight: .semibold)
            caption.maximumNumberOfLines = expanded ? 2 : 1
            caption.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
            applyTheme()
            layoutLabels()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.isEmphasized = true
        surface.wantsLayer = true
        surface.layer?.masksToBounds = true
        addSubview(surface)

        tint.wantsLayer = true
        tint.layer?.backgroundColor = theme.tint.cgColor
        tint.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        tint.layer?.borderWidth = 1
        tint.layer?.masksToBounds = true
        addSubview(tint)

        addSubview(contentContainer)

        brandBackground.wantsLayer = true
        brandBackground.layer?.cornerRadius = 10
        contentContainer.addSubview(brandBackground)
        brand.font = .systemFont(ofSize: 11, weight: .semibold)
        brand.alignment = .center
        brand.textColor = .secondaryLabelColor
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.alignment = .left
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        previous.font = .systemFont(ofSize: 12)
        previous.textColor = .secondaryLabelColor
        previous.lineBreakMode = .byTruncatingTail
        previous.alignment = .center
        caption.font = .systemFont(ofSize: 14, weight: .semibold)
        caption.textColor = .labelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.maximumNumberOfLines = 1
        next.font = .systemFont(ofSize: 12)
        next.textColor = .secondaryLabelColor
        next.lineBreakMode = .byTruncatingTail
        next.alignment = .center
        playbackButton.isBordered = false
        playbackButton.imagePosition = .imageOnly
        playbackButton.imageScaling = .scaleProportionallyDown
        playbackButton.contentTintColor = .labelColor
        playbackButton.wantsLayer = true
        playbackButton.layer?.cornerRadius = 16
        playbackButton.target = self
        playbackButton.action = #selector(togglePlayback)
        playbackButton.toolTip = "暂停播放"
        playbackButton.setAccessibilityLabel("暂停播放")
        speedButton.isBordered = false
        speedButton.imagePosition = .noImage
        speedButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        speedButton.contentTintColor = .labelColor
        speedButton.wantsLayer = true
        speedButton.target = self
        speedButton.action = #selector(showSpeedMenu)
        speedButton.toolTip = "调整播放速度"
        speedButton.setAccessibilityLabel("调整播放速度")
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        dragHint.font = .systemFont(ofSize: 10, weight: .regular)
        dragHint.textColor = .tertiaryLabelColor
        dragHint.alignment = .right
        for label in [brand, status, title, previous, caption, next, dragHint] { contentContainer.addSubview(label) }
        contentContainer.addSubview(statusDot)
        contentContainer.addSubview(playbackButton)
        contentContainer.addSubview(speedButton)
        contentContainer.addSubview(divider)
        expanded = false
        title.isHidden = true
        previous.isHidden = true
        next.isHidden = true
        status.isHidden = true
        divider.isHidden = true
        brandBackground.isHidden = true
        dragHint.isHidden = true
        caption.alignment = .center
        applyTheme()
        layoutLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Put content inside a single native glass surface. A second visual-effect
    /// view in contentView would cover the glass with a separate frosted material.
    func makeWindowContentView() -> NSView {
        guard #available(macOS 26.0, *) else { return self }
        (nativeGlass as? NSGlassEffectView)?.contentView = nil
        let glass = NSGlassEffectView(frame: bounds)
        glass.style = glassMaterial.nativeStyle
        glass.cornerRadius = min(bounds.height / 2, expanded ? 26 : 23)
        glass.contentView = self
        nativeGlass = glass
        surface.isHidden = true
        tint.isHidden = true
        applyTheme()
        return glass
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        pointerOrigin = screenLocation(for: event)
        didDrag = false
        onPointerBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pointerOrigin else { return }
        let pointer = screenLocation(for: event)
        let delta = NSPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
        guard didDrag || hypot(delta.x, delta.y) >= 4 else { return }
        didDrag = true
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard let origin = pointerOrigin else { return }
        let pointer = screenLocation(for: event)
        // A very short drag can be coalesced to a down/up pair. Preserve the
        // final displacement instead of treating that pair as an expand click.
        if !didDrag {
            let delta = NSPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
            if hypot(delta.x, delta.y) >= 4 {
                didDrag = true
                onDrag?(delta)
            }
        }
        pointerOrigin = nil
        onPointerEnded?(didDrag, pointer)
        didDrag = false
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        // Read the coordinate carried by this event. The global cursor may
        // already be at mouse-up when a queued/fast drag is being dispatched.
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    func cancelPointerInteraction() {
        pointerOrigin = nil
        didDrag = false
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = point
        if !playbackButton.isHidden && playbackButton.frame.contains(local) { return playbackButton }
        if !speedButton.isHidden && speedButton.frame.contains(local) { return speedButton }
        return bounds.contains(local) ? self : nil
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        tint.frame = bounds
        contentContainer.frame = bounds
        surface.layer?.cornerRadius = min(bounds.height / 2, expanded ? 26 : 23)
        tint.layer?.cornerRadius = surface.layer?.cornerRadius ?? 0
        if #available(macOS 26.0, *), let glass = nativeGlass as? NSGlassEffectView {
            glass.cornerRadius = min(bounds.height / 2, expanded ? 26 : 23)
        }
        layoutLabels()
    }

    private func layoutLabels() {
        let width = bounds.width
        let topCenter = expanded ? bounds.height - 29 : bounds.height / 2
        if expanded {
            brandBackground.frame = NSRect(x: 20, y: topCenter - 16, width: 34, height: 32)
            centerSingleLine(brand, x: 20, width: 34, centerY: topCenter)
            playbackButton.frame = NSRect(x: width - 52, y: topCenter - 16, width: 32, height: 32)
            speedButton.frame = NSRect(x: width - 112, y: topCenter - 14, width: 50, height: 28)
            let titleRight = speedButton.isHidden ? width - 20 : speedButton.frame.minX - 12
            centerSingleLine(title, x: 66, width: max(0, titleRight - 66), centerY: topCenter)
            divider.frame = NSRect(x: 24, y: bounds.height - 57, width: width - 48, height: 0.5)

            // Keep the reading area still as phrases change. Measure the caption
            // at its real width so a single line and two lines share one center.
            centerSingleLine(previous, x: 28, width: width - 56, centerY: 126)
            let readingRect = NSRect(x: 28, y: 61, width: width - 56, height: 51)
            let measured = caption.cell?.cellSize(forBounds: NSRect(x: 0, y: 0,
                width: readingRect.width, height: 1000)).height ?? 22
            let captionHeight = min(readingRect.height, max(1, ceil(measured)))
            caption.frame = NSRect(x: readingRect.minX, y: readingRect.midY - captionHeight / 2,
                                   width: readingRect.width, height: captionHeight)
            centerSingleLine(next, x: 28, width: width - 56, centerY: 47)
            statusDot.frame = NSRect(x: 24, y: 17, width: 5, height: 5)
            centerSingleLine(status, x: 36, width: max(0, width - 178), centerY: 19.5)
            centerSingleLine(dragHint, x: width - 124, width: 100, centerY: 19.5)
        } else {
            centerSingleLine(brand, x: 18, width: 34, centerY: topCenter)
            statusDot.frame = NSRect(x: 59, y: topCenter - 3, width: 6, height: 6)
            playbackButton.frame = NSRect(x: width - 42, y: topCenter - 15, width: 30, height: 30)
            speedButton.frame = NSRect(x: width - 99, y: topCenter - 13, width: 49, height: 26)
            // Keep the current phrase centered on the actual island. The left status
            // glyphs and right controls remain balanced utility rails.
            let leftBoundary: CGFloat = 82
            let rightBoundary = speedButton.frame.minX - 16
            let available = max(0, min(width / 2 - leftBoundary, rightBoundary - width / 2) * 2)
            let captionWidth = min(420, available)
            centerSingleLine(caption, x: (width - captionWidth) / 2,
                             width: captionWidth, centerY: topCenter)
        }
        statusDot.layer?.cornerRadius = statusDot.bounds.width / 2
    }

    private func centerSingleLine(_ label: NSTextField, x: CGFloat, width: CGFloat, centerY: CGFloat) {
        // NSTextField draws at the top of its cell. An oversized, centered frame
        // leaves the glyphs above the rail's center; center its natural height.
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: centerY - height / 2, width: width, height: height)
    }

    func update(text: String, titleText: String, state: String, previousText: String,
                nextText: String, connected: Bool, paused: Bool, playbackRate: Double) {
        let content = IslandContent(text: text, title: titleText, state: state,
                                    previous: previousText, next: nextText,
                                    connected: connected, paused: paused, rate: playbackRate)
        guard content != lastContent else { return }
        lastContent = content
        currentRate = playbackRate
        if caption.stringValue != text { needsLayout = true }
        caption.stringValue = text
        title.stringValue = titleText
        previous.stringValue = previousText
        next.stringValue = nextText
        previous.toolTip = previousText.isEmpty ? nil : "上一句 · " + previousText
        next.toolTip = nextText.isEmpty ? nil : "下一句 · " + nextText
        previous.setAccessibilityLabel("上一句")
        next.setAccessibilityLabel("下一句")
        caption.toolTip = text
        title.toolTip = titleText
        status.stringValue = connected ? String((state.components(separatedBy: " · ").first ?? state).prefix(16)) : "等待连接"
        status.textColor = .secondaryLabelColor
        statusDot.layer?.backgroundColor = (connected ? (paused ? NSColor.systemOrange : theme.accent) : NSColor.systemGray).cgColor
        playbackButton.isHidden = !connected
        playbackButton.isEnabled = connected && !controlPending
        let symbol = paused ? "play.fill" : "pause.fill"
        playbackButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: paused ? "播放" : "暂停播放")
        playbackButton.toolTip = paused ? "播放" : "暂停播放"
        playbackButton.setAccessibilityLabel(paused ? "播放" : "暂停播放")
        speedButton.isHidden = !connected
        speedButton.isEnabled = connected && !controlPending
        speedButton.title = rateTitle(playbackRate)
        speedButton.setAccessibilityLabel("播放速度 \(rateTitle(playbackRate))")
        needsLayout = true
    }

    private func rateTitle(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.0001 { return String(format: "%.1f×", rate) }
        if abs(rate * 10 - (rate * 10).rounded()) < 0.0001 { return String(format: "%.1f×", rate) }
        return String(format: "%.2f×", rate)
    }

    private func applyTheme() {
        if nativeGlass == nil {
            tint.layer?.backgroundColor = theme.tint.cgColor
            tint.layer?.borderColor = theme.accent.withAlphaComponent(0.24).cgColor
        }
        speedButton.layer?.backgroundColor = theme.accent.withAlphaComponent(0.14).cgColor
        speedButton.layer?.cornerRadius = expanded ? 14 : 13
        brandBackground.layer?.backgroundColor = theme.accent.withAlphaComponent(0.12).cgColor
        playbackButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(expanded ? 0.06 : 0).cgColor
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        caption.textColor = .labelColor
        statusDot.layer?.backgroundColor = (lastContent?.connected == true
            ? (lastContent?.paused == true ? NSColor.systemOrange : theme.accent) : NSColor.systemGray).cgColor
        applyTransparency()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTransparency() {
        let transparency = min(100, max(10, glassTransparency))
        if #available(macOS 26.0, *), let nativeGlass = nativeGlass as? NSGlassEffectView {
            // Only the explicit material picker changes the glass style.
            // Changing transparency never swaps materials.
            GlassAppearance.applyTransparency(transparency, to: nativeGlass)
            surface.isHidden = true
            tint.isHidden = true
            return
        }
        // Older systems keep a single native blur plus an adjustable theme tint.
        surface.alphaValue = 0.35 + CGFloat(1 - transparency / 100) * 0.65
        tint.layer?.opacity = Float(1 - transparency / 100)
    }

    @objc private func showSpeedMenu() {
        guard speedButton.isEnabled else { return }
        onMenuTracking?(true)
        defer { onMenuTracking?(false) }
        let menu = NSMenu(title: "播放速度")
        for rate in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            let item = NSMenuItem(title: rateTitle(rate), action: #selector(chooseRate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate
            item.state = abs(currentRate - rate) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: speedButton.bounds.height + 4), in: speedButton)
    }

    @objc private func chooseRate(_ item: NSMenuItem) {
        guard let rate = item.representedObject as? Double else { return }
        onSetPlaybackRate?(rate)
    }

    @objc private func togglePlayback() {
        guard playbackButton.isEnabled else { return }
        controlPending = true
        playbackButton.isEnabled = false
        onTogglePlayback?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            guard let self else { return }
            self.controlPending = false
            self.playbackButton.isEnabled = self.lastContent?.connected == true
            self.speedButton.isEnabled = self.lastContent?.connected == true
        }
    }
}

final class IslandController {
    private let panel: IslandPanel
    private let root: IslandRootView
    private let defaults: UserDefaults
    private var configuredWidth: CGFloat = 620
    private var expanded = false
    private var pointerInside = false
    private var pointerPressed = false
    private var menuTracking = false
    private var dragStartFrame: NSRect?
    private var hoverWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var preferredScreenID: String?
    private var positions: [String: IslandPosition] = [:]
    private(set) var expansionMode: IslandExpansionMode

    var onPlacementChanged: (() -> Void)?
    var onTogglePlayback: (() -> Void)? {
        didSet { root.onTogglePlayback = onTogglePlayback }
    }
    var onSetPlaybackRate: ((Double) -> Void)? {
        didSet { root.onSetPlaybackRate = onSetPlaybackRate }
    }

    var screenOptions: [IslandScreenOption] {
        NSScreen.screens.enumerated().map { index, screen in
            IslandScreenOption(id: screenID(screen), title: screen.localizedName + (index == 0 ? " · 主显示器" : ""))
        }
    }

    var selectedScreenID: String? { activeScreen.map(screenID) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expansionMode = IslandExpansionMode(rawValue: defaults.string(forKey: "islandExpansionMode") ?? "") ?? .hover
        preferredScreenID = defaults.string(forKey: "islandScreenID")
        if let data = defaults.data(forKey: "islandPositions"),
           let stored = try? JSONDecoder().decode([String: IslandPosition].self, from: data) {
            positions = stored
        }
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 46),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        root = IslandRootView(frame: NSRect(x: 0, y: 0, width: 620, height: 46))
        panel.glassMaterial = root.glassMaterial
        panel.contentView = root.makeWindowContentView()
        if #unavailable(macOS 26.0) {
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        root.toolTip = "拖动可调整位置，靠近顶部时自动吸附"
        root.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        root.onPointerBegan = { [weak self] in
            guard let self else { return }
            self.cancelHover()
            self.pointerPressed = true
            self.dragStartFrame = self.panel.frame
        }
        root.onDrag = { [weak self] delta in
            guard let self, let origin = self.dragStartFrame else { return }
            self.panel.setFrameOrigin(NSPoint(x: origin.minX + delta.x, y: origin.minY + delta.y))
        }
        root.onPointerEnded = { [weak self] dragged, point in self?.finishPointer(dragged: dragged, pointer: point) }
        root.onMenuTracking = { [weak self] tracking in
            guard let self else { return }
            self.menuTracking = tracking
            self.cancelHover()
            if !tracking { self.hoverChanged(self.panel.frame.contains(NSEvent.mouseLocation)) }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cancelHover()
            self.root.cancelPointerInteraction()
            self.pointerPressed = false
            self.dragStartFrame = nil
            self.place(animated: false)
            self.onPlacementChanged?()
        }
        // Pick once. Moving focus to another app must not move the subtitle panel.
        if preferredScreenID == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            preferredScreenID = screenID(screen)
            defaults.set(preferredScreenID, forKey: "islandScreenID")
        }
    }

    deinit {
        hoverWork?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func show() {
        cancelHover()
        expanded = expansionMode == .pinned
        root.expanded = expanded
        place(animated: false)
        panel.orderFrontRegardless()
        hoverChanged(panel.frame.contains(NSEvent.mouseLocation))
    }

    func hide() {
        cancelHover()
        panel.orderOut(nil)
        pointerInside = false
        pointerPressed = false
        dragStartFrame = nil
        root.cancelPointerInteraction()
        setExpanded(false)
    }

    func setWidth(_ width: Double) {
        let value = min(860, max(360, CGFloat(width)))
        guard configuredWidth != value else { return }
        configuredWidth = value
        place(animated: false)
    }

    func setTheme(_ theme: IslandTheme) {
        guard root.theme != theme else { return }
        root.theme = theme
    }

    func setGlassTransparency(_ transparency: Double) {
        let value = min(100, max(10, transparency))
        guard root.glassTransparency != value else { return }
        root.glassTransparency = value
    }

    func setGlassMaterial(_ material: GlassMaterial) {
        let supported = material.isAvailable ? material : .soft
        panel.glassMaterial = supported
        guard root.glassMaterial != supported else { return }
        root.glassMaterial = supported
        if #available(macOS 26.0, *) {
            // Rebuild the material to discard AppKit's cached active appearance.
            // The content view and the panel (including placement) stay intact.
            let frame = panel.frame
            panel.contentView = root.makeWindowContentView()
            panel.setFrame(frame, display: true)
        }
    }

    func setScreen(_ id: String) {
        guard NSScreen.screens.contains(where: { screenID($0) == id }) else { return }
        preferredScreenID = id
        defaults.set(id, forKey: "islandScreenID")
        cancelHover()
        place(animated: false)
        onPlacementChanged?()
    }

    func resetPosition() {
        guard let screen = activeScreen else { return }
        positions[screenID(screen)] = IslandPosition()
        savePositions()
        cancelHover()
        place(animated: true)
        onPlacementChanged?()
    }

    func setExpansionMode(_ mode: IslandExpansionMode) {
        guard expansionMode != mode else { return }
        expansionMode = mode
        defaults.set(mode.rawValue, forKey: "islandExpansionMode")
        cancelHover()
        setExpanded(mode == .pinned)
        if mode == .hover { hoverChanged(panel.frame.contains(NSEvent.mouseLocation)) }
        onPlacementChanged?()
    }

    func update(text: String, title: String, state: String, previous: String, next: String,
                isConnected: Bool, isPaused: Bool, playbackRate: Double) {
        root.update(text: text, titleText: title, state: state, previousText: previous,
                    nextText: next, connected: isConnected, paused: isPaused,
                    playbackRate: playbackRate)
    }

    private var activeScreen: NSScreen? {
        if let preferredScreenID, let screen = NSScreen.screens.first(where: { screenID($0) == preferredScreenID }) {
            return screen
        }
        return NSScreen.screens.first
    }

    private func screenID(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.localizedName
        }
        let display = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(display)"
    }

    private func safeFrame(_ screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let frame = screen.frame
        let safe = screen.safeAreaInsets
        let left = max(visible.minX, frame.minX + safe.left)
        let right = min(visible.maxX, frame.maxX - safe.right)
        let bottom = max(visible.minY, frame.minY + safe.bottom)
        let top = min(visible.maxY, frame.maxY - safe.top)
        return NSRect(x: left, y: bottom, width: max(1, right - left), height: max(1, top - bottom))
    }

    private func hoverChanged(_ inside: Bool) {
        pointerInside = inside
        cancelHover()
        guard expansionMode == .hover, !pointerPressed, !menuTracking, panel.isVisible else { return }
        guard expanded != inside else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.expansionMode == .hover, !self.pointerPressed, !self.menuTracking,
                  self.panel.isVisible, self.pointerInside == inside else { return }
            // Tracking events can be invalidated by a resize or a screen change.
            let actuallyInside = self.panel.frame.contains(NSEvent.mouseLocation)
            guard actuallyInside == inside else { return }
            self.setExpanded(inside)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.3 : 0.35), execute: work)
    }

    private func cancelHover() {
        hoverWork?.cancel()
        hoverWork = nil
    }

    private func finishPointer(dragged: Bool, pointer: NSPoint) {
        pointerPressed = false
        dragStartFrame = nil
        cancelHover()
        if dragged {
            // Prefer the screen under the pointer; the largest overlap is a fallback.
            let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.screens.max(by: {
                    let lhs = $0.frame.intersection(panel.frame)
                    let rhs = $1.frame.intersection(panel.frame)
                    return lhs.width * lhs.height < rhs.width * rhs.height
                })
            if let screen {
                let id = screenID(screen)
                preferredScreenID = id
                defaults.set(id, forKey: "islandScreenID")
                positions[id] = IslandPlacement.position(afterDragging: panel.frame, in: safeFrame(screen))
                savePositions()
                place(animated: true)
                onPlacementChanged?()
            }
            // Releasing a drag is not a click and must not unfold the capsule.
            pointerInside = panel.frame.contains(pointer)
        } else if expansionMode != .pinned {
            setExpanded(!expanded)
        }
    }

    private func savePositions() {
        if let data = try? JSONEncoder().encode(positions) { defaults.set(data, forKey: "islandPositions") }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        root.expanded = value
        place(animated: true)
    }

    private func place(animated: Bool) {
        guard !pointerPressed, let screen = activeScreen else { return }
        let target = IslandPlacement.frame(in: safeFrame(screen), width: configuredWidth, expanded: expanded,
                                           position: positions[screenID(screen)] ?? IslandPosition())
        guard panel.frame != target else { return }
        if animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }
}
