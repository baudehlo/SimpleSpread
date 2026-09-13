import Foundation

/// XML string-building helpers shared by the XLSX writer/reader.
enum XML {
    /// Escape text content: & < > (and CR stripped — LF round-trips fine).
    static func escapeText(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\r", with: "")
        return out
    }

    /// Escape attribute values (adds quote escaping).
    static func escapeAttribute(_ s: String) -> String {
        escapeText(s)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// OOXML _xHHHH_ encoding for characters illegal in XML 1.0
    /// (< 0x20 except TAB/LF/CR). Also escapes literal "_xHHHH_" sequences.
    static func encodeIllegalCharacters(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c.value < 0x20 && c != "\t" && c != "\n" && c != "\r" {
                out += String(format: "_x%04X_", c.value)
            } else if c == "_", matchesXEscape(scalars, at: i) {
                out += "_x005F_"
            } else {
                out.unicodeScalars.append(c)
            }
            i += 1
        }
        return out
    }

    /// Decode _xHHHH_ sequences produced by Excel.
    static func decodeIllegalCharacters(_ s: String) -> String {
        guard s.contains("_x") else { return s }
        var out = ""
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if matchesXEscape(scalars, at: i),
               let value = UInt32(String(String.UnicodeScalarView(scalars[(i + 2)...(i + 5)])), radix: 16),
               let scalar = Unicode.Scalar(value) {
                out.unicodeScalars.append(scalar)
                i += 7
            } else {
                out.unicodeScalars.append(scalars[i])
                i += 1
            }
        }
        return out
    }

    /// True when scalars[at...] begins "_xHHHH_" with hex digits.
    private static func matchesXEscape(_ scalars: [Unicode.Scalar], at i: Int) -> Bool {
        guard i + 6 < scalars.count, scalars[i] == "_",
              scalars[i + 1] == "x" || scalars[i + 1] == "X",
              scalars[i + 6] == "_" else { return false }
        for j in (i + 2)...(i + 5) {
            let v = scalars[j].value
            let isHex = (v >= 48 && v <= 57) || (v >= 65 && v <= 70) || (v >= 97 && v <= 102)
            if !isHex { return false }
        }
        return true
    }
}
