import AppKit

final class ListeningPreferences {
    private let defaults = UserDefaults.standard
    var autoSubtitle: Bool { get { defaults.object(forKey: "autoSubtitle") as? Bool ?? true } set { defaults.set(newValue, forKey: "autoSubtitle") } }
    var subtitlePreference: String { get { defaults.string(forKey: "subtitlePreference") ?? "ai" } set { defaults.set(newValue, forKey: "subtitlePreference") } }
    var playbackMode: String { get { defaults.string(forKey: "playbackMode") ?? "sequence" } set { defaults.set(newValue, forKey: "playbackMode") } }
    var useLocalQueue: Bool { get { defaults.bool(forKey: "useLocalQueue") } set { defaults.set(newValue, forKey: "useLocalQueue") } }
    func payload(library: ListeningLibrary) -> [String: Any] {
        let queue = useLocalQueue ? (library.selectedList?.items ?? []) : []
        let json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(queue))) ?? []
        return ["autoSubtitle": autoSubtitle, "subtitlePreference": subtitlePreference,
                "playbackMode": playbackMode, "queue": json]
    }
}

private final class ListeningButton: ConsoleButton {
    var handler: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; handler = action; target = self; self.action = #selector(run)
        bezelStyle = .rounded; font = .systemFont(ofSize: 12)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { handler?() }
}

private final class ConsoleSeekSliderCell: NSSliderCell {
    var modern = false
    override func drawBar(inside rect:NSRect,flipped:Bool) {
        guard modern else { super.drawBar(inside:rect,flipped:flipped); return }
        let bar=NSRect(x:rect.minX,y:rect.midY-2,width:rect.width,height:4)
        NSColor.labelColor.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect:bar,xRadius:2,yRadius:2).fill()
        let fraction=max(0,min(1,(doubleValue-minValue)/max(1,maxValue-minValue)))
        var fill=bar; fill.size.width *= fraction
        ConsolePalette.accent.withAlphaComponent(isEnabled ? 1 : 0.2).setFill(); NSBezierPath(roundedRect:fill,xRadius:2,yRadius:2).fill()
    }
}

private final class ModernMediaRow: NSTableRowView {
    var current = false
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool { get { true } set {} }
    override func drawBackground(in dirtyRect: NSRect) {
        if !isSelected && !current {
            NSColor.separatorColor.withAlphaComponent(0.18).setFill()
            NSRect(x: 46, y: bounds.maxY - 0.5, width: max(0, bounds.width - 54), height: 0.5).fill()
        }
        if current && !isSelected {
            let fill = ConsolePalette.selectionFill
            fill.withAlphaComponent(fill.alphaComponent * 0.5).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:4,dy:2),xRadius:9,yRadius:9).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        ConsolePalette.selectionFill.setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:4,dy:2),xRadius:9,yRadius:9).fill()
    }
}

private final class MediaTable: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private let scroll = NSScrollView()
    private var classicHeader: NSTableHeaderView?
    private var classicColumnWidths: [CGFloat] = []
    private var classicColumnSizing: NSTableView.ColumnAutoresizingStyle = .uniformColumnAutoresizingStyle
    private var classicTableStyle: NSTableView.Style = .automatic
    private let modernHeaders = ["章节", "时长", "听到"].map { NSTextField(labelWithString: $0) }
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString:"还没有章节")
    private let emptyDetail = NSTextField(labelWithString:"添加想听的视频，组成你的下一份听单。")
    var emptyMessage = ("还没有章节", "添加想听的视频，组成你的下一份听单。") {
        didSet { emptyTitle.stringValue=emptyMessage.0; emptyDetail.stringValue=emptyMessage.1 }
    }
    private func updateEmptyState() {
        for view in [emptyIcon,emptyTitle,emptyDetail] as [NSView] { view.isHidden = !modern || !items.isEmpty }
    }
    override func layout() {
        super.layout()
        layoutTable()
        emptyIcon.frame=NSRect(x:bounds.midX-18,y:bounds.midY+22,width:36,height:36)
        emptyTitle.frame=NSRect(x:20,y:bounds.midY-10,width:bounds.width-40,height:21)
        emptyDetail.frame=NSRect(x:20,y:bounds.midY-37,width:bounds.width-40,height:18)
    }
    private func layoutTable() {
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - (modern ? 28 : 0)))
        for header in modernHeaders { header.isHidden = !modern }
        guard modern, table.tableColumns.count == 3 else { return }
        let available = max(240, scroll.contentSize.width)
        let titleWidth = available - 76 - 88
        for (column, width) in zip(table.tableColumns, [titleWidth, 76, 88]) { column.width = width }
        table.setFrameSize(NSSize(width: available, height: table.frame.height))
        let headerY = bounds.height - 23
        for (index, header) in modernHeaders.enumerated() {
            let column = table.rect(ofColumn: index)
            let origin = convert(NSPoint(x: column.minX, y: 0), from: table)
            let textInset: CGFloat = index == 0 ? 46 : 7
            header.frame = NSRect(x: origin.x + textInset, y: headerY,
                                  width: max(0, column.width - textInset - 5), height: 18)
        }
    }
    var modern = false {
        didSet {
            guard modern != oldValue else { return }
            if modern {
                classicColumnWidths = table.tableColumns.map(\.width)
                classicColumnSizing = table.columnAutoresizingStyle
                classicTableStyle = table.style
                // Automatic/inset tables add a horizontal content inset, which
                // conflicts with our explicit page grid and custom headers.
                table.style = .plain
                table.columnAutoresizingStyle = .noColumnAutoresizing
            } else {
                table.style = classicTableStyle
                table.columnAutoresizingStyle = classicColumnSizing
                for (column, width) in zip(table.tableColumns, classicColumnWidths) { column.width = width }
            }
            table.rowHeight = modern ? 40 : 31
            table.intercellSpacing = NSSize(width: modern ? 0 : 3, height: 2)
            table.usesAlternatingRowBackgroundColors = !modern
            table.backgroundColor = modern ? .clear : .controlBackgroundColor
            scroll.borderType = modern ? .noBorder : .bezelBorder
            scroll.drawsBackground = !modern
            scroll.contentView.drawsBackground = !modern
            table.headerView = modern ? nil : classicHeader
            layoutTable()
            let selection = table.selectedRowIndexes
            table.reloadData(); table.selectRowIndexes(selection,byExtendingSelection:false)
            if let row=selection.first ?? items.firstIndex(where:{ canonicalVideoURL($0.url)==currentURL }) { table.scrollRowToVisible(row) }
            updateEmptyState()
        }
    }

    var items: [MediaItem] = []
    var currentURL: String?
    private var lastProgressRefresh: Double = 0
    var progress: ((String) -> ListeningProgress?)?
    var onPlay: ((MediaItem) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTableColumn(identifier: .init("title")); title.title = "章节 / 视频"; title.width = frame.width - 240
        let time = NSTableColumn(identifier: .init("time")); time.title = "时长"; time.width = 76
        let resume = NSTableColumn(identifier: .init("resume")); resume.title = "听到"; resume.width = 92
        table.addTableColumn(title); table.addTableColumn(time); table.addTableColumn(resume)
        table.rowHeight = 31; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(play)
        table.setAccessibilityLabel("章节列表，双击续听")
        classicHeader = table.headerView
        scroll.frame = bounds; scroll.autoresizingMask = [.width,.height]
        scroll.hasVerticalScroller = true; scroll.documentView = table; scroll.borderType = .bezelBorder
        addSubview(scroll)
        for header in modernHeaders {
            header.font = .systemFont(ofSize: 10.5, weight: .medium)
            header.textColor = ModernPalette.muted
            header.isHidden = true
            addSubview(header)
        }
        emptyIcon.image=NSImage(systemSymbolName:"headphones",accessibilityDescription:nil); emptyIcon.contentTintColor=ModernPalette.muted
        emptyTitle.font = .systemFont(ofSize:13,weight:.medium); emptyTitle.textColor=ModernPalette.secondary; emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize:11); emptyDetail.textColor=ModernPalette.muted; emptyDetail.alignment = .center
        addSubview(emptyIcon); addSubview(emptyTitle); addSubview(emptyDetail); updateEmptyState()
    }
    required init?(coder: NSCoder) { fatalError() }
    var selected: MediaItem? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }
    func update(_ value: [MediaItem], current: String?) {
        defer { updateEmptyState() }
        guard items != value || currentURL != current else {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgressRefresh >= 5 {
                lastProgressRefresh = now
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<items.count), columnIndexes: IndexSet(integer: 2))
            }
            return
        }
        let previous = selected?.id
        items = value; currentURL = current; table.reloadData()
        if let previous, let row = items.firstIndex(where: { $0.id == previous }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let field = NSTextField(labelWithString: ""); field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: modern ? 12.5 : 12)
        switch tableColumn?.identifier.rawValue {
        case "time":
            field.stringValue = item.duration.map(Self.time) ?? "—"; field.textColor = .secondaryLabelColor
            if modern { field.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular) }
        case "resume":
            field.stringValue = progress?(item.url).map { Self.time($0.time) } ?? "未播放"; field.textColor = .secondaryLabelColor
            if modern { field.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular) }
        default:
            let active = canonicalVideoURL(item.url) == currentURL
            field.stringValue = (modern ? "" : (active ? "▶  " : "")) + item.title
            field.textColor = active ? (modern ? ConsolePalette.accent : .controlAccentColor) : .labelColor
            field.toolTip = item.title
        }
        let box = NSTableCellView(); box.addSubview(field)
        var inset: CGFloat = 7
        if modern && tableColumn?.identifier.rawValue == "title" {
            let index = NSTextField(labelWithString:canonicalVideoURL(item.url) == currentURL ? "♫" : String(format:"%02d",row+1))
            index.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium)
            index.textColor = canonicalVideoURL(item.url) == currentURL ? ConsolePalette.accent : ModernPalette.muted
            index.alignment = .center; box.addSubview(index); index.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([index.leadingAnchor.constraint(equalTo:box.leadingAnchor,constant:8),index.widthAnchor.constraint(equalToConstant:28),index.centerYAnchor.constraint(equalTo:box.centerYAnchor)])
            inset=46
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),field.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        return box
    }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int) -> NSTableRowView? {
        guard modern else { return nil }
        let view=ModernMediaRow(); view.current=canonicalVideoURL(items[row].url)==currentURL; return view
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if modern { table.backgroundColor = .clear; table.reloadData() }
    }
    @objc private func play() { if let selected { onPlay?(selected) } }
    static func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        let seconds = Int(value)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

final class ListeningWindowController: NSWindowController, NSWindowDelegate {
    let store: CaptionStore
    let library: ListeningLibrary
    let preferences: ListeningPreferences
    let transcriber: LocalTranscriber
    var onCommand: ((String, [String: Any]) -> String?)?
    var onPlayItem: ((MediaItem, Bool) -> Void)?
    var onSettings: (() -> Void)?
    var onChange: (() -> Void)?
    var captionProvider: (() -> String)?
    private let titleLabel = NSTextField(labelWithString: "等待 B 站连接")
    private let subtitleLabel = NSTextField(labelWithString: "打开 B 站视频，扩展会自动连接")
    private let feedback = NSTextField(labelWithString: "字幕和听单保存在本机。双击章节可从上次进度续听。")
    private let timeLabel = NSTextField(labelWithString: "0:00 / —")
    private let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var playButton: ListeningButton!
    private var previousButton: ListeningButton!
    private var nextButton: ListeningButton!
    private var classicRoot: NSView!
    private var modernShell: ModernConsoleShell!
    private var classicFrames: [ObjectIdentifier:NSRect] = [:]
    private var pageFrames: [ObjectIdentifier:NSRect] = [:]
    private var modernPageFrames: [ObjectIdentifier:NSRect] = [:]
    private var modernPageDecorations: [NSView] = []
    private var transcriptionHeading: NSTextField!
    private var transcriptionHint: NSTextField!
    private var accountHint: NSTextField!
    private var isModern = false

    private let rates = ConsolePopUpButton()
    private let mode = ConsolePopUpButton()
    private let queue = ConsolePopUpButton()
    private let tabs = NSTabView()
    private let catalogName = NSTextField(labelWithString: "等待读取视频目录")
    private let catalogTable = MediaTable(frame: NSRect(x: 14, y: 66, width: 760, height: 272))
    private let localTable = MediaTable(frame: NSRect(x: 14, y: 66, width: 760, height: 272))
    private let accountTable = MediaTable(frame: NSRect(x: 14, y: 88, width: 760, height: 220))
    private let listPicker = ConsolePopUpButton()
    private let autoSubtitles = ConsoleToggleButton("自动开启字幕，换集后重新加载")
    private let preferencePicker = ConsolePopUpButton()
    private let trackPicker = ConsolePopUpButton()
    private let trackStatus = NSTextField(wrappingLabelWithString: "等待视频提供字幕轨道")
    private let browserPicker = ConsolePopUpButton()
    private let transcriptionState = NSTextField(wrappingLabelWithString: "")
    private var transcriptionButton: ListeningButton!
    private let folderPicker = ConsolePopUpButton()
    private let accountScope = ConsolePopUpButton()
    private var accountSource: String?
    private let accountState = NSTextField(labelWithString: "点击读取，使用当前浏览器的 B 站登录状态")
    private var timer: Timer?
    private var lastLists: [ListeningList] = []
    private var lastTracks: [SubtitleTrack] = []
    private var lastFolders: [AccountFolder] = []
    private var pendingControls: Set<String> = []

    init(store: CaptionStore, library: ListeningLibrary, preferences: ListeningPreferences, transcriber: LocalTranscriber) {
        self.store = store; self.library = library; self.preferences = preferences; self.transcriber = transcriber
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 650), styleMask: [.titled,.closable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "B 站 · 听书控制台"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center(); build(); configureInterfaces()
    }
    required init?(coder: NSCoder) { fatalError() }
    @discardableResult private func label(_ value: String, _ frame: NSRect, in parent: NSView, small: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value); label.frame = frame
        label.font = .systemFont(ofSize: small ? 11 : 12); if small { label.textColor = .secondaryLabelColor }
        parent.addSubview(label)
        return label
    }
    @discardableResult private func button(_ value: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, in parent: NSView, _ action: @escaping () -> Void) -> ListeningButton {
        let button = ListeningButton(value, action: action); button.frame = NSRect(x: x, y: y, width: width, height: 28); parent.addSubview(button); return button
    }
    private func page(_ name: String) -> NSView {
        let item = NSTabViewItem(identifier: name); item.label = name
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 790, height: 380)); item.view = view; tabs.addTabViewItem(item); return view
    }
    private func build() {
        guard let root = window?.contentView else { return }
        titleLabel.frame = NSRect(x: 24,y: 604,width: 570,height: 24); titleLabel.font = .systemFont(ofSize: 18,weight: .semibold); titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSRect(x: 24,y: 580,width: 700,height: 20); subtitleLabel.font = .systemFont(ofSize: 11); subtitleLabel.textColor = .secondaryLabelColor
        root.addSubview(titleLabel); root.addSubview(subtitleLabel)
        button("切换新版", 608, 601, 104, in: root) { [weak self] in self?.setModern(true) }
        button("外观设置", 718, 601, 98, in: root) { [weak self] in self?.onSettings?() }
        previousButton = button("上一集",24,540,74,in:root) { [weak self] in self?.send("previousItem") }
        playButton = button("播放",106,540,74,in:root) { [weak self] in self?.send("togglePlayback") }
        nextButton = button("下一集",188,540,74,in:root) { [weak self] in self?.send("nextItem") }
        rates.frame = NSRect(x: 278,y: 540,width: 86,height: 28); rates.addItems(withTitles: ["0.5×","0.75×","1×","1.25×","1.5×","2×","2.5×","3×"]); rates.selectItem(at: 2); rates.target = self; rates.action = #selector(rateChanged); rates.setAccessibilityLabel("播放倍速"); root.addSubview(rates)
        mode.frame = NSRect(x: 378,y: 540,width: 146,height: 28); mode.addItems(withTitles: ["顺序连播","单集循环","播完本集停止"]); mode.selectItem(at: ["sequence","repeatOne","stopAfter"].firstIndex(of: preferences.playbackMode) ?? 0); mode.target = self; mode.action = #selector(modeChanged); mode.setAccessibilityLabel("播放模式"); root.addSubview(mode)
        queue.frame = NSRect(x: 538,y: 540,width: 278,height: 28); queue.addItems(withTitles: ["连播使用：网页目录","连播使用：所选本机听单"]); queue.selectItem(at: preferences.useLocalQueue ? 1 : 0); queue.target = self; queue.action = #selector(queueChanged); root.addSubview(queue)
        seek.cell = ConsoleSeekSliderCell()
        seek.frame = NSRect(x: 24,y: 505,width: 630,height: 20); seek.isContinuous = false; seek.target = self; seek.action = #selector(seekChanged); seek.setAccessibilityLabel("播放进度"); root.addSubview(seek)
        timeLabel.frame = NSRect(x: 665,y: 504,width: 150,height: 20); timeLabel.alignment = .right; timeLabel.font = .monospacedDigitSystemFont(ofSize: 11,weight: .regular); root.addSubview(timeLabel)
        tabs.frame = NSRect(x: 16,y: 64,width: 808,height: 425); root.addSubview(tabs)
        let catalog = page("视频目录")
        catalogName.frame = NSRect(x: 16,y: 350,width: 750,height: 22); catalogName.font = .systemFont(ofSize: 13,weight: .medium); catalog.addSubview(catalogName); catalog.addSubview(catalogTable)
        button("续听所选",14,22,96,in:catalog) { [weak self] in self?.play(self?.catalogTable.selected) }
        button("从头播放",118,22,96,in:catalog) { [weak self] in self?.play(self?.catalogTable.selected, resume: false) }
        button("保存整个目录为听单",458,22,172,in:catalog) { [weak self] in self?.saveCatalog() }
        button("加入所选听单",638,22,138,in:catalog) { [weak self] in self?.addToList(self?.catalogTable.selected.map { [$0] } ?? []) }
        let local = page("本机听单")
        listPicker.frame = NSRect(x: 14,y: 346,width: 340,height: 28); listPicker.target = self; listPicker.action = #selector(listChanged); listPicker.setAccessibilityLabel("本机听单"); local.addSubview(listPicker)
        button("新建",366,346,68,in:local) { [weak self] in self?.newList() }
        button("改名",440,346,68,in:local) { [weak self] in self?.renameList() }
        button("删除听单",514,346,90,in:local) { [weak self] in self?.deleteList() }
        button("添加视频链接",614,346,160,in:local) { [weak self] in self?.addLink() }
        local.addSubview(localTable)
        button("续听所选",14,22,96,in:local) { [weak self] in self?.play(self?.localTable.selected) }
        button("从头播放",118,22,96,in:local) { [weak self] in self?.play(self?.localTable.selected, resume: false) }
        button("加入当前视频",230,22,130,in:local) { [weak self] in guard let self, let item = self.currentItem() else { return }; self.addToList([item]) }
        button("上移",500,22,70,in:local) { [weak self] in self?.move(-1) }
        button("下移",578,22,70,in:local) { [weak self] in self?.move(1) }
        button("移除",656,22,118,in:local) { [weak self] in guard let self, let item = self.localTable.selected, let id = self.library.selectedListID else { return }; self.library.removeItem(id: item.id, from: id); self.refreshLibrary() }
        let subtitles = page("字幕与转写")
        autoSubtitles.frame = NSRect(x: 18,y: 342,width: 440,height: 26); autoSubtitles.state = preferences.autoSubtitle ? .on : .off; autoSubtitles.target = self; autoSubtitles.action = #selector(subtitleOptionsChanged); subtitles.addSubview(autoSubtitles)
        preferencePicker.frame = NSRect(x: 510,y: 342,width: 260,height: 28); preferencePicker.addItems(withTitles: ["优先 B 站 AI 中文字幕","优先人工中文字幕"]); preferencePicker.selectItem(at: preferences.subtitlePreference == "human" ? 1 : 0); preferencePicker.target = self; preferencePicker.action = #selector(subtitleOptionsChanged); subtitles.addSubview(preferencePicker)
        trackPicker.frame = NSRect(x: 18,y: 297,width: 450,height: 28); trackPicker.target = self; trackPicker.action = #selector(trackChanged); trackPicker.setAccessibilityLabel("字幕轨道"); subtitles.addSubview(trackPicker)
        button("开启字幕",486,297,132,in:subtitles) { [weak self] in self?.send("enableSubtitles") }
        button("重新同步",636,297,134,in:subtitles) { [weak self] in self?.send("resyncSubtitles") }
        trackStatus.frame = NSRect(x: 20,y: 244,width: 746,height: 38); trackStatus.font = .systemFont(ofSize: 12); trackStatus.textColor = .secondaryLabelColor; subtitles.addSubview(trackStatus)
        let divider = NSBox(frame: NSRect(x: 20,y: 229,width: 748,height: 1)); divider.boxType = .separator; subtitles.addSubview(divider)
        transcriptionHeading = label("无字幕视频 · 本机语音转写",NSRect(x: 20,y: 194,width: 740,height: 24),in:subtitles)
        transcriptionHint = label("仅在你开启时采集所选浏览器的声音，不使用麦克风，不上传音频。该浏览器其他标签页的声音也可能被识别。",NSRect(x: 20,y: 143,width: 740,height: 42),in:subtitles,small:true)
        browserPicker.frame = NSRect(x: 18,y: 103,width: 450,height: 28); browserPicker.setAccessibilityLabel("转写浏览器"); subtitles.addSubview(browserPicker)
        transcriptionButton = button("开始本机转写",486,103,180,in:subtitles) { [weak self] in self?.toggleTranscription() }
        button("刷新",684,103,86,in:subtitles) { [weak self] in self?.refreshBrowsers() }
        transcriptionState.frame = NSRect(x: 20,y: 20,width: 746,height: 70); transcriptionState.font = .systemFont(ofSize: 12); transcriptionState.textColor = .secondaryLabelColor; subtitles.addSubview(transcriptionState)
        let account = page("B 站账号")
        folderPicker.frame = NSRect(x: 14,y: 346,width: 510,height: 28); folderPicker.addItem(withTitle: "稍后再看"); folderPicker.lastItem?.representedObject = "watchlater"; folderPicker.target = self; folderPicker.action = #selector(loadAccount); folderPicker.setAccessibilityLabel("B 站收藏夹"); account.addSubview(folderPicker)
        button("读取 / 刷新",540,346,110,in:account) { [weak self] in self?.loadAccount() }
        button("导入本机听单",658,346,116,in:account) { [weak self] in self?.importAccount() }
        accountState.frame = NSRect(x: 16,y: 315,width: 756,height: 24); accountState.font = .systemFont(ofSize: 11); accountState.textColor = .secondaryLabelColor; account.addSubview(accountState); account.addSubview(accountTable)
        accountScope.frame = NSRect(x: 14,y: 49,width: 220,height: 28); accountScope.addItems(withTitles: ["添加：当前视频","添加：所选本机听单"]); account.addSubview(accountScope)
        button("加入稍后再看",246,49,184,in:account) { [weak self] in self?.writeAccount(favorite: false) }
        button("加入所选收藏夹",446,49,210,in:account) { [weak self] in self?.writeAccount(favorite: true) }
        accountHint = label("收藏操作只在点击按钮并确认目标后提交；本机听单与 B 站账号分别保存。",NSRect(x: 16,y: 13,width: 750,height: 24),in:account,small:true)
        feedback.frame = NSRect(x: 24,y: 16,width: 792,height: 36); feedback.maximumNumberOfLines = 2; feedback.lineBreakMode = .byTruncatingTail; feedback.font = .systemFont(ofSize: 11); feedback.textColor = .secondaryLabelColor; root.addSubview(feedback)
        for table in [catalogTable,localTable,accountTable] {
            table.progress = { [weak self] in self?.library.progress(for: $0) }
            table.onPlay = { [weak self] in self?.play($0) }
        }
        tabs.selectTabViewItem(at: 0)
        refreshLibrary(); refreshBrowsers(); refresh()
    }
    private var movingPlaybackViews: [NSView] { [previousButton,playButton,nextButton,rates,mode,queue,seek,timeLabel] }

    private func configureInterfaces() {
        classicRoot = window?.contentView
        catalogTable.emptyMessage=("还没有视频目录", "在浏览器打开 B 站视频，章节会自动同步到这里。")
        localTable.emptyMessage=("听单还是空的", "新建听单，添加链接或保存整本书的目录。")
        accountTable.emptyMessage=("把收藏带到这里", "点击「读取 / 刷新」，查看收藏夹与稍后再看。")
        for view in movingPlaybackViews + [tabs,feedback] { classicFrames[ObjectIdentifier(view)] = view.frame }
        for item in tabs.tabViewItems { for child in item.view?.subviews ?? [] { pageFrames[ObjectIdentifier(child)] = child.frame } }
        configureModernPageLayouts()
        trackPicker.placeholder = "暂无可用字幕轨道"
        listPicker.placeholder = "还没有听单"
        browserPicker.placeholder = "选择转写浏览器"
        modernShell = ModernConsoleShell(frame:NSRect(x:0,y:0,width:976,height:740))
        modernShell.onSelectPage = { [weak self] index in self?.tabs.selectTabViewItem(at:index); self?.modernShell.selectPage(index) }
        modernShell.onClassic = { [weak self] in self?.setModern(false) }
        modernShell.onSettings = { [weak self] in self?.onSettings?() }
        setModern(UserDefaults.standard.string(forKey:"consoleInterface") != "classic", persist:false)
    }

    /// Layout only: both interfaces continue to share the same controls and data.
    private func configureModernPageLayouts() {
        func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 32) {
            modernPageFrames[ObjectIdentifier(view)] = NSRect(x: x, y: y, width: width, height: height)
        }
        func action(_ title: String, in page: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat) {
            if let button = page.subviews.compactMap({ $0 as? ListeningButton }).first(where: { $0.title == title }) {
                place(button, x, y, width)
            }
        }
        func separator(in page: NSView, y: CGFloat) {
            let line = NSBox(frame: NSRect(x: 16, y: y, width: 712, height: 1))
            line.boxType = .separator; page.addSubview(line); modernPageDecorations.append(line)
        }
        guard let catalog = tabs.tabViewItem(at: 0).view,
              let local = tabs.tabViewItem(at: 1).view,
              let subtitles = tabs.tabViewItem(at: 2).view,
              let account = tabs.tabViewItem(at: 3).view else { return }
        place(catalogName, 16, 420, 712, 22)
        place(catalogTable, 16, 72, 712, 330)
        action("续听所选", in: catalog, 16, 16, 96)
        action("从头播放", in: catalog, 120, 16, 96)
        action("保存整个目录为听单", in: catalog, 408, 16, 176)
        action("加入所选听单", in: catalog, 592, 16, 136)
        separator(in: catalog, y: 60)

        place(listPicker, 16, 410, 260)
        action("新建", in: local, 288, 410, 52)
        action("改名", in: local, 348, 410, 52)
        action("删除听单", in: local, 408, 410, 80)
        action("添加视频链接", in: local, 600, 410, 128)
        place(localTable, 16, 72, 712, 322)
        action("续听所选", in: local, 16, 16, 96)
        action("从头播放", in: local, 120, 16, 96)
        action("加入当前视频", in: local, 232, 16, 130)
        action("上移", in: local, 520, 16, 64)
        action("下移", in: local, 592, 16, 64)
        action("移除", in: local, 664, 16, 64)
        separator(in: local, y: 60)

        let heading = label("B 站字幕", NSRect(x: 16, y: 420, width: 712, height: 20), in: subtitles)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        modernPageDecorations.append(heading)
        place(autoSubtitles, 16, 378, 360, 26)
        place(preferencePicker, 400, 376, 328)
        place(trackPicker, 16, 330, 418)
        action("开启字幕", in: subtitles, 450, 330, 128)
        action("重新同步", in: subtitles, 590, 330, 138)
        place(trackStatus, 16, 284, 712, 32)
        if let line = subtitles.subviews.first(where: { $0 is NSBox }) { place(line, 16, 266, 712, 1) }
        place(transcriptionHeading, 16, 225, 712, 20)
        place(transcriptionHint, 16, 181, 712, 32)
        place(browserPicker, 16, 126, 418)
        place(transcriptionButton, 450, 126, 180)
        action("刷新", in: subtitles, 642, 126, 86)
        place(transcriptionState, 16, 44, 712, 64)

        place(folderPicker, 16, 410, 428)
        action("读取 / 刷新", in: account, 456, 410, 120)
        action("导入本机听单", in: account, 588, 410, 140)
        place(accountState, 16, 380, 712, 18)
        place(accountTable, 16, 114, 712, 252)
        separator(in: account, y: 100)
        place(accountScope, 16, 58, 220)
        action("加入稍后再看", in: account, 248, 58, 184)
        action("加入所选收藏夹", in: account, 448, 58, 210)
        place(accountHint, 16, 20, 712, 22)
    }

    private func setModern(_ modern: Bool, persist: Bool = true) {
        guard let window else { return }
        window.makeFirstResponder(nil)
        let center=NSPoint(x:window.frame.midX,y:window.frame.midY)
        isModern=modern
        window.titleVisibility = modern ? .hidden : .visible
        window.titlebarAppearsTransparent = modern
        window.titlebarSeparatorStyle = modern ? .none : .automatic
        // Reading surfaces remain opaque; the sidebar and player are separate
        // visual regions inside the modern shell.
        window.isOpaque = true
        window.backgroundColor = modern ? ConsolePalette.background : .windowBackgroundColor
        if modern { window.styleMask.insert(.fullSizeContentView) }
        else { window.styleMask.remove(.fullSizeContentView) }
        if persist { UserDefaults.standard.set(modern ? "modern" : "classic",forKey:"consoleInterface") }
        let selected=tabs.selectedTabViewItem.flatMap { tabs.indexOfTabViewItem($0) } ?? 0
        if modern {
            window.contentView=modernShell
            tabs.tabViewType = .noTabsNoBorder; tabs.drawsBackground = false
            modernShell.contentHost.addSubview(tabs); tabs.frame=modernShell.contentHost.bounds
            for view in movingPlaybackViews { modernShell.playbackHost.addSubview(view) }
            previousButton.frame=NSRect(x:22,y:58,width:32,height:32)
            playButton.frame=NSRect(x:70,y:50,width:48,height:48)
            nextButton.frame=NSRect(x:134,y:58,width:32,height:32)
            rates.frame=NSRect(x:188,y:58,width:80,height:30)
            mode.frame=NSRect(x:280,y:58,width:146,height:30)
            queue.frame=NSRect(x:438,y:58,width:326,height:30)
            seek.frame=NSRect(x:188,y:26,width:414,height:18)
            timeLabel.frame=NSRect(x:614,y:25,width:150,height:18)
            modernShell.addSubview(feedback); feedback.frame=NSRect(x:220,y:174,width:724,height:18)
            modernShell.selectPage(selected)
        } else {
            window.contentView=classicRoot
            tabs.tabViewType = .topTabsBezelBorder; tabs.drawsBackground = true
            for view in movingPlaybackViews + [tabs,feedback] {
                classicRoot.addSubview(view)
                if let frame=classicFrames[ObjectIdentifier(view)] { view.frame=frame }
            }
        }
        for view in [previousButton!,playButton!,nextButton!] {
            view.modern=modern; view.primary = modern && view === playButton
            view.imagePosition = modern ? .imageOnly : .noImage
            view.isBordered = !modern
            if !modern { view.image=nil }
        }
        if modern {
            previousButton.image=NSImage(systemSymbolName:"backward.end.fill",accessibilityDescription:"上一集")
            nextButton.image=NSImage(systemSymbolName:"forward.end.fill",accessibilityDescription:"下一集")
        }
        for decoration in modernPageDecorations { decoration.isHidden = !modern }
        for item in tabs.tabViewItems {
            if let view=item.view {
                for child in view.subviews {
                    let id = ObjectIdentifier(child)
                    if let frame = modern ? modernPageFrames[id] : pageFrames[id] { child.frame = frame }
                }
                stylePage(view,modern:modern)
            }
        }
        (seek.cell as? ConsoleSeekSliderCell)?.modern=modern; seek.needsDisplay=true
        for table in [catalogTable,localTable,accountTable] { table.modern=modern }
        for popup in [rates,mode,queue,listPicker,preferencePicker,trackPicker,browserPicker,folderPicker,accountScope] {
            popup.modern = modern
            popup.font = .systemFont(ofSize: modern ? 11.5 : 12,weight:modern ? .medium : .regular)
            popup.contentTintColor = modern ? ModernPalette.text : nil
        }
        autoSubtitles.modern = modern
        feedback.font = .systemFont(ofSize:11)
        feedback.maximumNumberOfLines = modern ? 1 : 2
        catalogName.lineBreakMode = .byTruncatingTail
        transcriptionHeading.font = .systemFont(ofSize: modern ? 13 : 12, weight: modern ? .semibold : .regular)
        timeLabel.textColor = modern ? ModernPalette.secondary : .labelColor
        window.setContentSize(NSSize(width:modern ? 976 : 840,height:modern ? 740 : 650))
        var frame=window.frame; frame.origin=NSPoint(x:center.x-frame.width/2,y:center.y-frame.height/2)
        window.setFrame(window.constrainFrameRect(frame,to:window.screen),display:true)
        window.recalculateKeyViewLoop()
        refresh()
    }

    private func stylePage(_ view:NSView,modern:Bool) {
        if let button=view as? ListeningButton {
            button.modern=modern
            button.primary = modern && (["续听所选", "开启字幕", "读取 / 刷新"].contains(button.title) || button === transcriptionButton)
            button.destructive = modern && ["删除听单", "移除"].contains(button.title)
            button.font = .systemFont(ofSize: modern ? 11.5 : 12)
            button.contentTintColor = modern ? ModernPalette.text : nil
        }
        if let label=view as? NSTextField, !label.isEditable {
            let isHeading = label === catalogName || label === transcriptionHeading || modernPageDecorations.contains(where: { $0 === label })
            label.textColor = modern ? (isHeading ? ModernPalette.text : ModernPalette.secondary) : (label === catalogName ? .labelColor : .secondaryLabelColor)
        }
        // Tables own their reusable row views and appearance.
        if view is MediaTable { return }
        for child in view.subviews { stylePage(child,modern:modern) }
    }

    func open() {
        showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        refresh(); timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; library.flush() }
    func showFeedback(_ text: String, error: Bool = false) { feedback.stringValue = text; feedback.textColor = error ? .systemRed : .secondaryLabelColor }
    func controlResult(_ id: String, ok: Bool, error: String?) {
        guard pendingControls.remove(id) != nil else { return }
        showFeedback(ok ? "操作完成" : (error ?? "操作失败，请重试"), error: !ok); refresh()
    }
    private func send(_ action: String, _ arguments: [String: Any] = [:]) {
        guard let id = onCommand?(action, arguments) else { showFeedback("未连接到可控制的 B 站标签页，请打开视频并检查扩展。", error: true); return }
        pendingControls.insert(id); showFeedback("正在执行…")
    }
    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        let player = store.active(at: now); let source = store.activeSourceId(at: now)
        titleLabel.stringValue = player?.title ?? "等待 B 站连接"
        subtitleLabel.stringValue = player == nil ? "打开 B 站视频，扩展会自动连接" : "\(player!.paused ? "已暂停" : "播放中") · 断点自动保存 · \(preferences.useLocalQueue ? "本机听单连播" : "网页目录连播")"
        playButton.title = player?.paused == false ? "暂停" : "播放"; playButton.isEnabled = player != nil
        if isModern {
            playButton.image=NSImage(systemSymbolName:player?.paused == false ? "pause.fill" : "play.fill",accessibilityDescription:playButton.title)
            playButton.imagePosition = .imageOnly
            let display=store.display(at:now)
            modernShell?.update(title:player?.title ?? "打开 B 站视频开始收听",caption:captionProvider?() ?? display.text,connected:player != nil,paused:player?.paused ?? true)
        }
        let time = player?.position(at: now) ?? 0; let duration = player?.duration ?? 0
        if !seek.isHighlighted { seek.maxValue = max(1,duration); seek.doubleValue = time }; seek.isEnabled = duration > 0
        timeLabel.stringValue = "\(MediaTable.time(time)) / \(duration > 0 ? MediaTable.time(duration) : "—")"
        let rateValues = [0.5,0.75,1,1.25,1.5,2,2.5,3]
        if let player, let index = rateValues.firstIndex(of: player.rate) { rates.selectItem(at: index) }
        let catalog = store.catalog(for: source)
        catalogName.stringValue = catalog.map { "\($0.title) · \($0.items.count) 集" } ?? "等待读取视频目录"
        catalogName.toolTip = catalogName.stringValue
        let current = player.flatMap { canonicalVideoURL($0.pageKey) }
        catalogTable.update(catalog?.items ?? [], current: current)
        localTable.update(library.selectedList?.items ?? [], current: current)
        let tracks = catalog?.subtitles ?? []
        if tracks != lastTracks { lastTracks = tracks; trackPicker.removeAllItems(); for track in tracks { trackPicker.addItem(withTitle: track.label + (track.isAI ? " · AI" : "")); trackPicker.lastItem?.representedObject = track.id } }
        if let selected = catalog?.selectedSubtitleID, let i = tracks.firstIndex(where: { $0.id == selected }) { trackPicker.selectItem(at: i) }
        trackPicker.isEnabled = !tracks.isEmpty
        trackStatus.stringValue = catalog?.subtitleStatus ?? "等待视频提供字幕轨道；若视频没有 B 站字幕，可手动开启下面的本机转写。"
        transcriptionState.stringValue = transcriber.stateText
        transcriptionButton.title = transcriber.isRunning ? "停止本机转写" : "开始本机转写"
        if accountSource != source {
            accountSource = source; lastFolders = []
            folderPicker.removeAllItems(); folderPicker.addItem(withTitle: "稍后再看"); folderPicker.lastItem?.representedObject = "watchlater"
            accountState.stringValue = "点击读取，使用当前浏览器的 B 站登录状态"
        }
        let account = store.account(for: source)
        if let account {
            let accountError = account.error.flatMap { $0.isEmpty ? nil : $0 }
            accountState.stringValue = accountError ?? (account.loggedIn ? "已登录 · 当前列表 \(account.items.count) 项" : "未登录，请在浏览器中登录 B 站后刷新")
            if lastFolders != account.folders {
                let selected = folderPicker.selectedItem?.representedObject as? String
                lastFolders = account.folders; folderPicker.removeAllItems(); folderPicker.addItem(withTitle: "稍后再看"); folderPicker.lastItem?.representedObject = "watchlater"
                for folder in account.folders { folderPicker.addItem(withTitle: "\(folder.title)（\(folder.count)）"); folderPicker.lastItem?.representedObject = folder.id }
                if let i = folderPicker.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) { folderPicker.selectItem(at: i) }
            }
            // Never show a stale folder's rows underneath the newly selected folder label.
            let chosen = folderPicker.selectedItem?.representedObject as? String
            accountTable.update(account.folderID == chosen ? account.items : [], current: current)
        } else {
            accountTable.update([], current: current)
            accountState.stringValue = "点击读取，使用当前浏览器的 B 站登录状态"
            if !lastFolders.isEmpty {
                lastFolders = []; folderPicker.removeAllItems()
                folderPicker.addItem(withTitle: "稍后再看"); folderPicker.lastItem?.representedObject = "watchlater"
            }
        }
    }
    private func refreshLibrary() {
        if preferences.useLocalQueue && (library.selectedList?.items.isEmpty ?? true) {
            preferences.useLocalQueue = false; queue.selectItem(at: 0)
        }
        lastLists = library.lists; listPicker.removeAllItems()
        for list in library.lists { listPicker.addItem(withTitle: "\(list.name)（\(list.items.count)）"); listPicker.lastItem?.representedObject = list.id.uuidString }
        if let i = library.lists.firstIndex(where: { $0.id == library.selectedListID }) { listPicker.selectItem(at: i) }
        listPicker.isEnabled = !library.lists.isEmpty; refresh(); onChange?()
        if let error = library.lastError { showFeedback(error, error: true) }
    }
    private func prompt(_ title: String, value: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let input = NSTextField(string: value); input.frame = NSRect(x: 0,y: 0,width: 360,height: 26); alert.accessoryView = input
        alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
    }
    private func currentItem() -> MediaItem? {
        guard let player = store.active(at: ProcessInfo.processInfo.systemUptime), let url = canonicalVideoURL(player.pageKey) else { return nil }
        return MediaItem(id: url, url: url, title: player.title, duration: player.duration)
    }
    private func play(_ item: MediaItem?, resume: Bool = true) { guard let item else { showFeedback("请先选择一集"); return }; onPlayItem?(item,resume) }
    private func newList() { if let name = prompt("新建本机听单"), library.createList(name: name) != nil { refreshLibrary() } }
    private func renameList() { guard let list = library.selectedList, let name = prompt("重命名听单",value: list.name) else { return }; library.renameList(id: list.id,name: name); refreshLibrary() }
    private func deleteList() {
        guard let list = library.selectedList else { return }; let alert = NSAlert(); alert.messageText = "删除听单「\(list.name)」？"; alert.informativeText = "只删除本机听单，B 站收藏不受影响。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { library.deleteList(id: list.id); refreshLibrary() }
    }
    private func addLink() {
        guard library.selectedListID != nil else { showFeedback("请先新建听单"); return }
        guard let value = prompt("添加 B 站视频链接"), let url = canonicalVideoURL(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        guard let name = prompt("章节名称",value: URL(string:url)?.lastPathComponent ?? "B 站视频") else { return }
        addToList([MediaItem(id:url,url:url,title:name)])
    }
    private func addToList(_ items: [MediaItem]) {
        guard !items.isEmpty else { showFeedback("请先选择视频"); return }
        guard let id = library.selectedListID else { showFeedback("请先在「本机听单」新建或选择听单"); return }
        let count = library.addItems(items,to:id); refreshLibrary(); showFeedback(library.lastError ?? "已加入 \(count) 项；重复视频会自动跳过。", error: library.lastError != nil)
    }
    private func saveCatalog() {
        guard let catalog = store.catalog(for: store.activeSourceId(at: ProcessInfo.processInfo.systemUptime)), !catalog.items.isEmpty,
              let name = prompt("保存视频目录为听单",value: catalog.title), let id = library.createList(name:name) else { return }
        library.addItems(catalog.items,to:id); refreshLibrary(); showFeedback("已保存整个目录。可在「本机听单」中调整顺序。")
    }
    private func move(_ offset: Int) {
        guard let list = library.selectedList, let item = localTable.selected, let index = list.items.firstIndex(where: { $0.id == item.id }) else { return }
        library.moveItem(id:item.id,in:list.id,to:index+offset); refreshLibrary()
    }
    private func refreshBrowsers() {
        let selected = browserPicker.selectedItem?.representedObject as? String; browserPicker.removeAllItems()
        for browser in transcriber.availableBrowsers { browserPicker.addItem(withTitle: browser.title); browserPicker.lastItem?.representedObject = browser.id }
        if let i = browserPicker.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) { browserPicker.selectItem(at:i) }
    }
    private func toggleTranscription() {
        if transcriber.isRunning { transcriber.stop() }
        else if let id = browserPicker.selectedItem?.representedObject as? String { transcriber.start(bundleID:id) }
        else { showFeedback("请先打开 Chromium 浏览器，再点刷新",error:true) }
        refresh(); onChange?()
    }
    @objc private func rateChanged() { send("setPlaybackRate",["rate":[0.5,0.75,1,1.25,1.5,2,2.5,3][rates.indexOfSelectedItem]]) }
    @objc private func seekChanged() { send("seek",["time":seek.doubleValue]) }
    @objc private func modeChanged() { preferences.playbackMode = ["sequence","repeatOne","stopAfter"][mode.indexOfSelectedItem]; onChange?(); refresh() }
    @objc private func queueChanged() {
        if queue.indexOfSelectedItem == 1 && (library.selectedList?.items.isEmpty ?? true) { queue.selectItem(at:0); showFeedback("请先创建并选择一个非空本机听单"); return }
        preferences.useLocalQueue = queue.indexOfSelectedItem == 1; onChange?(); refresh()
    }
    @objc private func listChanged() { library.selectList(listPicker.selectedItem.flatMap { ($0.representedObject as? String).flatMap(UUID.init(uuidString:)) }); refreshLibrary() }
    @objc private func subtitleOptionsChanged() { preferences.autoSubtitle = autoSubtitles.state == .on; preferences.subtitlePreference = preferencePicker.indexOfSelectedItem == 1 ? "human" : "ai"; onChange?(); if preferences.autoSubtitle { send("resyncSubtitles") } }
    @objc private func trackChanged() { if let id = trackPicker.selectedItem?.representedObject as? String { send("selectSubtitle",["subtitleID":id]) } }
    @objc private func loadAccount() { send("loadAccount",["folderID":folderPicker.selectedItem?.representedObject as? String ?? "watchlater"]); refresh() }
    private func importAccount() {
        let items = accountTable.items; guard !items.isEmpty, let name = prompt("导入为本机听单",value:folderPicker.titleOfSelectedItem ?? "B 站听单"), let id = library.createList(name:name) else { return }
        library.addItems(items,to:id); refreshLibrary(); showFeedback("已导入 \(items.count) 项到本机")
    }
    private func writeAccount(favorite: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let source = store.activeSourceId(at: now), let account = store.account(for: source), account.loggedIn else {
            showFeedback("请先读取 B 站账号，确认已登录"); return
        }
        let items = accountScope.indexOfSelectedItem == 1 ? (library.selectedList?.items ?? []) : (currentItem().map { [$0] } ?? [])
        guard !items.isEmpty else { showFeedback("当前没有可添加的视频"); return }
        let folder = folderPicker.selectedItem?.representedObject as? String ?? "watchlater"
        guard !favorite || account.folders.contains(where: { $0.id == folder }) else { showFeedback("请先选择一个有效收藏夹"); return }
        let urls = Array(Set(items.compactMap { item -> String? in
            guard var parts = URLComponents(string: item.url) else { return nil }
            parts.query = nil; return parts.url?.absoluteString
        })).sorted()
        guard urls.count <= 100 else { showFeedback("一次最多添加 100 个独立视频，请先拆分听单。",error:true); return }
        let alert = NSAlert()
        alert.messageText = favorite ? "加入「\(folderPicker.titleOfSelectedItem ?? "收藏夹")」？" : "加入 B 站稍后再看？"
        alert.informativeText = items.count == 1 ? items[0].title : "将所选本机听单中的 \(items.count) 个章节加入 B 站账号；同一视频的多个分 P 会合并。"
        alert.addButton(withTitle:"加入"); alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn {
            guard store.activeSourceId(at: ProcessInfo.processInfo.systemUptime) == source,
                  store.account(for: source)?.loggedIn == true else { showFeedback("连接来源发生变化，请重新读取账号后再添加",error:true); return }
            send(favorite ? "saveFavorites" : "addWatchLater",favorite ? ["folderID":folder,"urls":urls] : ["urls":urls])
        }
    }
}
