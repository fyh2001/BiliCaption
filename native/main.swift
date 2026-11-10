import AppKit

enum CaptionDisplayMode: String {
    case menuBar
    case island
}

final class CaptionView: NSView {
    var text = "B 站字幕 · 等待连接" {
        didSet {
            guard text != oldValue else { return }
            changedAt = ProcessInfo.processInfo.systemUptime
            measuredText = nil
            needsDisplay = true
        }
    }
    var scrolling = true { didSet { if scrolling != oldValue { needsDisplay = true } } }
    private var changedAt = ProcessInfo.processInfo.systemUptime
    private var measuredText: NSSize?
    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let icon = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "B 站字幕")
    private var textSize: NSSize {
        if let measuredText { return measuredText }
        let size = (text as NSString).size(withAttributes: [.font: font])
        measuredText = size
        return size
    }

    /// Wait during the reading pauses; animate only while an overflowing line moves.
    func nextScrollDelay(at now: Double) -> Double? {
        let overflow = Double(textSize.width - max(0, bounds.width - 34))
        guard scrolling, !isHidden, overflow > 0, bounds.width > 34 else { return nil }
        let elapsed = now - changedAt - 1.2
        if elapsed < 0 { return 0.8 - elapsed }
        let duration = overflow / 30
        let cycle = duration + 2.4
        let phase = elapsed.truncatingRemainder(dividingBy: cycle)
        if phase < 0.8 { return max(0.001, 0.8 - phase) }
        if phase < 0.8 + duration { return 1.0 / 30 }
        return max(0.001, cycle - phase)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let size = textSize
        let box = NSRect(x: 26, y: 0, width: bounds.width - 34, height: bounds.height)
        if let icon {
            icon.isTemplate = true
            icon.draw(in: NSRect(x: 7, y: (bounds.height - 14) / 2, width: 16, height: 14))
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: box).addClip()
        var offset: CGFloat = 0
        if size.width > box.width && scrolling {
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - changedAt - 1.2)
            let travel = Double(size.width - box.width)
            let cycle = travel / 30 + 2.4
            let phase = elapsed.truncatingRemainder(dividingBy: cycle)
            offset = CGFloat(min(travel, max(0, phase - 0.8) * 30))
        }
        (text as NSString).draw(at: NSPoint(x: box.minX - offset, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = CaptionStore()
    let server = BridgeServer()
    let library = ListeningLibrary()
    let listeningPreferences = ListeningPreferences()
    let transcriber = LocalTranscriber()
    lazy var listeningWindow = ListeningWindowController(store: store, library: library, preferences: listeningPreferences, transcriber: transcriber)
    private var asrCaption = ""
    private var asrCaptionTime: Double = 0
    private var asrPage: String?
    private var asrIdentity: String?
    private var previousASRPlayback: Playback?
    private var pendingPlay: (item: MediaItem, time: Double, rate: Double, expires: Double)?
    private var pendingPlayTimer: Timer?
    private var playbackCommands: Set<String> = []
    var statusItem: NSStatusItem!
    let captionView = CaptionView()
    let detail = DetailController()
    let island = IslandController()
    let popover = GlassSettingsPopover()
    private var refreshTimer: Timer?
    private var refreshDeadline: Double?
    private var scrollTimer: Timer?
    private var scrollDeadline: Double?
    var failure: String?
    var currentURL: String?
    var displayMode: CaptionDisplayMode = .menuBar
    var menuBarWidth: Double = 260
    var islandWidth: Double = 620
    var islandTheme: IslandTheme = .graphite
    var glassTransparency: Double = 45
    var settingsGlassTransparency: Double = 45
    var islandGlassMaterial: GlassMaterial = .clear
    var settingsGlassMaterial: GlassMaterial = .soft
    var lastControlAt: Double = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(); appItem.submenu = appMenu
        let appearanceItem = NSMenuItem(title: "字幕与外观…", action: #selector(openAppearance), keyEquivalent: ",")
        appearanceItem.target = self; appMenu.addItem(appearanceItem); appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 B 站字幕", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp; appMenu.addItem(quitItem); mainMenu.addItem(appItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
        for (title, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        let savedMenuWidth = UserDefaults.standard.double(forKey: "captionWidth")
        menuBarWidth = savedMenuWidth > 0 ? min(440, max(140, savedMenuWidth)) : 260
        let savedIslandWidth = UserDefaults.standard.double(forKey: "islandWidth")
        islandWidth = savedIslandWidth > 0 ? min(860, max(360, savedIslandWidth)) : 620
        islandTheme = IslandTheme(rawValue: UserDefaults.standard.string(forKey: "islandTheme") ?? "") ?? .graphite
        if let savedTransparency = UserDefaults.standard.object(forKey: "glassTransparency") as? NSNumber {
            glassTransparency = min(100, max(10, savedTransparency.doubleValue))
        }
        // The existing key belongs to subtitle glass. Settings must not inherit
        // its value: many users intentionally keep subtitles at maximum clarity.
        if let saved = UserDefaults.standard.object(forKey: "settingsGlassTransparency") as? NSNumber {
            settingsGlassTransparency = min(100, max(10, saved.doubleValue))
        }
        islandGlassMaterial = GlassMaterial.resolve(UserDefaults.standard.string(forKey: "islandGlassMaterial"), default: .clear)
        settingsGlassMaterial = GlassMaterial.resolve(UserDefaults.standard.string(forKey: "settingsGlassMaterial"), default: .soft)
        displayMode = CaptionDisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .menuBar
        statusItem = NSStatusBar.system.statusItem(withLength: menuBarWidth)
        if let button = statusItem.button {
            button.title = ""
            button.target = self; button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addSubview(captionView)
            captionView.autoresizingMask = [.width, .height]
            button.setAccessibilityLabel("B 站字幕")
        }
        _ = detail.view
        detail.mode.selectedSegment = displayMode == .menuBar ? 0 : 1
        detail.configureWidth(for: displayMode, value: displayMode == .menuBar ? menuBarWidth : islandWidth)
        if let themeIndex = IslandTheme.allCases.firstIndex(of: islandTheme) { detail.theme.selectItem(at: themeIndex) }
        detail.configureGlassTransparency(glassTransparency)
        detail.configureSettingsTransparency(settingsGlassTransparency)
        detail.configureIslandMaterial(islandGlassMaterial)
        detail.configureSettingsMaterial(settingsGlassMaterial)
        let scroll = UserDefaults.standard.object(forKey: "scrollCaptions") as? Bool ?? true
        captionView.scrolling = scroll; detail.scrolling.state = scroll ? .on : .off
        detail.onMode = { [weak self] in self?.applyDisplayMode($0, closePopover: true) }
        detail.onTheme = { [weak self] in self?.setTheme($0) }
        detail.onGlassTransparency = { [weak self] in self?.setGlassTransparency($0) }
        detail.onSettingsTransparency = { [weak self] in self?.setSettingsTransparency($0) }
        detail.onIslandMaterial = { [weak self] in self?.setIslandMaterial($0) }
        detail.onSettingsMaterial = { [weak self] in self?.setSettingsMaterial($0) }
        detail.onWidth = { [weak self] in self?.setWidth($0) }
        detail.onScroll = { [weak self] value in
            self?.captionView.scrolling = value
            UserDefaults.standard.set(value, forKey: "scrollCaptions")
            self?.scheduleScroll()
        }
        detail.onExpansion = { [weak self] mode in
            self?.island.setExpansionMode(mode)
            self?.configureIslandControls()
        }
        detail.onScreen = { [weak self] id in
            self?.island.setScreen(id)
            self?.configureIslandControls()
        }
        detail.onResetPosition = { [weak self] in self?.island.resetPosition() }
        island.onPlacementChanged = { [weak self] in self?.configureIslandControls() }
        configureIslandControls()
        detail.onLibrary = { [weak self] in self?.openListeningWindow() }
        listeningWindow.onCommand = { [weak self] action, args in self?.sendCommand(action, args) }
        listeningWindow.onPlayItem = { [weak self] item, resume in self?.playItem(item, resume: resume) }
        listeningWindow.onSettings = { [weak self] in
            self?.openAppearance()
        }
        listeningWindow.onChange = { [weak self] in self?.refresh() }
        listeningWindow.captionProvider = { [weak self] in self?.captionView.text ?? "" }
        transcriber.onChange = { [weak self] in
            guard let self else { return }
            if !self.transcriber.isRunning { self.asrCaption = ""; self.asrPage = nil }
            self.refresh()
        }
        transcriber.onCaption = { [weak self] text in
            guard let self else { return }
            self.asrCaption = text; self.asrCaptionTime = ProcessInfo.processInfo.systemUptime
            self.asrPage = self.store.active(at: self.asrCaptionTime).flatMap { canonicalVideoURL($0.pageKey) }
            self.refresh()
        }
        server.onPreferences = { [weak self] in
            guard let self else { return [:] }
            var payload = self.listeningPreferences.payload(library: self.library)
            payload["controlledSourceId"] = self.store.activeSourceId(at: ProcessInfo.processInfo.systemUptime) ?? ""
            return payload
        }
        server.onControlResult = { [weak self] id, ok, error in
            guard let self else { return }
            self.listeningWindow.controlResult(id, ok: ok, error: error)
            if self.playbackCommands.remove(id) != nil {
                self.listeningWindow.showFeedback(ok ? "已开始播放" : (error ?? "播放失败"), error: !ok)
            }
        }
        detail.onOpen = { [weak self] in
            if let value = self?.currentURL, let url = URL(string: value) { NSWorkspace.shared.open(url) }
        }
        island.onTogglePlayback = { [weak self] in self?.togglePlayback() }
        island.onSetPlaybackRate = { [weak self] in self?.setPlaybackRate($0) }
        island.setTheme(islandTheme)
        island.setGlassTransparency(glassTransparency)
        island.setGlassMaterial(islandGlassMaterial)
        popover.setGlassTransparency(settingsGlassTransparency)
        popover.setGlassMaterial(settingsGlassMaterial)
        popover.contentViewController = detail
        server.onMessage = { [weak self] message in
            guard let self else { return false }
            let result = self.store.accept(message, now: ProcessInfo.processInfo.systemUptime)
            if result, message.kind == "playback", let source = message.sourceId,
               let player = self.store.players[source], player.hasVideo {
                self.library.recordProgress(url: player.pageKey, time: player.time, rate: player.rate,
                                            duration: player.duration, paused: player.paused)
                if let pending = self.pendingPlay, canonicalVideoURL(player.pageKey) == canonicalVideoURL(pending.item.url),
                   ProcessInfo.processInfo.systemUptime < pending.expires {
                    self.pendingPlay = nil; self.pendingPlayTimer?.invalidate()
                    if let id = self.server.enqueue(action: "playItem", sourceId: source,
                                                    arguments: ["url": pending.item.url, "time": pending.time, "rate": pending.rate]) {
                        self.playbackCommands.insert(id)
                    }
                }
            }
            self.refresh()
            return result
        }
        server.onFailure = { [weak self] message in self?.failure = message; self?.refresh() }
        server.needsTrack = { [weak self] in $0.kind == "playback" && self?.store.tracks[$0.pageKey] == nil }
        server.onHealth = { [weak self] in
            let now = ProcessInfo.processInfo.systemUptime
            let player = self?.store.active(at: now)
            let data: [String: Any] = ["ok": true, "app": "BiliCaption", "version": "2.1.13", "connected": player != nil,
                                      "sourceCount": self?.store.players.count ?? 0,
                                      "cueCount": player.flatMap { self?.store.tracks[$0.pageKey]?.count } ?? 0,
                                      "trackStart": player.flatMap { self?.store.tracks[$0.pageKey]?.first?.from } ?? -1,
                                      "trackEnd": player.flatMap { self?.store.tracks[$0.pageKey]?.last?.to } ?? -1]
            return String(data: try! JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        }
        server.start()
        applyDisplayMode(displayMode, closePopover: false)
        refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openListeningWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        library.flush(); transcriber.stop()
    }

    @objc func openListeningWindow() {
        popover.performClose(nil)
        listeningWindow.open()
    }

    @objc func openAppearance() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        refresh()
    }

    private func sendCommand(_ action: String, _ arguments: [String: Any] = [:]) -> String? {
        guard let source = store.activeSourceId(at: ProcessInfo.processInfo.systemUptime) else { return nil }
        return server.enqueue(action: action, sourceId: source, arguments: arguments)
    }

    private func playItem(_ item: MediaItem, resume: Bool) {
        guard let url = canonicalVideoURL(item.url) else { return }
        let saved = resume ? library.progress(for: url) : nil
        let finished = saved.map { $0.duration.map { $0 > 0 && saved!.time >= $0 - 3 } ?? false } ?? false
        let time = finished ? 0 : (saved?.time ?? 0)
        let rate = saved?.rate ?? store.active(at: ProcessInfo.processInfo.systemUptime)?.rate ?? 1
        if let id = sendCommand("playItem", ["url": url, "time": time, "rate": rate]) {
            playbackCommands.insert(id); listeningWindow.showFeedback("正在打开章节并恢复进度…")
        } else if let target = URL(string: url) {
            pendingPlay = (item, time, rate, ProcessInfo.processInfo.systemUptime + 40)
            pendingPlayTimer?.invalidate()
            pendingPlayTimer = Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { [weak self] _ in
                guard self?.pendingPlay != nil else { return }
                self?.pendingPlay = nil
                self?.listeningWindow.showFeedback("已打开视频，但未收到扩展连接。请检查此浏览器是否启用扩展。", error: true)
            }
            NSWorkspace.shared.open(target)
            listeningWindow.showFeedback("已在浏览器打开；连接后将恢复进度。")
        }
    }

    func setWidth(_ value: Double) {
        if displayMode == .menuBar {
            menuBarWidth = min(440, max(140, value))
            statusItem.length = menuBarWidth
            UserDefaults.standard.set(menuBarWidth, forKey: "captionWidth")
        } else {
            islandWidth = min(860, max(360, value))
            island.setWidth(islandWidth)
            UserDefaults.standard.set(islandWidth, forKey: "islandWidth")
        }
        refresh()
    }

    func togglePlayback() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastControlAt > 0.6,
              let sourceId = store.activeSourceId(at: now) else { return }
        lastControlAt = now
        _ = server.enqueuePlaybackToggle(sourceId: sourceId)
    }

    func setPlaybackRate(_ rate: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastControlAt > 0.6,
              let sourceId = store.activeSourceId(at: now) else { return }
        lastControlAt = now
        _ = server.enqueuePlaybackRate(sourceId: sourceId, rate: rate)
    }

    func setTheme(_ theme: IslandTheme) {
        islandTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: "islandTheme")
        if let index = IslandTheme.allCases.firstIndex(of: theme) { detail.theme.selectItem(at: index) }
        island.setTheme(theme)
    }

    func setGlassTransparency(_ value: Double) {
        glassTransparency = min(100, max(10, value))
        detail.configureGlassTransparency(glassTransparency)
        UserDefaults.standard.set(glassTransparency, forKey: "glassTransparency")
        island.setGlassTransparency(glassTransparency)
    }

    func setSettingsTransparency(_ value: Double) {
        settingsGlassTransparency = min(100, max(10, value))
        detail.configureSettingsTransparency(settingsGlassTransparency)
        popover.setGlassTransparency(settingsGlassTransparency)
        UserDefaults.standard.set(settingsGlassTransparency, forKey: "settingsGlassTransparency")
    }

    func setIslandMaterial(_ material: GlassMaterial) {
        guard material.isAvailable else { return }
        islandGlassMaterial = material
        detail.configureIslandMaterial(material)
        island.setGlassMaterial(material)
        UserDefaults.standard.set(material.rawValue, forKey: "islandGlassMaterial")
    }

    func setSettingsMaterial(_ material: GlassMaterial) {
        guard material.isAvailable else { return }
        settingsGlassMaterial = material
        detail.configureSettingsMaterial(material)
        popover.setGlassMaterial(material)
        UserDefaults.standard.set(material.rawValue, forKey: "settingsGlassMaterial")
    }

    func applyDisplayMode(_ mode: CaptionDisplayMode, closePopover: Bool) {
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "displayMode")
        detail.mode.selectedSegment = mode == .menuBar ? 0 : 1
        detail.configureWidth(for: mode, value: mode == .menuBar ? menuBarWidth : islandWidth)
        configureIslandControls()
        if mode == .menuBar {
            island.hide()
            captionView.isHidden = false
            statusItem.button?.image = nil
            statusItem.button?.imagePosition = .noImage
            statusItem.length = menuBarWidth
        } else {
            if closePopover { popover.performClose(nil) }
            captionView.isHidden = true
            let icon = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "B 站字幕")
            icon?.isTemplate = true
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageOnly
            statusItem.length = NSStatusItem.squareLength
            island.setWidth(islandWidth)
            island.show()
        }
        refresh()
    }

    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        let display = store.display(at: now)
        let captionFrame = statusItem.button?.bounds ?? .zero
        if captionView.frame != captionFrame { captionView.frame = captionFrame }
        let currentPage = display.player.flatMap { canonicalVideoURL($0.pageKey) }
        let identity = display.player.map { (store.activeSourceId(at: now) ?? "") + "|" + $0.pageKey }
        if transcriber.isRunning {
            let jumped = display.player.map { player in
                previousASRPlayback.map { abs(player.time - $0.position(at: player.received)) > 4 } ?? false
            } ?? false
            if asrIdentity != identity || jumped {
                asrIdentity = identity; asrCaption = ""; asrPage = nil
                transcriber.resetRecognition()
            }
            previousASRPlayback = display.player
        } else { asrIdentity = nil; previousASRPlayback = nil }
        let useASR = transcriber.isRunning && !asrCaption.isEmpty && asrPage == currentPage && now - asrCaptionTime < 12
        let text = useASR ? asrCaption : (failure == nil ? display.text : "B 站字幕 · 连接失败")
        if captionView.text != text {
            captionView.text = text
            statusItem.button?.setAccessibilityLabel(text)
        }
        let tooltip = failure ?? display.text
        if statusItem.button?.toolTip != tooltip { statusItem.button?.toolTip = tooltip }
        currentURL = display.player?.pageKey
        if displayMode == .island {
            island.update(text: captionView.text,
                          title: display.player?.title ?? "B 站字幕",
                          state: useASR ? "本机语音转写" : (failure ?? display.state),
                          previous: display.previous,
                          next: display.next,
                          isConnected: display.player != nil,
                          isPaused: display.player?.paused ?? true,
                          playbackRate: display.player?.rate ?? 1)
        }
        if popover.isShown {
            detail.updatePreview(state: failure ?? display.state,
                                 title: display.player?.title ?? "打开 B 站视频，字幕会自动同步到这里",
                                 previous: display.previous, caption: text, next: display.next)
        }
        if listeningWindow.window?.isVisible == true { listeningWindow.refresh() }
        scheduleRefresh(at: now)
        scheduleScroll()
    }

    private func configureIslandControls() {
        detail.configureIslandControls(mode: displayMode, expansionMode: island.expansionMode,
                                       screens: island.screenOptions, selectedScreenID: island.selectedScreenID)
    }

    private func scheduleRefresh(at now: Double) {
        var delays = [store.nextRefreshDelay(at: now)].compactMap { $0 }
        if transcriber.isRunning && !asrCaption.isEmpty && now - asrCaptionTime < 12 {
            delays.append(max(0.01, 12 - (now - asrCaptionTime)))
        }
        guard let delay = delays.min() else {
            refreshTimer?.invalidate(); refreshTimer = nil; refreshDeadline = nil
            return
        }
        let deadline = now + delay
        if let existing = refreshDeadline, refreshTimer?.isValid == true, abs(existing - deadline) < 0.002 { return }
        refreshTimer?.invalidate()
        refreshDeadline = deadline
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.refreshTimer = nil; self?.refreshDeadline = nil
            self?.refresh()
        }
        timer.tolerance = min(0.01, delay / 10)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleScroll() {
        let now = ProcessInfo.processInfo.systemUptime
        guard displayMode == .menuBar, let delay = captionView.nextScrollDelay(at: now) else {
            scrollTimer?.invalidate(); scrollTimer = nil; scrollDeadline = nil
            return
        }
        let deadline = now + delay
        if let existing = scrollDeadline, scrollTimer?.isValid == true, existing <= deadline + 0.002 { return }
        scrollTimer?.invalidate()
        scrollDeadline = deadline
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.scrollTimer = nil; self.scrollDeadline = nil
            self.captionView.needsDisplay = true
            self.scheduleScroll()
        }
        timer.tolerance = min(0.005, delay / 10)
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            refresh()
        }
    }

    func showMenu() {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "B 站菜单栏字幕", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        let console = NSMenuItem(title: "打开听书控制台…", action: #selector(openListeningWindow), keyEquivalent: "")
        console.target = self; menu.addItem(console)
        menu.addItem(.separator())
        let displayHeading = NSMenuItem(title: "显示模式", action: nil, keyEquivalent: "")
        let displaySubmenu = NSMenu()
        for (mode, title) in [(CaptionDisplayMode.menuBar, "菜单栏字幕"), (.island, "灵动岛")] {
            let item = NSMenuItem(title: title, action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = displayMode == mode ? .on : .off
            displaySubmenu.addItem(item)
        }
        displayHeading.submenu = displaySubmenu
        menu.addItem(displayHeading)
        menu.addItem(.separator())
        let auto = NSMenuItem(title: "自动选择正在播放的标签页", action: #selector(selectSource(_:)), keyEquivalent: "")
        auto.target = self; auto.state = store.selectedSource == nil ? .on : .off
        menu.addItem(auto)
        let now = ProcessInfo.processInfo.systemUptime
        for (id, player) in store.players.sorted(by: { $0.value.received > $1.value.received }) where now - player.received < CaptionStore.staleAfter && player.hasVideo {
            let item = NSMenuItem(title: String(player.title.prefix(35)) + (player.paused ? " · 已暂停" : " · 播放中"), action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.state = store.selectedSource == id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 B 站字幕", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func selectSource(_ item: NSMenuItem) {
        store.selectedSource = item.representedObject as? String
        refresh()
    }

    @objc func selectDisplayMode(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let mode = CaptionDisplayMode(rawValue: raw) else { return }
        applyDisplayMode(mode, closePopover: false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
