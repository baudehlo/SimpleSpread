import Foundation

enum TextFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = joining + searching + casing + conversion

    private static let joining: [BuiltinFunction] = [
        .eager("CONCATENATE", min: 1, max: nil) { args, _ in
            .string(try joinAll(args, separator: ""))
        },
        .eager("CONCAT", min: 1, max: nil) { args, _ in
            .string(try joinAll(args, separator: ""))
        },
        .eager("TEXTJOIN", min: 3, max: nil) { args, _ in
            let delimiter = try strArg(args[0])
            let ignoreEmpty = try boolArg(args[1])
            var parts: [String] = []
            for arg in args.dropFirst(2) {
                try GridArg(arg).forEach { v in
                    if case .error(let e) = v { throw e }
                    let s = Coerce.displayText(v)
                    if ignoreEmpty && s.isEmpty { return }
                    parts.append(s)
                }
            }
            return .string(parts.joined(separator: delimiter))
        },
        .eager("LEFT", min: 1, max: 2) { args, _ in
            let s = try strArg(args[0])
            let n = try optionalInt(args, 1, default: 1)
            guard n >= 0 else { throw CellError.value }
            return .string(String(s.prefix(n)))
        },
        .eager("RIGHT", min: 1, max: 2) { args, _ in
            let s = try strArg(args[0])
            let n = try optionalInt(args, 1, default: 1)
            guard n >= 0 else { throw CellError.value }
            return .string(String(s.suffix(n)))
        },
        .eager("MID", min: 3, max: 3) { args, _ in
            let s = try strArg(args[0])
            let start = try intArg(args[1])
            let length = try intArg(args[2])
            guard start >= 1, length >= 0 else { throw CellError.value }
            let chars = Array(s)
            guard start <= chars.count else { return .string("") }
            let from = start - 1
            let to = min(chars.count, from + length)
            return .string(String(chars[from..<to]))
        },
        .eager("LEN", min: 1, max: 1) { args, _ in
            .number(Double(try strArg(args[0]).count))
        },
    ]

    private static let searching: [BuiltinFunction] = [
        .eager("FIND", min: 2, max: 3) { args, _ in
            let needle = try strArg(args[0])
            let haystack = try strArg(args[1])
            let start = try optionalInt(args, 2, default: 1)
            guard start >= 1 else { throw CellError.value }
            let chars = Array(haystack)
            guard start <= chars.count + 1 else { throw CellError.value }
            if needle.isEmpty { return .number(Double(start)) }
            let sub = String(chars[(start - 1)...])
            guard let range = sub.range(of: needle) else { throw CellError.value }
            let offset = sub.distance(from: sub.startIndex, to: range.lowerBound)
            return .number(Double(start + offset))
        },
        .eager("SEARCH", min: 2, max: 3) { args, _ in
            let pattern = try strArg(args[0])
            let haystack = try strArg(args[1])
            let start = try optionalInt(args, 2, default: 1)
            guard start >= 1 else { throw CellError.value }
            let chars = Array(haystack)
            guard start <= chars.count + 1 else { throw CellError.value }
            if pattern.isEmpty { return .number(Double(start)) }
            // Wildcard-aware, case-insensitive: find the first position where
            // the pattern matches a prefix of the remaining text.
            for pos in (start - 1)...chars.count {
                let rest = String(chars[pos...])
                if Criterion.wildcardMatch(pattern: pattern + "*", text: rest) {
                    return .number(Double(pos + 1))
                }
            }
            throw CellError.value
        },
        .eager("SUBSTITUTE", min: 3, max: 4) { args, _ in
            let text = try strArg(args[0])
            let search = try strArg(args[1])
            let replacement = try strArg(args[2])
            guard !search.isEmpty else { return .string(text) }
            if args.count > 3 {
                let occurrence = try intArg(args[3])
                guard occurrence >= 1 else { throw CellError.value }
                var result = text
                var searchStart = result.startIndex
                var count = 0
                while let r = result.range(of: search, range: searchStart..<result.endIndex) {
                    count += 1
                    if count == occurrence {
                        result.replaceSubrange(r, with: replacement)
                        return .string(result)
                    }
                    searchStart = r.upperBound
                }
                return .string(text)
            }
            return .string(text.replacingOccurrences(of: search, with: replacement))
        },
        .eager("REPLACE", min: 4, max: 4) { args, _ in
            let text = try strArg(args[0])
            let position = try intArg(args[1])
            let length = try intArg(args[2])
            let newText = try strArg(args[3])
            guard position >= 1, length >= 0 else { throw CellError.value }
            let chars = Array(text)
            let from = min(position - 1, chars.count)
            let to = min(from + length, chars.count)
            return .string(String(chars[0..<from]) + newText + String(chars[to...]))
        },
    ]

    private static let casing: [BuiltinFunction] = [
        .eager("UPPER", min: 1, max: 1) { args, _ in
            .string(try strArg(args[0]).uppercased())
        },
        .eager("LOWER", min: 1, max: 1) { args, _ in
            .string(try strArg(args[0]).lowercased())
        },
        .eager("PROPER", min: 1, max: 1) { args, _ in
            let s = try strArg(args[0])
            var result = ""
            var prevIsLetter = false
            for ch in s {
                if ch.isLetter {
                    result.append(prevIsLetter ? Character(ch.lowercased()) : Character(ch.uppercased()))
                    prevIsLetter = true
                } else {
                    result.append(ch)
                    prevIsLetter = false
                }
            }
            return .string(result)
        },
        .eager("TRIM", min: 1, max: 1) { args, _ in
            // Excel TRIM: strip leading/trailing spaces AND collapse runs.
            let s = try strArg(args[0])
            let collapsed = s.split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
            return .string(collapsed)
        },
        .eager("CLEAN", min: 1, max: 1) { args, _ in
            let s = try strArg(args[0])
            return .string(String(s.unicodeScalars.filter { $0.value >= 32 }.map(Character.init)))
        },
        .eager("REPT", min: 2, max: 2) { args, _ in
            let s = try strArg(args[0])
            let n = try intArg(args[1])
            guard n >= 0 else { throw CellError.value }
            guard s.count * n <= 32767 else { throw CellError.value }
            return .string(String(repeating: s, count: n))
        },
        .eager("EXACT", min: 2, max: 2) { args, _ in
            .bool(try strArg(args[0]) == (try strArg(args[1])))
        },
    ]

    private static let conversion: [BuiltinFunction] = [
        .eager("TEXT", min: 2, max: 2) { args, _ in
            let v = try args[0].toScalar()
            if case .error(let e) = v { throw e }
            let format = try strArg(args[1])
            if case .string(let s) = v {
                // Non-numeric text passes through (unless coercible).
                if let n = Coerce.parseNumericText(s) {
                    return .string(NumberFormatEngine.formatNumber(n, code: format))
                }
                return .string(s)
            }
            let n = try Coerce.number(v)
            return .string(NumberFormatEngine.formatNumber(n, code: format))
        },
        .eager("VALUE", min: 1, max: 1) { args, _ in
            let v = try args[0].toScalar()
            if case .number(let n) = v { return .number(n) }
            if case .error(let e) = v { throw e }
            let s = try Coerce.string(v)
            guard let parsed = ValueParser.parseSerialNumber(from: s) else { throw CellError.value }
            return .number(parsed)
        },
        .eager("T", min: 1, max: 1) { args, _ in
            let v = try args[0].toScalar()
            if case .string(let s) = v { return .string(s) }
            if case .error(let e) = v { throw e }
            return .string("")
        },
        .eager("CHAR", min: 1, max: 1) { args, _ in
            let n = try intArg(args[0])
            guard n >= 1, n <= 0x10FFFF, let scalar = Unicode.Scalar(n) else { throw CellError.value }
            return .string(String(Character(scalar)))
        },
        .eager("CODE", min: 1, max: 1) { args, _ in
            let s = try strArg(args[0])
            guard let first = s.unicodeScalars.first else { throw CellError.value }
            return .number(Double(first.value))
        },
        .eager("REGEXMATCH", min: 2, max: 2) { args, _ in
            let text = try strArg(args[0])
            let pattern = try strArg(args[1])
            let regex = try compileRegex(pattern)
            let range = NSRange(text.startIndex..., in: text)
            return .bool(regex.firstMatch(in: text, range: range) != nil)
        },
        .eager("REGEXEXTRACT", min: 2, max: 2) { args, _ in
            let text = try strArg(args[0])
            let pattern = try strArg(args[1])
            let regex = try compileRegex(pattern)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { throw CellError.na }
            // With capture groups, return the first group; else the whole match.
            let groupIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let r = Range(match.range(at: groupIndex), in: text) else { throw CellError.na }
            return .string(String(text[r]))
        },
        .eager("REGEXREPLACE", min: 3, max: 3) { args, _ in
            let text = try strArg(args[0])
            let pattern = try strArg(args[1])
            let replacement = try strArg(args[2])
            let regex = try compileRegex(pattern)
            let range = NSRange(text.startIndex..., in: text)
            let result = regex.stringByReplacingMatches(in: text, range: range,
                                                        withTemplate: replacement)
            return .string(result)
        },
    ]

    private static func joinAll(_ args: [EvalValue], separator: String) throws -> String {
        var parts: [String] = []
        for arg in args {
            try GridArg(arg).forEach { v in
                if case .error(let e) = v { throw e }
                parts.append(Coerce.displayText(v))
            }
        }
        return parts.joined(separator: separator)
    }

    private static func compileRegex(_ pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            throw CellError.value
        }
    }
}
