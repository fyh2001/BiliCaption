import AppKit

/// Colours shared by the modern shell and its functional content. The classic UI
/// remains free to use system defaults; changing console style changes no data.
enum ModernPalette {
    private static func color(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        func make(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: alpha)
        }
        return NSColor(name: nil) { appearance in
            make(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
    static let background = color(0xF7F7FC, 0x181921)
    static let sidebar = color(0xEFEEF8, 0x20212D)
    static let surface = color(0xFFFFFF, 0x252632)
    static let inset = color(0xF4F3FA, 0x30313E)
    static let border = color(0xE7E6F0, 0x3A3B49)
    static let accent = color(0x6555D9, 0xB6A8FF)
    static let accentSoft = color(0xE5E0FB, 0x3A3358)
    static let coral = color(0xED8E85, 0xF2A29A)
    static let text = color(0x242B2B, 0xEEF2F1)
    static let secondary = color(0x727B7A, 0xA6B0AE)
    static let muted = color(0x9AA2A0, 0x7D8986)
    static let connected = color(0x3C9B7B, 0x83D6B3)
    static let primaryFill = color(0x6555D9, 0x8773EB)
    static let primaryText = NSColor.white
}

/// Quiet, opaque surfaces keep the console readable beside other windows.
enum ConsolePalette {
    private static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }
    static let accent = color(0x277D70, 0x83CDBA)
    static let primaryFill = color(0x277D70, 0x346F62)
    static let primaryText = NSColor.white
    static let controlFill = color(0xF4F6F5, 0x292F2D)
    static let selectionFill = color(0xE9F3EF, 0x2A4039)
    static let background = color(0xFFFFFF, 0x202523)
    static let sidebar = color(0xF4F6F5, 0x191F1D)
    static let divider = color(0xE9EDEA, 0x333B37)
    static let contentFill = color(0xFFFFFF, 0x202523)
    static let playerFill = color(0xF8FAF9, 0x242B28)
}

private final class ConsoleSurface: NSView {
    let fill: NSColor
    let radius: CGFloat
    init(frame: NSRect, fill: NSColor, radius: CGFloat) {
        self.fill = fill; self.radius = radius
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = radius; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private func modernSymbol(_ name: String, pointSize: CGFloat, color: NSColor, weight: NSFont.Weight = .medium) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
}

/// A compact player mark, not a thumbnail of the current video.
private final class ConsolePlayerMark: NSView {
    override func draw(_ dirtyRect: NSRect) {
        ConsolePalette.selectionFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        modernSymbol("waveform", pointSize: 24, color: ConsolePalette.accent, weight: .regular)?
            .draw(in: bounds.insetBy(dx: 12, dy: 12))
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Shared console button treatment. Primary actions have the only permanent
/// accent fill; secondary actions stay quiet until hover or keyboard focus.
class ConsoleButton: NSButton {
    var modern = false { didSet { isBordered = !modern; needsDisplay = true } }
    var primary = false { didSet { needsDisplay = true } }
    var destructive = false { didSet { needsDisplay = true } }

    private var hovered = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area); tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard modern else { super.draw(dirtyRect); return }
        let transport = imagePosition == .imageOnly
        let radius = transport ? min(bounds.height, bounds.width) / 2 : 10
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                 xRadius: radius, yRadius: radius)
        let opacity: CGFloat = isEnabled ? 1 : 0.42
        let active = hovered || isHighlighted

        if primary {
            let base = ConsolePalette.primaryFill
            let fill = active ? (base.blended(withFraction: 0.12, of: .white) ?? base) : base
            fill.withAlphaComponent(opacity).setFill(); shape.fill()
        } else if transport {
            NSColor.labelColor.withAlphaComponent((active ? 0.075 : 0.035) * opacity).setFill()
            shape.fill()
        } else if active {
            (destructive ? NSColor.systemRed : ConsolePalette.accent)
                .withAlphaComponent(0.075 * opacity).setFill()
            shape.fill()
        }

        let ink: NSColor = !isEnabled ? ModernPalette.muted :
            (primary ? ConsolePalette.primaryText : (destructive ? .systemRed : ModernPalette.text))
        if transport, let image {
            let size: CGFloat = primary ? 19 : 14
            let tinted = image.copy() as! NSImage
            tinted.lockFocus()
            ink.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: (bounds.width - size) / 2,
                                   y: (bounds.height - size) / 2,
                                   width: size, height: size))
        } else {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: primary ? .semibold : .medium),
                .foregroundColor: ink.withAlphaComponent(opacity),
                .paragraphStyle: style
            ]
            let height = ceil((title as NSString).size(withAttributes: attributes).height)
            (title as NSString).draw(in: NSRect(x: 10, y: (bounds.height - height) / 2,
                                               width: bounds.width - 20, height: height),
                                     withAttributes: attributes)
        }

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.7).setStroke()
            shape.lineWidth = 2; shape.stroke()
        }
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds,
                     xRadius: min(bounds.height, bounds.width) / 2,
                     yRadius: min(bounds.height, bounds.width) / 2).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// A custom pop-up field with one chevron while preserving native menu handling.
final class ConsolePopUpButton: NSPopUpButton {
    var modern = false { didSet { needsDisplay = true } }
    var placeholder = "未选择" { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard modern else { super.draw(dirtyRect); return }
        let opacity: CGFloat = isEnabled ? 1 : 0.42
        let active = hovered || isHighlighted
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                               xRadius: 9, yRadius: 9)
        (active ? ConsolePalette.selectionFill : ConsolePalette.controlFill)
            .withAlphaComponent(opacity).setFill()
        box.fill()
        NSColor.labelColor.withAlphaComponent((active ? 0.12 : 0.055) * opacity).setStroke()
        box.lineWidth = 0.75; box.stroke()

        let value = titleOfSelectedItem ?? placeholder
        let ink = isEnabled ? ModernPalette.text : ModernPalette.muted
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(opacity),
            .paragraphStyle: paragraph
        ]
        let height = ceil((value as NSString).size(withAttributes: attributes).height)
        (value as NSString).draw(in: NSRect(x: 12, y: (bounds.height - height) / 2,
                                            width: bounds.width - 42, height: height),
                                 withAttributes: attributes)
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: bounds.width - 20, y: bounds.midY - 3))
        chevron.line(to: NSPoint(x: bounds.width - 16, y: bounds.midY + 1))
        chevron.line(to: NSPoint(x: bounds.width - 12, y: bounds.midY - 3))
        chevron.lineWidth = 1.6; chevron.lineCapStyle = .round
        ink.withAlphaComponent(0.72 * opacity).setStroke(); chevron.stroke()
    }
    override var focusRingMaskBounds: NSRect { modern ? bounds.insetBy(dx: 1, dy: 1) : super.focusRingMaskBounds }
    override func drawFocusRingMask() {
        guard modern else { super.drawFocusRingMask(); return }
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 9, yRadius: 9).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// A labelled switch that keeps NSButton's native keyboard and action handling.
final class ConsoleToggleButton: NSButton {
    var modern = false { didSet { isBordered = !modern; needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(_ title: String) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.toggle)
        isBordered = true
        font = .systemFont(ofSize: 12)
        setAccessibilityLabel(title)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue("关闭")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override var state: NSControl.StateValue {
        didSet { needsDisplay = true; setAccessibilityValue(state == .on ? "开启" : "关闭") }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isOn = state == .on
        if !modern {
            let box = NSRect(x: 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
            let boxPath = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            if isOn {
                NSColor.controlAccentColor.setFill(); boxPath.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3, y: box.midY))
                check.line(to: NSPoint(x: box.minX + 6, y: box.minY + 3))
                check.line(to: NSPoint(x: box.maxX - 2, y: box.maxY - 3))
                check.lineWidth = 1.8; check.lineCapStyle = .round
                NSColor.white.setStroke(); check.stroke()
            } else {
                NSColor.tertiaryLabelColor.setStroke(); boxPath.lineWidth = 1; boxPath.stroke()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ]
            (title as NSString).draw(at: NSPoint(x: 22, y: (bounds.height - 17) / 2),
                                     withAttributes: attrs)
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: ModernPalette.text,
            .paragraphStyle: paragraph
        ]
        let height = ceil((title as NSString).size(withAttributes: attrs).height)
        (title as NSString).draw(in: NSRect(x: 2, y: (bounds.height - height) / 2,
                                            width: bounds.width - 52, height: height),
                                 withAttributes: attrs)

        let track = NSRect(x: bounds.width - 38, y: (bounds.height - 20) / 2,
                           width: 36, height: 20)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10)
        let trackFill = isOn ? ConsolePalette.primaryFill :
            NSColor.labelColor.withAlphaComponent(hovered ? 0.16 : 0.10)
        trackFill.setFill(); trackPath.fill()
        let knobX = isOn ? track.maxX - 18 : track.minX + 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX, y: track.minY + 2, width: 16, height: 16)).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// Header utilities remain flat until hover, avoiding rows of utility pills.
final class ModernActionButton: NSButton {
    var handler: (() -> Void)?
    var symbolName: String?
    var primary: Bool
    var leadingAligned = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(title: String, symbol: String? = nil, primary: Bool = false, action: @escaping () -> Void) {
        self.symbolName = symbol; self.primary = primary; self.handler = action
        super.init(frame: .zero)
        self.title = title; font = .systemFont(ofSize: 11.5, weight: .medium)
        isBordered = false; bezelStyle = .regularSquare; setButtonType(.momentaryPushIn)
        target = self; self.action = #selector(activate)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func activate() { handler?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                 xRadius: 9, yRadius: 9)
        let active = hovered || isHighlighted
        if active {
            NSColor.labelColor.withAlphaComponent(0.065).setFill(); shape.fill()
        }
        let ink = active ? ModernPalette.text : ModernPalette.secondary
        let iconWidth: CGFloat = symbolName == nil ? 0 : 15
        let gap: CGFloat = symbolName == nil ? 0 : 7
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: ink
        ]
        let measured = (title as NSString).size(withAttributes: attrs)
        let total = iconWidth + gap + measured.width
        let start: CGFloat = leadingAligned ? 14 : (bounds.width - total) / 2
        if let symbolName {
            modernSymbol(symbolName, pointSize: 13, color: ink, weight: .regular)?
                .draw(in: NSRect(x: start, y: (bounds.height - 15) / 2,
                                 width: 15, height: 15))
        }
        (title as NSString).draw(at: NSPoint(x: start + iconWidth + gap,
                                             y: (bounds.height - measured.height) / 2),
                                 withAttributes: attrs)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 9, yRadius: 9).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

private final class ModernNavigationButton: NSButton {
    let symbolName: String
    var chosen = false {
        didSet {
            state = chosen ? .on : .off
            setAccessibilityValue(chosen ? "已选中" : "")
            needsDisplay = true
        }
    }
    var handler: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(title: String, symbol: String, frame: NSRect) {
        symbolName = symbol
        super.init(frame: frame)
        self.title = title; isBordered = false; setButtonType(.momentaryPushIn)
        target = self; action = #selector(activate); focusRingType = .exterior
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func activate() { handler?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        if chosen {
            ConsolePalette.selectionFill.setFill(); shape.fill()
        } else if hovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.04).setFill(); shape.fill()
        }
        let ink = chosen ? ConsolePalette.accent : ModernPalette.secondary
        modernSymbol(symbolName, pointSize: 16, color: ink, weight: chosen ? .semibold : .regular)?
            .draw(in: NSRect(x: 13, y: (bounds.height - 18) / 2, width: 18, height: 18))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: chosen ? .semibold : .medium),
            .foregroundColor: chosen ? ModernPalette.text : ModernPalette.secondary
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 43, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 9, yRadius: 9).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// A fixed library sidebar, open reading canvas and quiet persistent player.
/// Playback and library state continue to live in the controller.
final class ModernConsoleShell: NSView {
    let contentHost: NSView
    let playbackHost: NSView
    let playerTitle = NSTextField(labelWithString: "打开 B 站视频开始收听")
    let subtitle = NSTextField(labelWithString: "连接后会显示视频标题和实时字幕。")
    let connection = NSTextField(labelWithString: "等待连接")
    var onSelectPage: ((Int) -> Void)?
    var onClassic: (() -> Void)?
    var onSettings: (() -> Void)?

    private let connectionDot = NSView()
    private let pageHeading = NSTextField(labelWithString: "正在收听")
    private let pageDetail = NSTextField(labelWithString: "视频章节与播放进度")
    private var navigation: [ModernNavigationButton] = []
    private var connected = false
    private let pages = [("正在收听", "headphones", "视频章节与播放进度"),
                         ("我的听单", "rectangle.stack", "收藏想听的故事，随时接着听"),
                         ("字幕与转写", "captions.bubble", "选择字幕来源，让每一句都跟上播放"),
                         ("B 站收藏", "bookmark", "从收藏夹和稍后再看，整理下一份听单")]

    override init(frame: NSRect) {
        contentHost = ConsoleSurface(frame: NSRect(x: 208, y: 192, width: 744, height: 454),
                                     fill: ConsolePalette.contentFill, radius: 0)
        playbackHost = ConsoleSurface(frame: NSRect(x: 188, y: 0, width: 788, height: 168),
                                      fill: ConsolePalette.playerFill, radius: 0)
        super.init(frame: frame)
        addSubview(contentHost); addSubview(playbackHost)
        buildHeader(); buildNavigation(); buildPlayer(); selectPage(0)
        setAccessibilityLabel("听书控制台 · 现代版")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ConsolePalette.background.setFill(); bounds.fill()
        ConsolePalette.sidebar.setFill(); NSRect(x: 0, y: 0, width: 188, height: bounds.height).fill()
        ConsolePalette.divider.setFill()
        NSRect(x: 187, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 188, y: 168, width: bounds.width - 188, height: 1).fill()
        NSRect(x: 220, y: 653, width: 724, height: 1).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true; updateDot()
    }
    private func label(_ title: String, frame: NSRect, size: CGFloat,
                       weight: NSFont.Weight = .regular, color: NSColor = ModernPalette.secondary) {
        let text = NSTextField(labelWithString: title)
        text.frame = frame; text.font = .systemFont(ofSize: size, weight: weight); text.textColor = color
        addSubview(text)
    }
    private func buildHeader() {
        let brand = ConsoleSurface(frame: NSRect(x: 20, y: 653, width: 32, height: 32),
                                   fill: ConsolePalette.primaryFill, radius: 10)
        let mark = NSImageView(frame: NSRect(x: 8, y: 8, width: 16, height: 16))
        mark.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        mark.contentTintColor = .white; brand.addSubview(mark); addSubview(brand)
        label("听书", frame: NSRect(x: 62, y: 666, width: 104, height: 23),
              size: 17, weight: .semibold, color: ModernPalette.text)
        label("B 站 · 字幕伴侣", frame: NSRect(x: 62, y: 648, width: 114, height: 18), size: 10)

        pageHeading.frame = NSRect(x: 224, y: 689, width: 692, height: 30)
        pageHeading.font = .systemFont(ofSize: 23, weight: .semibold)
        pageHeading.textColor = ModernPalette.text; addSubview(pageHeading)
        pageDetail.frame = NSRect(x: 225, y: 666, width: 692, height: 18)
        pageDetail.font = .systemFont(ofSize: 11.5); pageDetail.textColor = ModernPalette.secondary
        addSubview(pageDetail)

        label("偏好设置", frame: NSRect(x: 25, y: 165, width: 140, height: 18), size: 10.5)
        let settings = ModernActionButton(title: "字幕与外观", symbol: "slider.horizontal.3") { [weak self] in self?.onSettings?() }
        settings.leadingAligned = true
        settings.frame = NSRect(x: 12, y: 124, width: 164, height: 34)
        settings.toolTip = "调整字幕显示位置、玻璃材质与外观"; addSubview(settings)
        let classic = ModernActionButton(title: "切换经典版", symbol: "rectangle.on.rectangle") { [weak self] in self?.onClassic?() }
        classic.leadingAligned = true
        classic.frame = NSRect(x: 12, y: 86, width: 164, height: 34)
        classic.toolTip = "切回原有控制台，听单和播放进度保持不变"; addSubview(classic)

        connectionDot.frame = NSRect(x: 25, y: 38, width: 5, height: 5)
        connectionDot.wantsLayer = true; connectionDot.layer?.cornerRadius = 2.5; addSubview(connectionDot)
        connection.frame = NSRect(x: 38, y: 31, width: 138, height: 19)
        connection.font = .systemFont(ofSize: 10.5)
        connection.textColor = ModernPalette.secondary; connection.lineBreakMode = .byTruncatingTail
        addSubview(connection); updateDot()
    }
    private func buildNavigation() {
        label("资料库", frame: NSRect(x: 25, y: 602, width: 140, height: 18), size: 10.5)
        for (index, item) in pages.enumerated() {
            let button = ModernNavigationButton(title: item.0, symbol: item.1,
                frame: NSRect(x: 12, y: 551 - CGFloat(index) * 48, width: 164, height: 42))
            button.handler = { [weak self] in self?.selectPage(index); self?.onSelectPage?(index) }
            navigation.append(button); addSubview(button)
        }
    }
    private func buildPlayer() {
        let mark = ConsolePlayerMark(frame: NSRect(x: 24, y: 106, width: 44, height: 44))
        playbackHost.addSubview(mark)
        playerTitle.frame = NSRect(x: 82, y: 134, width: 682, height: 18)
        playerTitle.font = .systemFont(ofSize: 11.5, weight: .medium)
        playerTitle.textColor = ModernPalette.secondary; playerTitle.lineBreakMode = .byTruncatingTail
        playbackHost.addSubview(playerTitle)
        subtitle.frame = NSRect(x: 82, y: 106, width: 682, height: 22)
        subtitle.font = .systemFont(ofSize: 14.5, weight: .medium); subtitle.textColor = ModernPalette.text
        subtitle.maximumNumberOfLines = 1; subtitle.lineBreakMode = .byTruncatingTail
        playbackHost.addSubview(subtitle)
    }
    func selectPage(_ index: Int) {
        guard navigation.indices.contains(index) else { return }
        for (offset, button) in navigation.enumerated() { button.chosen = offset == index }
        pageHeading.stringValue = pages[index].0
        pageDetail.stringValue = pages[index].2
    }
    func update(title: String, caption: String, connected: Bool, paused: Bool) {
        let displayTitle = connected && !title.isEmpty ? title : "打开 B 站视频开始收听"
        if playerTitle.stringValue != displayTitle {
            playerTitle.stringValue = displayTitle; playerTitle.toolTip = displayTitle
        }
        let copy = !connected ? "连接后会显示视频标题和实时字幕。" :
            (caption.isEmpty || caption == "♪" ? "当前暂无字幕" : caption)
        if subtitle.stringValue != copy { subtitle.stringValue = copy; subtitle.toolTip = copy }
        let connectionChanged = self.connected != connected
        self.connected = connected
        let status = connected ? (paused ? "已连接 · 已暂停" : "已连接 · 播放中") : "等待 B 站连接"
        if connection.stringValue != status { connection.stringValue = status }
        if connectionChanged { updateDot() }
    }
    private func updateDot() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            connectionDot.layer?.backgroundColor = (connected ? ModernPalette.connected : ModernPalette.muted).cgColor
        }
    }
}
