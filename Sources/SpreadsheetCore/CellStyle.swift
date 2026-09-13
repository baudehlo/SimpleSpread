import Foundation

/// A simple RGBA color, independent of AppKit.
public struct RGBAColor: Hashable, Sendable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// Parse "RRGGBB" or "AARRGGBB" hex (as used by OOXML rgb attributes).
    public init?(argbHex: String) {
        var hex = argbHex.hasPrefix("#") ? String(argbHex.dropFirst()) : argbHex
        if hex.count == 6 { hex = "FF" + hex }
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        alpha = UInt8((value >> 24) & 0xFF)
        red = UInt8((value >> 16) & 0xFF)
        green = UInt8((value >> 8) & 0xFF)
        blue = UInt8(value & 0xFF)
    }

    /// "AARRGGBB" as written to XLSX.
    public var argbHex: String {
        String(format: "%02X%02X%02X%02X", alpha, red, green, blue)
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 255, green: 255, blue: 255)
}

public enum TextAlignmentH: String, Hashable, Sendable, Codable {
    /// Type-based: text left, numbers/dates right, booleans/errors centered.
    case automatic
    case left
    case center
    case right
}

public enum TextAlignmentV: String, Hashable, Sendable, Codable {
    case top
    case middle
    case bottom
}

/// Visual + number formatting attributes of a cell. Value semantics; deduplicated
/// into a workbook-level style table (mirrors XLSX cellXfs).
public struct CellStyle: Hashable, Sendable, Codable {
    public var fontName: String?
    public var fontSize: Double?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var textColor: RGBAColor?
    public var fillColor: RGBAColor?
    public var horizontalAlignment: TextAlignmentH
    public var verticalAlignment: TextAlignmentV
    public var wrapText: Bool
    public var numberFormat: NumberFormat

    public init(
        fontName: String? = nil,
        fontSize: Double? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        textColor: RGBAColor? = nil,
        fillColor: RGBAColor? = nil,
        horizontalAlignment: TextAlignmentH = .automatic,
        verticalAlignment: TextAlignmentV = .bottom,
        wrapText: Bool = false,
        numberFormat: NumberFormat = .general
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.textColor = textColor
        self.fillColor = fillColor
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.wrapText = wrapText
        self.numberFormat = numberFormat
    }

    public static let `default` = CellStyle()

    /// Default rendering font when fontName/fontSize are nil.
    public static let defaultFontName = "Helvetica Neue"
    public static let defaultFontSize = 12.0
}

/// Deduplicating style table; index 0 is always the default style.
public struct StyleTable: Sendable {
    public private(set) var styles: [CellStyle]
    private var indexByStyle: [CellStyle: Int]

    public init() {
        styles = [.default]
        indexByStyle = [.default: 0]
    }

    public var count: Int { styles.count }

    public subscript(index: Int) -> CellStyle {
        (index >= 0 && index < styles.count) ? styles[index] : .default
    }

    /// Return the index for a style, interning it if new.
    public mutating func index(for style: CellStyle) -> Int {
        if let existing = indexByStyle[style] { return existing }
        styles.append(style)
        let idx = styles.count - 1
        indexByStyle[style] = idx
        return idx
    }
}
