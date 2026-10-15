import SwiftUI
import SpreadsheetCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The few things AppKit and UIKit name differently. Shared code uses these
// and never tests the platform itself; everything else platform-specific
// lives in Mac/ and iOS/.

#if os(macOS)
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
/// The window a document's progress panels and prompts belong to.
typealias HostWindow = NSWindow
#else
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
typealias HostWindow = UIWindow
#endif

// MARK: Colours

/// The system colours the grid and the window chrome use. All of them
/// follow light and dark mode.
enum SystemColors {
    #if os(macOS)
    static var textBackground: PlatformColor { .textBackgroundColor }
    static var windowBackground: PlatformColor { .windowBackgroundColor }
    static var controlBackground: PlatformColor { .controlBackgroundColor }
    static var separator: PlatformColor { .separatorColor }
    static var accent: PlatformColor { .controlAccentColor }
    static var text: PlatformColor { .textColor }
    static var label: PlatformColor { .labelColor }
    static var secondaryLabel: PlatformColor { .secondaryLabelColor }
    static var tertiaryLabel: PlatformColor { .tertiaryLabelColor }
    #else
    static var textBackground: PlatformColor { .systemBackground }
    static var windowBackground: PlatformColor { .secondarySystemBackground }
    static var controlBackground: PlatformColor { .systemBackground }
    static var separator: PlatformColor { .separator }
    static var accent: PlatformColor { .tintColor }
    static var text: PlatformColor { .label }
    static var label: PlatformColor { .label }
    static var secondaryLabel: PlatformColor { .secondaryLabel }
    static var tertiaryLabel: PlatformColor { .tertiaryLabel }
    #endif

    /// A colour that differs in light and dark mode.
    static func dynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
        #else
        UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        #endif
    }
}

extension PlatformColor {
    /// A cell's stored colour.
    convenience init(rgba c: RGBAColor) {
        #if os(macOS)
        self.init(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255,
                  blue: CGFloat(c.blue) / 255, alpha: CGFloat(c.alpha) / 255)
        #else
        self.init(red: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255,
                  blue: CGFloat(c.blue) / 255, alpha: CGFloat(c.alpha) / 255)
        #endif
    }
}

extension Color {
    static var textBackground: Color { Color(SystemColors.textBackground) }
    static var windowBackground: Color { Color(SystemColors.windowBackground) }
    static var controlBackground: Color { Color(SystemColors.controlBackground) }
    static var separator: Color { Color(SystemColors.separator) }
    static var text: Color { Color(SystemColors.text) }
}

extension RGBAColor {
    /// A colour picked in SwiftUI, in sRGB; nil if it has no sRGB form.
    init?(_ color: Color) {
        #if os(macOS)
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let (r, g, b, a) = (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #endif
        // Extended-range components (a wide-gamut pick) clamp to sRGB.
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded(.down)) }
        self.init(red: byte(r), green: byte(g), blue: byte(b), alpha: byte(a))
    }
}

// MARK: Fonts

extension PlatformFont {
    /// A cell's font: the named face (the system font if it isn't
    /// installed) with bold and italic applied.
    static func cellFont(name: String?, size: CGFloat, bold: Bool = false, italic: Bool = false) -> PlatformFont {
        let base = PlatformFont(name: name ?? CellStyle.defaultFontName, size: size)
            ?? PlatformFont.systemFont(ofSize: size)
        guard bold || italic else { return base }
        #if os(macOS)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
        #else
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }
}

// MARK: SwiftUI controls

extension View {
    /// A checkbox: AppKit's on the Mac, a checkmark square on iPad.
    @ViewBuilder func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(CheckboxToggleStyle())
        #endif
    }

    /// A text-like button (AppKit's link style on the Mac).
    @ViewBuilder func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// Radio buttons on the Mac; an inline list on iPad.
    @ViewBuilder func radioGroupPickerStyle() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        pickerStyle(.inline)
        #endif
    }

    /// The format toolbar's menus: borderless on the Mac, plain tinted
    /// buttons on iPad.
    @ViewBuilder func toolbarMenuStyle() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton)
        #else
        menuStyle(.button).buttonStyle(.borderless)
        #endif
    }

    /// Escape (the Mac's cancel command; a hardware keyboard's Esc on iPad).
    @ViewBuilder func onEscape(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) {
            action()
            return .handled
        }
        #endif
    }

    /// The window subtitle ("— Edited"); iPad windows have none.
    @ViewBuilder func windowSubtitle(_ text: String) -> some View {
        #if os(macOS)
        navigationSubtitle(text)
        #else
        self
        #endif
    }
}

#if os(iOS)
/// A Mac-style checkbox for iPad lists of options.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                configuration.label
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
