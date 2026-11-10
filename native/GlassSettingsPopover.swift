import AppKit

private final class GlassSettingsPanel: CaptionGlassPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A status-item anchored settings panel. Unlike
/// NSPopover, this owns its one glass background and can adjust its tint.
final class GlassSettingsPopover: NSObject {
    private let panel: GlassSettingsPanel
    private let host = NSViewController()
    private var material: NSView?
    private var legacyTint: NSView?
    private var mountedController: NSViewController?
    private var transparency: Double = 45
    private var glassMaterial: GlassMaterial = .soft
    private weak var anchor: NSView?
    private weak var anchorWindow: NSWindow?
    private var positioningRect = NSRect.zero
    private var followsAnchorBounds = true
    private var preferredEdge: NSRectEdge = .minY
    private var previousFrameNotifications = false
    private var previousBoundsNotifications = false
    private var observers: [NSObjectProtocol] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var menuTrackingDepth = 0
    private var lastMenuClosedAt: TimeInterval = 0

    var contentViewController: NSViewController? {
        didSet {
            guard contentViewController !== oldValue else { return }
            mountContent()
            if isShown { reposition() }
        }
    }

    var isShown: Bool { panel.isVisible }

    override init() {
        panel = GlassSettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 584),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        super.init()
        panel.title = "字幕与外观"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.cancelFromKeyboard() }
    }

    deinit { removeTracking() }

    func setGlassTransparency(_ value: Double) {
        transparency = value.isFinite ? min(100, max(10, value)) : 45
        applyMaterial()
    }

    func setGlassMaterial(_ value: GlassMaterial) {
        let supported = value.isAvailable ? value : .soft
        guard glassMaterial != supported else { return }
        glassMaterial = supported
        panel.glassMaterial = supported
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            // AppKit caches the active appearance in an existing glass view.
            // Recreate only its surface when changing materials; keep the same
            // controls, text selection, frame and first responder.
            let frame = panel.frame
            let responder = panel.firstResponder
            let content = glass.contentView
            let replacement = NSGlassEffectView(frame: glass.frame)
            replacement.style = supported.nativeStyle
            replacement.cornerRadius = glass.cornerRadius
            panel.contentViewController = nil
            glass.contentView = nil
            replacement.contentView = content
            host.view = replacement
            material = replacement
            panel.contentViewController = host
            panel.setFrame(frame, display: true)
            if let responder { panel.makeFirstResponder(responder) }
            applyMaterial()
        }
    }

    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge) {
        guard contentViewController != nil, let window = view.window else { return }
        removeTracking()
        anchor = view
        anchorWindow = window
        positioningRect = rect
        followsAnchorBounds = rect == view.bounds
        preferredEdge = edge
        mountContent()
        reposition()
        installTracking()
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
    }

    func performClose(_ sender: Any?) {
        removeTracking()
        panel.orderOut(nil)
        anchor = nil
        anchorWindow = nil
    }

    private func cancelFromKeyboard() {
        // Escape that dismisses a native popup menu must not also dismiss its
        // containing settings window as the menu finishes tracking.
        guard menuTrackingDepth == 0,
              ProcessInfo.processInfo.systemUptime - lastMenuClosedAt > 0.2 else { return }
        performClose(nil)
    }

    private func mountContent() {
        guard let controller = contentViewController else {
            performClose(nil)
            mountedController?.view.removeFromSuperview()
            mountedController?.removeFromParent()
            mountedController = nil
            return
        }
        guard mountedController !== controller else { return }
        mountedController?.view.removeFromSuperview()
        mountedController?.removeFromParent()
        let content = controller.view
        let preferred = controller.preferredContentSize
        let size = preferred.width > 0 && preferred.height > 0 ? preferred : content.frame.size
        let bounds = NSRect(origin: .zero, size: size)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        legacyTint = nil

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            // Only the explicit material picker changes this style.
            glass.style = glassMaterial.nativeStyle
            glass.cornerRadius = 24
            glass.contentView = content
            host.view = glass
            material = glass
        } else {
            let root = NSView(frame: bounds)
            root.wantsLayer = true
            root.layer?.cornerRadius = 20
            root.layer?.masksToBounds = true
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            let tint = NSView(frame: bounds)
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            root.addSubview(blur)
            root.addSubview(tint)
            root.addSubview(content)
            host.view = root
            material = blur
            legacyTint = tint
        }
        host.addChild(controller)
        panel.contentViewController = host
        panel.setContentSize(size)
        mountedController = controller
        applyMaterial()
    }

    private func applyMaterial() {
        let density = CGFloat((100 - transparency) / 90)
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            GlassAppearance.applyTransparency(transparency, to: glass)
        } else if let blur = material as? NSVisualEffectView {
            // Here the effect and content are siblings; only the backdrop fades.
            blur.alphaValue = 0.20 + density * 0.80
            legacyTint?.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(density * 0.5).cgColor
        }
    }

    private func anchorRectOnScreen() -> NSRect? {
        guard let view = anchor, let window = view.window else { return nil }
        let rect = followsAnchorBounds ? view.bounds : positioningRect
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    private func reposition() {
        guard let rect = anchorRectOnScreen(), let content = contentViewController?.view else { return }
        let screen = anchorWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) })
            ?? NSScreen.main
        guard let screen else { return }
        let safe = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = content.frame.size
        let gap: CGFloat = 8
        let below = rect.minY - gap - size.height
        let above = rect.maxY + gap
        let fitsBelow = below >= safe.minY
        let fitsAbove = above + size.height <= safe.maxY
        // The status item normally requests minY. Flip only when that edge has
        // insufficient room, then constrain the panel to this screen's edges.
        var y = preferredEdge == .maxY && fitsAbove ? above : below
        if y == below && !fitsBelow && fitsAbove { y = above }
        y = min(max(safe.minY, y), max(safe.minY, safe.maxY - size.height))
        let x = min(max(safe.minX, rect.midX - size.width / 2), max(safe.minX, safe.maxX - size.width))
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func installTracking() {
        guard let anchor else { return }
        previousFrameNotifications = anchor.postsFrameChangedNotifications
        previousBoundsNotifications = anchor.postsBoundsChangedNotifications
        anchor.postsFrameChangedNotifications = true
        anchor.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: anchor, queue: .main) { [weak self] _ in self?.reposition() })
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: anchorWindow, queue: .main) { [weak self] _ in self?.reposition() })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.reposition() })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTrackingDepth += 1 })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
            self.lastMenuClosedAt = ProcessInfo.processInfo.systemUptime
        })
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.isShown, self.menuTrackingDepth == 0 else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.cancelFromKeyboard(); return nil }
            } else if event.window !== self.panel {
                self.closeIfOutside(at: NSEvent.mouseLocation)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeIfOutside(at: NSEvent.mouseLocation)
        }
    }

    private func closeIfOutside(at point: NSPoint) {
        guard isShown, menuTrackingDepth == 0, !panel.frame.contains(point) else { return }
        // The status item already toggles this panel from its own mouse-up
        // action. Closing it on mouse-down would turn that click into a reopen.
        if let anchorRect = anchorRectOnScreen(), anchorRect.contains(point) { return }
        performClose(nil)
    }

    private func removeTracking() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if !observers.isEmpty {
            anchor?.postsFrameChangedNotifications = previousFrameNotifications
            anchor?.postsBoundsChangedNotifications = previousBoundsNotifications
        }
        observers.removeAll()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        menuTrackingDepth = 0
    }
}
