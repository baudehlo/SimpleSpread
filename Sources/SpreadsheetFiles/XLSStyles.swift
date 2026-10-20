import Foundation
import SpreadsheetCore

struct XLSStyleCatalog {
    struct Font {
        var height = 200
        var italic = false
        var strike = false
        var colorIndex = 0
        var bold = false
        var underline = false
        var name = "Arial"
    }

    struct XF {
        var font = 0
        var format = 0
        var alignment: UInt8 = 0
        var rotation: UInt8 = 0
        var textProperties: UInt8 = 0
        var border1: UInt32 = 0
        var border2: UInt32 = 0
        var fill: UInt16 = 0
    }

    var fonts: [Font] = []
    var formats: [Int: String] = [:]
    var xfs: [XF] = []
    var palette: [RGBAColor] = XLSStyleCatalog.defaultPalette
    var hasUnsupportedFeatures = false

    static func parse(_ records: [BIFFRecord]) throws -> XLSStyleCatalog {
        var result = XLSStyleCatalog()
        var sawPalette = false
        for record in records {
            switch record.type {
            case 0x0031:
                result.fonts.append(try parseFont(record.data))
            case 0x041E:
                guard record.data.count >= 5 else { throw XLSError.malformed("Invalid FORMAT record.") }
                let id = Int(try record.data.readU16(0))
                let code = try BIFFString.read(record.data, at: 2).text
                result.formats[id] = code.caseInsensitiveCompare("General") == .orderedSame ? "" : code
            case 0x00E0:
                let xf = try parseXF(record.data)
                let pattern = (xf.border2 >> 26) & 0x3F
                if xf.rotation != 0 || pattern > 1 || ((xf.border2 >> 21) & 0x1F) != 0 {
                    result.hasUnsupportedFeatures = true
                }
                result.xfs.append(xf)
            case 0x0092:
                guard record.data.count >= 2 else { throw XLSError.malformed("Invalid PALETTE record.") }
                let count = Int(try record.data.readU16(0))
                guard count <= 56, record.data.count == 2 + count * 4 else { throw XLSError.malformed("Invalid PALETTE record.") }
                if !sawPalette { result.palette = []; sawPalette = true }
                for index in 0..<count {
                    let p = 2 + index * 4
                    result.palette.append(RGBAColor(red: record.data[p], green: record.data[p + 1], blue: record.data[p + 2]))
                }
            default: continue
            }
        }
        if result.fonts.isEmpty { result.fonts.append(Font()) }
        if result.xfs.isEmpty { result.xfs.append(XF()) }
        return result
    }

    func cellStyle(_ index: Int) -> CellStyle {
        if index == 0 { return .default }
        guard xfs.indices.contains(index) else { return .default }
        let xf = xfs[index]
        let fontIndex = xf.font > 4 ? xf.font - 1 : xf.font
        let font = fonts.indices.contains(fontIndex) ? fonts[fontIndex] : Font()
        var style = CellStyle()
        style.bold = font.bold; style.italic = font.italic
        style.underline = font.underline; style.strikethrough = font.strike
        style.fontName = font.name; style.fontSize = Double(font.height) / 20
        style.textColor = color(font.colorIndex)
        style.numberFormat = NumberFormat(code: formats[xf.format] ?? NumberFormat.builtin(xf.format)?.code ?? "")
        switch Int(xf.alignment & 0x07) {
        case 1: style.horizontalAlignment = .left
        case 2, 6: style.horizontalAlignment = .center
        case 3: style.horizontalAlignment = .right
        default: break
        }
        switch Int((xf.alignment >> 4) & 0x07) {
        case 0: style.verticalAlignment = .top
        case 1: style.verticalAlignment = .middle
        default: style.verticalAlignment = .bottom
        }
        style.wrapText = (xf.alignment & 0x08) != 0
        style.indent = Int(xf.textProperties & 0x0F)
        style.borders = CellBorders(
            top: borderLine(Int((xf.border1 >> 8) & 0x0F), color: Int(xf.border2 & 0x7F)),
            bottom: borderLine(Int((xf.border1 >> 12) & 0x0F), color: Int((xf.border2 >> 7) & 0x7F)),
            left: borderLine(Int(xf.border1 & 0x0F), color: Int((xf.border1 >> 16) & 0x7F)),
            right: borderLine(Int((xf.border1 >> 4) & 0x0F), color: Int((xf.border1 >> 23) & 0x7F)))
        let fillPattern = Int((xf.border2 >> 26) & 0x3F)
        let fillIndex = Int(xf.fill & 0x7F)
        if fillPattern == 1 { style.fillColor = color(fillIndex) }
        return style
    }

    private static func parseFont(_ data: Data) throws -> Font {
        guard data.count >= 16 else { throw XLSError.malformed("Invalid FONT record.") }
        var font = Font()
        font.height = Int(try data.readU16(0))
        let flags = try data.readU16(2)
        font.italic = flags & 0x0002 != 0; font.strike = flags & 0x0008 != 0
        font.colorIndex = Int(try data.readU16(4))
        font.bold = try data.readU16(6) >= 700
        font.underline = data[10] != 0
        if data.count > 14 {
            let count = Int(data[14]); let wide = data[15] & 1 != 0
            let byteCount = count * (wide ? 2 : 1)
            guard data.count >= 16 + byteCount else { throw XLSError.malformed("Truncated FONT name.") }
            let slice = data.subdata(in: 16..<(16 + byteCount))
            font.name = wide
                ? String(decoding: stride(from: 0, to: slice.count, by: 2).map { UInt16(slice[$0]) | UInt16(slice[$0 + 1]) << 8 }, as: UTF16.self)
                : BIFFString.decodeCompressed(Array(slice))
        }
        return font
    }

    private static func parseXF(_ data: Data) throws -> XF {
        guard data.count >= 20 else { throw XLSError.malformed("Invalid XF record.") }
        return XF(font: Int(try data.readU16(0)), format: Int(try data.readU16(2)),
                  alignment: data[6], rotation: data[7], textProperties: data[8],
                  border1: try data.readU32(10), border2: try data.readU32(14), fill: try data.readU16(18))
    }

    private func borderLine(_ code: Int, color: Int) -> BorderLine? {
        guard code > 0 else { return nil }
        let styles: [BorderLineStyle] = [.thin, .medium, .dashed, .dotted, .thick, .double, .hair, .mediumDashed, .dashDot, .mediumDashDot, .dashDotDot, .mediumDashDotDot, .slantDashDot]
        let style = styles.indices.contains(code - 1) ? styles[code - 1] : .thin
        let rgba = self.color(color)
        return BorderLine(style, color: rgba)
    }

    private func color(_ index: Int) -> RGBAColor? {
        if (0..<8).contains(index) { return Self.defaultPalette[index] }
        let paletteIndex = index - 8
        return palette.indices.contains(paletteIndex) ? palette[paletteIndex] : nil
    }

    private static let defaultPalette: [RGBAColor] = [
        "000000","FFFFFF","FF0000","00FF00","0000FF","FFFF00","FF00FF","00FFFF",
        "800000","008000","000080","808000","800080","008080","C0C0C0","808080",
        "9999FF","993366","FFFFCC","CCFFFF","660066","FF8080","0066CC","CCCCFF",
        "000080","FF00FF","FFFF00","00FFFF","800080","800000","008080","0000FF",
        "00CCFF","CCFFFF","CCFFCC","FFFF99","99CCFF","FF99CC","CC99FF","FFCC99",
        "3366FF","33CCCC","99CC00","FFCC00","FF9900","FF6600","666699","969696",
        "003366","339966","003300","333300","993300","993366","333399","333333"
    ].compactMap(RGBAColor.init(argbHex:))
}

extension Data {
    func readU16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, count - offset >= 2 else { throw XLSError.malformed("Truncated BIFF record.") }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func readU32(_ offset: Int) throws -> UInt32 {
        UInt32(try readU16(offset)) | UInt32(try readU16(offset + 2)) << 16
    }
}

struct BIFFString {
    let text: String
    let end: Int

    static func decodeCompressed(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map(UInt16.init), as: UTF16.self)
    }

    static func read(_ data: Data, at offset: Int, lengthBytes: Int = 2) throws -> BIFFString {
        guard offset >= 0, data.count - offset >= lengthBytes + 1 else { throw XLSError.malformed("Truncated BIFF string.") }
        let length = lengthBytes == 2 ? Int(try data.readU16(offset)) : Int(data[offset])
        let flagsAt = offset + lengthBytes
        let flags = data[flagsAt]
        var position = flagsAt + 1
        let wide = flags & 1 != 0
        let richRuns = flags & 0x08 != 0
        let extended = flags & 0x04 != 0
        var runCount = 0
        if richRuns { runCount = Int(try data.readU16(position)); position += 2 }
        var extensionBytes = 0
        if extended { extensionBytes = Int(try data.readU32(position)); position += 4 }
        let byteCount = length * (wide ? 2 : 1)
        guard byteCount >= 0, byteCount <= data.count - position else {
            throw XLSError.malformed("Truncated BIFF string text.")
        }
        guard runCount <= (data.count - position - byteCount) / 4,
              extensionBytes <= data.count - position - byteCount - runCount * 4 else {
            throw XLSError.malformed("Truncated BIFF string text or metadata.")
        }
        let chunk = data.subdata(in: position..<(position + byteCount))
        let text = wide
            ? String(decoding: stride(from: 0, to: chunk.count, by: 2).map { UInt16(chunk[$0]) | UInt16(chunk[$0 + 1]) << 8 }, as: UTF16.self)
            : String(decoding: chunk.map(UInt16.init), as: UTF16.self)
        position += byteCount + runCount * 4
        guard position <= data.count else { throw XLSError.malformed("Truncated BIFF rich text runs.") }
        return BIFFString(text: text, end: position)
    }
}

/// When SST character data spans CONTINUE records, the first byte of each
/// continuation is its compression flag, not part of the string.
struct BIFFSSTCursor {
    private let segments: [Data]
    private var segment = 0
    private var offset = 0
    private(set) var hasRichText = false

    init(_ segments: [Data]) { self.segments = segments }

    mutating func readByte() throws -> UInt8 {
        try skipEmptySegments()
        guard segment < segments.count else { throw XLSError.malformed("Truncated shared string table.") }
        let byte = segments[segment][offset]
        offset += 1
        return byte
    }

    mutating func readU16() throws -> UInt16 {
        UInt16(try readByte()) | UInt16(try readByte()) << 8
    }

    mutating func readU32() throws -> UInt32 {
        UInt32(try readU16()) | UInt32(try readU16()) << 16
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0 else { throw XLSError.malformed("Invalid shared string metadata length.") }
        for _ in 0..<count { _ = try readByte() }
    }

    mutating func readString() throws -> String {
        let characterCount = Int(try readU16())
        let flags = try readByte()
        hasRichText = hasRichText || flags & 0x0C != 0
        var wide = flags & 1 != 0
        let runs = flags & 0x08 != 0 ? Int(try readU16()) : 0
        let extensionBytes = flags & 0x04 != 0 ? Int(try readU32()) : 0
        guard characterCount <= 1_048_576, runs <= 16_384, extensionBytes <= 16_777_216 else {
            throw XLSError.invalidFile("A shared string exceeds the supported size limit.")
        }
        var units: [UInt16] = []; units.reserveCapacity(characterCount)
        for _ in 0..<characterCount {
            if isAtSegmentEnd {
                segment += 1; offset = 0
                guard segment < segments.count, !segments[segment].isEmpty else { throw XLSError.malformed("Invalid SST CONTINUE record.") }
                wide = try readByte() & 1 != 0
            }
            if wide {
                let low = UInt16(try readByte())
                guard !isAtSegmentEnd else { throw XLSError.malformed("A Unicode code unit is split across SST records.") }
                units.append(low | UInt16(try readByte()) << 8)
            } else { units.append(UInt16(try readByte())) }
        }
        try skip(extensionBytes + runs * 4)
        return String(decoding: units, as: UTF16.self)
    }

    private var isAtSegmentEnd: Bool { segment < segments.count && offset == segments[segment].count }

    private mutating func skipEmptySegments() throws {
        while segment < segments.count && offset == segments[segment].count {
            segment += 1; offset = 0
        }
    }
}
