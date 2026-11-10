import AppKit

/// Keep native slider interaction and the system thumb, matching only the rail
/// colour to the other controls in this popover.
private final class DetailSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        ModernPalette.inset.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        var fill = bar
        fill.size.width *= max(0, min(1, (doubleValue - minValue) / max(1, maxValue - minValue)))
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.25).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }
}

/// Only a tint and border: the settings window supplies the single glass layer.
private final class DetailCard: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var borderOpacity: CGFloat = 0.8 { didSet { needsDisplay = true } }
    let radius: CGFloat
    let bordered: Bool

    init(frame: NSRect, fill: NSColor, radius: CGFloat = 16, bordered: Bool = true) {
        self.fill = fill; self.radius = radius; self.bordered = bordered
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        if bordered {
            ModernPalette.border.withAlphaComponent(borderOpacity).setStroke()
            path.lineWidth = 1; path.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

private final class DetailTabButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title; isBordered = false
        setButtonType(.pushOnPushOff)
        focusRingType = .exterior
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular),
            .foregroundColor: selected ? ModernPalette.text : ModernPalette.secondary
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2 + 1), withAttributes: attrs)
        if selected {
            ModernPalette.text.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: isFlipped ? bounds.height - 2 : 0, width: bounds.width - 24, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class DetailController: NSViewController {
    let state = NSTextField(labelWithString: "等待连接")
    let titleField = NSTextField(wrappingLabelWithString: "打开 B 站视频开始收听")
    let previous = NSTextField(wrappingLabelWithString: "")
    let caption = NSTextView()
    let next = NSTextField(wrappingLabelWithString: "")
    let widthLabel = NSTextField(labelWithString: "菜单栏宽度")
    let width = NSSlider(value: 260, minValue: 140, maxValue: 440, target: nil, action: nil)
    let mode = NSSegmentedControl(labels: ["菜单栏字幕", "灵动岛"], trackingMode: .selectOne, target: nil, action: nil)
    let theme = NSPopUpButton(frame: .zero, pullsDown: false)
    let islandMaterial = NSSegmentedControl(labels: GlassMaterial.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let settingsMaterial = NSSegmentedControl(labels: GlassMaterial.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let glassTransparency = NSSlider(value: 45, minValue: 10, maxValue: 100, target: nil, action: nil)
    let transparencyValue = NSTextField(labelWithString: "45%")
    let settingsTransparency = NSSlider(value: 45, minValue: 10, maxValue: 100, target: nil, action: nil)
    let settingsTransparencyValue = NSTextField(labelWithString: "45%")
    let scrolling = NSButton(checkboxWithTitle: "文字过长时自动滚动", target: nil, action: nil)
    let expansion = NSSegmentedControl(labels: ["悬停展开", "点击展开", "固定展开"], trackingMode: .selectOne, target: nil, action: nil)
    let screenPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let resetPosition = NSButton(title: "恢复顶部", target: nil, action: nil)
    var onMode: ((CaptionDisplayMode) -> Void)?
    var onTheme: ((IslandTheme) -> Void)?
    var onIslandMaterial: ((GlassMaterial) -> Void)?
    var onSettingsMaterial: ((GlassMaterial) -> Void)?
    var onGlassTransparency: ((Double) -> Void)?
    var onSettingsTransparency: ((Double) -> Void)?
    var onWidth: ((Double) -> Void)?
    var onScroll: ((Bool) -> Void)?
    var onOpen: (() -> Void)?
    var onLibrary: (() -> Void)?
    var onExpansion: ((IslandExpansionMode) -> Void)?
    var onScreen: ((String) -> Void)?
    var onResetPosition: (() -> Void)?

    private let widthValue = NSTextField(labelWithString: "260 pt")
    private let captionScroll = NSScrollView()
    private let captionViewportHeight: CGFloat = 36
    private let positionHint = NSTextField(labelWithString: "拖动灵动岛可移动，靠近顶部自动吸附。")
    private let subtitlePage = NSView()
    private let settingsPage = NSView()
    private let subtitleTab = DetailTabButton(title: "字幕")
    private let settingsTab = DetailTabButton(title: "设置窗口")
    private let widthRow = NSView()
    private var islandViews: [NSView] = []
    private var menuViews: [NSView] = []
    private var currentMode: CaptionDisplayMode = .menuBar
    private var readingCard: DetailCard?
    private var settingsCard: DetailCard?
    private var selectedIslandMaterial: GlassMaterial = GlassMaterial.clear.isAvailable ? .clear : .soft
    private var selectedSettingsMaterial: GlassMaterial = .soft

    override func loadView() {
        // A stable panel size keeps the menu-bar anchor still while switching pages.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 456, height: 600))
        preferredContentSize = view.frame.size
        for slider in [glassTransparency, settingsTransparency, width] {
            let minimum = slider.minValue, maximum = slider.maxValue, value = slider.doubleValue
            slider.cell = DetailSliderCell()
            slider.minValue = minimum; slider.maxValue = maximum; slider.doubleValue = value
        }

        let icon = NSImageView(frame: NSRect(x: 24, y: 565, width: 21, height: 21))
        icon.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: nil)
        icon.contentTintColor = ModernPalette.secondary
        let heading = label("字幕与外观", font: .systemFont(ofSize: 16, weight: .semibold), color: ModernPalette.text)
        center(heading, x: 55, width: 226, y: 575)
        state.font = .systemFont(ofSize: 10.5, weight: .medium)
        state.textColor = ModernPalette.secondary; state.alignment = .right
        state.lineBreakMode = .byTruncatingTail
        center(state, x: 302, width: 130, y: 575)
        for child in [icon, heading, state] { view.addSubview(child) }

        let readingCard = DetailCard(frame: NSRect(x: 20, y: 430, width: 416, height: 116),
                                     fill: .clear, radius: 14, bordered: false)
        let settingsCard = DetailCard(frame: NSRect(x: 20, y: 66, width: 416, height: 312),
                                      fill: .clear, radius: 14, bordered: false)
        self.readingCard = readingCard; self.settingsCard = settingsCard
        view.addSubview(readingCard); view.addSubview(settingsCard)
        titleField.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleField.textColor = ModernPalette.secondary; titleField.maximumNumberOfLines = 1
        titleField.lineBreakMode = .byTruncatingTail
        center(titleField, x: 36, width: 384, y: 529)
        for field in [previous, next] {
            field.font = .systemFont(ofSize: 10.5); field.textColor = ModernPalette.muted
            field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingTail
            field.alignment = .center
        }
        center(previous, x: 36, width: 384, y: 508)
        center(next, x: 36, width: 384, y: 446)
        previous.setAccessibilityLabel("上一句"); next.setAccessibilityLabel("下一句")
        caption.font = .systemFont(ofSize: 14.5, weight: .medium)
        caption.alignment = .center
        caption.isEditable = false; caption.isSelectable = true
        caption.isRichText = false; caption.drawsBackground = false
        caption.textColor = ModernPalette.text
        caption.isVerticallyResizable = true; caption.isHorizontallyResizable = false
        caption.frame = NSRect(x: 0, y: 0, width: 384, height: captionViewportHeight)
        caption.minSize = NSSize(width: 0, height: captionViewportHeight)
        caption.maxSize = NSSize(width: 384, height: CGFloat.greatestFiniteMagnitude)
        caption.textContainerInset = .zero
        caption.textContainer?.lineFragmentPadding = 0
        caption.textContainer?.containerSize = NSSize(width: 384, height: CGFloat.greatestFiniteMagnitude)
        caption.textContainer?.widthTracksTextView = true
        caption.setAccessibilityLabel("当前字幕，可选择复制")
        captionScroll.frame = NSRect(x: 36, y: 462, width: 384, height: captionViewportHeight)
        captionScroll.drawsBackground = false; captionScroll.contentView.drawsBackground = false
        captionScroll.borderType = .noBorder
        captionScroll.hasVerticalScroller = true; captionScroll.hasHorizontalScroller = false
        captionScroll.scrollerStyle = .overlay; captionScroll.autohidesScrollers = true
        captionScroll.documentView = caption
        for child in [titleField, previous, captionScroll, next] { view.addSubview(child) }

        let tabLine = NSBox(frame: NSRect(x: 20, y: 390, width: 416, height: 1))
        tabLine.boxType = .separator; view.addSubview(tabLine)
        subtitleTab.frame = NSRect(x: 20, y: 390, width: 92, height: 34)
        settingsTab.frame = NSRect(x: 122, y: 390, width: 112, height: 34)
        for tab in [subtitleTab, settingsTab] {
            tab.target = self; tab.action = #selector(tabChanged(_:)); view.addSubview(tab)
        }
        subtitleTab.state = .on
        for page in [subtitlePage, settingsPage] {
            page.frame = NSRect(x: 20, y: 66, width: 416, height: 312)
            view.addSubview(page)
        }
        settingsPage.isHidden = true

        mode.setLabel("菜单栏", forSegment: 0)
        configureSegments(mode, label: "字幕显示位置", action: #selector(modeChanged))
        mode.selectedSegment = currentMode == .island ? 1 : 0
        addRow("显示位置", control: mode, centerY: 288, to: subtitlePage)

        theme.font = .systemFont(ofSize: 12)
        for item in IslandTheme.allCases {
            theme.addItem(withTitle: item.title)
            theme.lastItem?.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                item.accent.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
            }
        }
        theme.setAccessibilityLabel("灵动岛主题色")
        theme.target = self; theme.action = #selector(themeChanged)
        configureMaterialSelector(islandMaterial, label: "字幕材质", action: #selector(islandMaterialChanged))
        configureMaterialSelector(settingsMaterial, label: "设置材质", action: #selector(settingsMaterialChanged))
        configureSlider(glassTransparency, label: "字幕通透度", action: #selector(transparencyChanged))
        glassTransparency.toolTip = "只调整字幕灵动岛的背景；数值越大越通透"
        configureSlider(settingsTransparency, label: "设置通透度", action: #selector(settingsTransparencyChanged))
        settingsTransparency.toolTip = "只调整当前设置窗口的背景；数值越大越通透"
        islandViews.append(sectionHeading("外观", y: 254, in: subtitlePage))
        islandViews.append(addRow("主题色", control: theme, centerY: 226, to: subtitlePage))
        islandViews.append(addRow("玻璃材质", control: islandMaterial, centerY: 194, to: subtitlePage))
        islandViews.append(addSliderRow("通透度", slider: glassTransparency, value: transparencyValue,
                                       centerY: 162, to: subtitlePage))
        islandViews.append(sectionHeading("位置与交互", y: 128, in: subtitlePage))

        widthLabel.font = .systemFont(ofSize: 11.5); widthLabel.textColor = ModernPalette.secondary
        center(widthLabel, x: 16, width: 98, y: 14)
        widthRow.addSubview(widthLabel)
        configureSlider(width, label: "字幕显示宽度", action: #selector(widthChanged))
        // Apply after dragging so changing the status-item width never moves the slider.
        width.isContinuous = false; width.toolTip = "松开滑块后应用宽度"
        width.frame = NSRect(x: 122, y: 5, width: 218, height: 18)
        widthRow.addSubview(width); configureValueLabel(widthValue, in: widthRow)
        subtitlePage.addSubview(widthRow)

        configureSegments(expansion, label: "灵动岛展开方式", action: #selector(expansionChanged))
        expansion.selectedSegment = 0
        expansion.toolTip = "悬停约 0.3 秒展开，也可选择点击展开或固定展开"
        islandViews.append(addRow("展开方式", control: expansion, centerY: 68, to: subtitlePage))
        screenPicker.font = .systemFont(ofSize: 11.5)
        screenPicker.setAccessibilityLabel("灵动岛显示器")
        screenPicker.target = self; screenPicker.action = #selector(screenChanged)
        let screenRow = addRow("显示器", control: screenPicker, centerY: 36, to: subtitlePage)
        screenPicker.frame.size.width = 184
        resetPosition.bezelStyle = .rounded; resetPosition.font = .systemFont(ofSize: 11)
        resetPosition.frame = NSRect(x: 314, y: 1, width: 86, height: 26)
        resetPosition.target = self; resetPosition.action = #selector(resetPositionClicked)
        resetPosition.toolTip = "恢复到所选显示器顶部中央"
        screenRow.addSubview(resetPosition); islandViews.append(screenRow)
        positionHint.font = .systemFont(ofSize: 10); positionHint.textColor = ModernPalette.muted
        center(positionHint, x: 16, width: 384, y: 11)
        subtitlePage.addSubview(positionHint); islandViews.append(positionHint)

        menuViews.append(sectionHeading("菜单栏", y: 254, in: subtitlePage))
        scrolling.font = .systemFont(ofSize: 11.5)
        scrolling.title = "长句自动滚动"
        scrolling.toolTip = "文字超过菜单栏宽度时自动滚动"
        scrolling.setAccessibilityLabel("菜单栏长句自动滚动")
        scrolling.target = self; scrolling.action = #selector(scrollChanged)
        let scrollRow = addRow("阅读方式", control: scrolling, centerY: 186, to: subtitlePage)
        scrolling.frame = NSRect(x: 122, y: 3, width: 278, height: 22)
        menuViews.append(scrollRow)
        let menuHint = NSTextField(wrappingLabelWithString: "菜单栏空间不足时，可以切换到灵动岛，\n在独立浮窗中阅读字幕。")
        menuHint.font = .systemFont(ofSize: 11.5); menuHint.textColor = ModernPalette.secondary
        menuHint.frame = NSRect(x: 16, y: 119, width: 384, height: 38)
        subtitlePage.addSubview(menuHint); menuViews.append(menuHint)

        let settingsHeading = label("窗口外观", font: .systemFont(ofSize: 13, weight: .semibold), color: ModernPalette.text)
        center(settingsHeading, x: 16, width: 384, y: 284); settingsPage.addSubview(settingsHeading)
        let settingsHint = label("仅影响当前设置窗口，字幕外观保持独立。", font: .systemFont(ofSize: 11.5), color: ModernPalette.secondary)
        center(settingsHint, x: 16, width: 384, y: 259); settingsPage.addSubview(settingsHint)
        addRow("玻璃材质", control: settingsMaterial, centerY: 218, to: settingsPage)
        addSliderRow("通透度", slider: settingsTransparency, value: settingsTransparencyValue,
                     centerY: 178, to: settingsPage)
        let transparencyHint = label("数值越大，背景越通透；文字和按钮保持清晰。", font: .systemFont(ofSize: 10.5), color: ModernPalette.muted)
        center(transparencyHint, x: 16, width: 384, y: 142); settingsPage.addSubview(transparencyHint)

        let footerLine = NSBox(frame: NSRect(x: 20, y: 57, width: 416, height: 1))
        footerLine.boxType = .separator; view.addSubview(footerLine)
        let libraryButton = footerButton("听书控制台", symbol: "slider.horizontal.3", action: #selector(openLibrary))
        libraryButton.frame = NSRect(x: 20, y: 17, width: 146, height: 28)
        let openButton = footerButton("返回视频", symbol: "arrow.up.right.square", action: #selector(openVideo))
        openButton.frame = NSRect(x: 176, y: 17, width: 124, height: 28)
        let quitButton = NSButton(title: "退出", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitButton.isBordered = false; quitButton.font = .systemFont(ofSize: 11)
        quitButton.contentTintColor = ModernPalette.secondary
        quitButton.frame = NSRect(x: 390, y: 17, width: 46, height: 28)
        for child in [libraryButton, openButton, quitButton] { view.addSubview(child) }

        configureGlassTransparency(glassTransparency.doubleValue)
        configureSettingsTransparency(settingsTransparency.doubleValue)
        configureIslandMaterial(selectedIslandMaterial)
        configureSettingsMaterial(selectedSettingsMaterial)
        updateModeLayout()
        updatePreview(state: "等待连接", title: "字幕预览", previous: "", caption: "", next: "")
    }

    private func label(_ title: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = font; field.textColor = color
        return field
    }
    private func center(_ field: NSTextField, x: CGFloat, width: CGFloat, y: CGFloat) {
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: x, y: y - height / 2, width: width, height: height)
    }
    @discardableResult
    private func addRow(_ title: String, control: NSControl, centerY: CGFloat, to parent: NSView) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: centerY - 14, width: 416, height: 28))
        let field = label(title, font: .systemFont(ofSize: 11.5), color: ModernPalette.secondary)
        center(field, x: 16, width: 98, y: 14); row.addSubview(field)
        control.frame = NSRect(x: 122, y: 1, width: 278, height: 26)
        row.addSubview(control); parent.addSubview(row)
        return row
    }
    @discardableResult
    private func addSliderRow(_ title: String, slider: NSSlider, value: NSTextField,
                              centerY: CGFloat, to parent: NSView) -> NSView {
        let row = addRow(title, control: slider, centerY: centerY, to: parent)
        slider.frame = NSRect(x: 122, y: 5, width: 218, height: 18)
        configureValueLabel(value, in: row)
        return row
    }
    private func configureValueLabel(_ field: NSTextField, in row: NSView) {
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.textColor = ModernPalette.secondary; field.alignment = .right
        center(field, x: 346, width: 54, y: 14); row.addSubview(field)
    }
    private func sectionHeading(_ title: String, y: CGFloat, in parent: NSView) -> NSView {
        let field = label(title, font: .systemFont(ofSize: 10.5, weight: .semibold), color: ModernPalette.muted)
        center(field, x: 16, width: 384, y: y); parent.addSubview(field)
        return field
    }
    private func configureSegments(_ control: NSSegmentedControl, label: String, action: Selector) {
        control.font = .systemFont(ofSize: 11.5); control.segmentStyle = .rounded
        control.setAccessibilityLabel(label); control.target = self; control.action = action
    }
    private func configureMaterialSelector(_ control: NSSegmentedControl, label: String, action: Selector) {
        configureSegments(control, label: label, action: action)
        for (index, material) in GlassMaterial.allCases.enumerated() {
            control.setEnabled(material.isAvailable, forSegment: index)
            control.setToolTip(material == .clear
                ? "系统清透玻璃需要 macOS 26 或更新版本；切换材质不会更改通透度"
                : "柔和的磨砂玻璃；切换材质不会更改通透度", forSegment: index)
        }
    }
    private func configureSlider(_ slider: NSSlider, label: String, action: Selector) {
        slider.isContinuous = true; slider.target = self; slider.action = action
        slider.setAccessibilityLabel(label)
    }
    private func footerButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11.5)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel(title)
        return button
    }
    @objc private func tabChanged(_ sender: NSButton) {
        let showSettings = sender === settingsTab
        subtitleTab.state = showSettings ? .off : .on
        settingsTab.state = showSettings ? .on : .off
        subtitlePage.isHidden = showSettings
        settingsPage.isHidden = !showSettings
    }
    private func updateModeLayout() {
        let island = currentMode == .island
        for child in islandViews { child.isHidden = !island }
        for child in menuViews { child.isHidden = island }
        widthRow.frame = NSRect(x: 0, y: (island ? 100 : 222) - 14, width: 416, height: 28)
    }

    /// Refresh only changed text so heartbeats preserve selection and scrolling.
    func updatePreview(state: String, title: String, previous: String, caption: String, next: String) {
        let summary = state.hasPrefix("打开 B 站") ? "等待连接"
            : state.hasPrefix("已连接，等待") ? "等待字幕"
            : state.components(separatedBy: " · ").prefix(2).joined(separator: " · ")
        if self.state.stringValue != summary { self.state.stringValue = summary }
        self.state.toolTip = state
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let disconnected = state.hasPrefix("打开 B 站") || state == "等待连接"
        let empty = disconnected || trimmed.isEmpty || ["♫", "♪", "♬"].contains(trimmed)
        let preview = empty ? (disconnected ? "打开 B 站视频，字幕会自动同步" : "当前暂无字幕") : caption
        let previewTitle = disconnected ? "字幕预览" : title
        for (field, text) in [(titleField, previewTitle), (self.previous, previous), (self.next, next)] {
            if field.stringValue != text { field.stringValue = text }
            field.toolTip = text.isEmpty ? nil : text
        }
        self.previous.isHidden = previous.isEmpty
        self.next.isHidden = next.isEmpty
        if self.caption.string != preview {
            self.caption.string = preview
            self.caption.font = .systemFont(ofSize: empty ? 13 : 14.5, weight: empty ? .regular : .medium)
            self.caption.textColor = empty ? ModernPalette.secondary : ModernPalette.text
            self.caption.alignment = .center
            layoutCaption()
            self.caption.scrollToBeginningOfDocument(nil)
        }
    }

    private func layoutCaption() {
        guard let container = caption.textContainer, let manager = caption.layoutManager else { return }
        let viewport = captionScroll.contentSize
        guard viewport.width > 0 else { return }
        caption.textContainerInset = .zero
        caption.setFrameSize(NSSize(width: viewport.width, height: max(captionViewportHeight, caption.frame.height)))
        container.containerSize = NSSize(width: viewport.width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let contentHeight = ceil(manager.usedRect(for: container).height)
        let padding = max(0, (viewport.height - contentHeight) / 2)
        caption.textContainerInset = NSSize(width: 0, height: padding)
        caption.setFrameSize(NSSize(width: viewport.width, height: max(viewport.height, contentHeight + padding * 2)))
    }

    @objc func modeChanged() {
        currentMode = mode.selectedSegment == 1 ? .island : .menuBar
        updateModeLayout()
        onMode?(currentMode)
    }
    @objc func themeChanged() {
        let cases = IslandTheme.allCases
        guard cases.indices.contains(theme.indexOfSelectedItem) else { return }
        onTheme?(cases[theme.indexOfSelectedItem])
    }
    @objc func islandMaterialChanged() {
        let materials = GlassMaterial.allCases
        guard materials.indices.contains(islandMaterial.selectedSegment) else { return }
        let material = materials[islandMaterial.selectedSegment]
        guard material.isAvailable else { return }
        configureIslandMaterial(material)
        onIslandMaterial?(material)
    }
    @objc func settingsMaterialChanged() {
        let materials = GlassMaterial.allCases
        guard materials.indices.contains(settingsMaterial.selectedSegment) else { return }
        let material = materials[settingsMaterial.selectedSegment]
        guard material.isAvailable else { return }
        configureSettingsMaterial(material)
        onSettingsMaterial?(material)
    }
    @objc func transparencyChanged() {
        let value = glassTransparency.doubleValue.rounded()
        transparencyValue.stringValue = "\(Int(value))%"
        onGlassTransparency?(value)
    }
    @objc func settingsTransparencyChanged() {
        let value = settingsTransparency.doubleValue.rounded()
        settingsTransparencyValue.stringValue = "\(Int(value))%"
        onSettingsTransparency?(value)
    }
    @objc func widthChanged() {
        widthValue.stringValue = "\(Int(width.doubleValue.rounded())) pt"
        onWidth?(width.doubleValue)
    }
    @objc func scrollChanged() { onScroll?(scrolling.state == .on) }
    @objc func openVideo() { onOpen?() }
    @objc func openLibrary() { onLibrary?() }
    @objc func expansionChanged() {
        let modes = IslandExpansionMode.allCases
        guard modes.indices.contains(expansion.selectedSegment) else { return }
        onExpansion?(modes[expansion.selectedSegment])
    }
    @objc func screenChanged() {
        guard let id = screenPicker.selectedItem?.representedObject as? String else { return }
        onScreen?(id)
    }
    @objc func resetPositionClicked() { onResetPosition?() }

    func configureIslandControls(mode: CaptionDisplayMode, expansionMode: IslandExpansionMode,
                                 screens: [IslandScreenOption], selectedScreenID: String?) {
        expansion.selectedSegment = IslandExpansionMode.allCases.firstIndex(of: expansionMode) ?? 0
        let sameScreens = screenPicker.itemArray.map { $0.representedObject as? String } == screens.map { Optional($0.id) }
            && screenPicker.itemTitles == screens.map(\.title)
        if !sameScreens {
            screenPicker.removeAllItems()
            for screen in screens {
                screenPicker.addItem(withTitle: screen.title)
                screenPicker.lastItem?.representedObject = screen.id
            }
        }
        if let index = screens.firstIndex(where: { $0.id == selectedScreenID }) { screenPicker.selectItem(at: index) }
        screenPicker.toolTip = screenPicker.titleOfSelectedItem
        let enabled = mode == .island
        for control in [theme, islandMaterial, glassTransparency, expansion, screenPicker, resetPosition] as [NSControl] {
            control.isEnabled = enabled
        }
        scrolling.isEnabled = !enabled
        currentMode = mode
        updateModeLayout()
    }

    func configureWidth(for mode: CaptionDisplayMode, value: Double) {
        currentMode = mode
        updateModeLayout()
        widthLabel.stringValue = mode == .menuBar ? "菜单栏宽度" : "灵动岛宽度"
        width.minValue = mode == .menuBar ? 140 : 360
        width.maxValue = mode == .menuBar ? 440 : 860
        width.doubleValue = value
        widthValue.stringValue = "\(Int(value.rounded())) pt"
    }

    func configureGlassTransparency(_ value: Double) {
        let clamped = min(100, max(10, value))
        glassTransparency.doubleValue = clamped
        transparencyValue.stringValue = "\(Int(clamped.rounded()))%"
    }

    func configureIslandMaterial(_ material: GlassMaterial) {
        selectedIslandMaterial = material.isAvailable ? material : .soft
        islandMaterial.selectedSegment = GlassMaterial.allCases.firstIndex(of: selectedIslandMaterial) ?? 0
    }

    func configureSettingsMaterial(_ material: GlassMaterial) {
        selectedSettingsMaterial = material.isAvailable ? material : .soft
        settingsMaterial.selectedSegment = GlassMaterial.allCases.firstIndex(of: selectedSettingsMaterial) ?? 0
        updateCardAppearance()
    }

    func configureSettingsTransparency(_ value: Double) {
        let clamped = min(100, max(10, value))
        settingsTransparency.doubleValue = clamped
        settingsTransparencyValue.stringValue = "\(Int(clamped.rounded()))%"
        updateCardAppearance()
    }

    private func updateCardAppearance() {
        let density = CGFloat((100 - settingsTransparency.doubleValue) / 90)
        let clear = selectedSettingsMaterial == .clear
        readingCard?.fill = clear ? .clear : ModernPalette.surface.withAlphaComponent(density * 0.72)
        settingsCard?.fill = clear ? .clear : ModernPalette.surface.withAlphaComponent(density * 0.62)
        readingCard?.borderOpacity = 0.32 + density * 0.35
        settingsCard?.borderOpacity = 0.32 + density * 0.35
    }
}
