import AppKit
import ObjectiveC

/// Material and transparency are independent choices. A slider never chooses
/// a material, and each surface persists its own selection.
enum GlassMaterial: String, CaseIterable {
    case soft
    case clear

    var title: String {
        switch self {
        case .soft: return "柔和玻璃"
        case .clear: return "系统清透玻璃"
        }
    }

    var isAvailable: Bool {
        if self == .soft { return true }
        if #available(macOS 26.0, *) {
            #if compiler(>=6.2)
            return true
            #else
            return false
            #endif
        }
        return false
    }

    static func resolve(_ rawValue: String?, default fallback: GlassMaterial) -> GlassMaterial {
        let value = rawValue.flatMap(Self.init(rawValue:)) ?? fallback
        return value.isAvailable ? value : .soft
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    var nativeStyle: NSGlassEffectView.Style { self == .soft ? .regular : .clear }
    #endif
}

/// Both native glass surfaces use the same transparency scale. Their chosen
/// material and stored transparency remain independent. At 100 there is no
/// app-added tint; the system still supplies its own adaptive glass effect.
enum GlassAppearance {
    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static func applyTransparency(_ value: Double, to glass: NSGlassEffectView) {
        let transparency = value.isFinite ? min(100, max(10, value)) : 45
        let density = CGFloat((100 - transparency) / 90)
        glass.tintColor = density > 0
            ? NSColor.windowBackgroundColor.withAlphaComponent(density * 0.5)
            : nil
        // The content view includes text and controls; fade only the tint.
        glass.alphaValue = 1
    }
    #endif
}

/// Compatibility workaround for AppKit's inactive-window glass fallback.
/// `_hasActiveAppearance` is NOT a public API. Keep it scoped to our two
/// borderless panels, only for clear glass on the tested macOS generation.
/// This never changes isKeyWindow/isMainWindow, activates an app, or takes focus.
class CaptionGlassPanel: NSPanel {
    var glassMaterial: GlassMaterial = .soft

    private typealias NativeAppearance = @convention(c) (AnyObject, Selector) -> ObjCBool
    private static let activeAppearanceSelector = NSSelectorFromString("_hasActiveAppearance")
    private static let nativeMethod: Method? = {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard (26...27).contains(major),
              !UserDefaults.standard.bool(forKey: "disableStableClearGlass") else { return nil }
        guard let method = class_getInstanceMethod(NSPanel.self, activeAppearanceSelector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        let receiverType = method_copyArgumentType(method, 0)
        let selectorType = method_copyArgumentType(method, 1)
        defer { free(returnType); free(receiverType); free(selectorType) }
        guard let receiverType, let selectorType,
              ["B", "c"].contains(String(cString: returnType)),
              String(cString: receiverType) == "@", String(cString: selectorType) == ":" else { return nil }
        return method
    }()
    private static let nativeAppearance: NativeAppearance? = nativeMethod.map {
        unsafeBitCast(method_getImplementation($0), to: NativeAppearance.self)
    }
    private static let compatibilityInstalled: Bool = {
        guard let original = nativeMethod,
              let trampoline = class_getInstanceMethod(CaptionGlassPanel.self,
                  #selector(captionGlassHasActiveAppearance)) else { return false }
        // Add only to our own class after checking the inherited ABI. Unknown
        // OS versions/signatures inherit AppKit untouched, rather than calling
        // a statically registered override with a potentially changed ABI.
        return class_addMethod(CaptionGlassPanel.self, activeAppearanceSelector,
                               method_getImplementation(trampoline), method_getTypeEncoding(original))
    }()

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        _ = CaptionGlassPanel.compatibilityInstalled
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    }

    @objc(captionStableGlassAppearance)
    func captionGlassHasActiveAppearance() -> Bool {
        if glassMaterial == .clear, Self.compatibilityInstalled {
            return true
        }
        // Keep the real AppKit appearance for soft glass, old/future systems,
        // and the diagnostic opt-out. Do not call super via our own selector.
        return Self.nativeAppearance?(self, Self.activeAppearanceSelector).boolValue
            ?? (isKeyWindow || isMainWindow)
    }
}
