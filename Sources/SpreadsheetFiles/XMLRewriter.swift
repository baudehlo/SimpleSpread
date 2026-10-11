import Foundation

/// Streams an XML part back out, letting the caller inspect or rewrite each
/// element's attributes and drop whole elements on the way through.
///
/// Used for parts SimpleSpread carries through a save without modelling them
/// (pivot tables): everything the caller doesn't touch survives — element and
/// attribute names keep their prefixes, namespace declarations stay where they
/// were declared, and text is re-escaped from its decoded form. What is NOT
/// preserved is purely lexical: attribute order (XMLParser hands attributes
/// over as a dictionary, so they are written xmlns-first, then sorted),
/// comments, processing instructions, CDATA sections (written as escaped
/// text), and the spelling of character references.
enum XMLRewriter {
    enum Action {
        /// Emit the element (with any attribute changes) and descend into it.
        case keep
        /// Omit the element and its whole subtree.
        case drop
    }

    /// The element being visited.
    struct Element {
        /// Local names (prefix stripped) from the root down to this element.
        let path: [String]
        /// The qualified name as written ("x14:pivotTableDefinition").
        let qualifiedName: String
        /// Attributes as written, namespace declarations included. Changes
        /// are written out (rewrite) — namespace declarations should be left
        /// alone, since scope resolution has already used them.
        var attributes: [String: String]
        fileprivate let scopes: [[String: String]]

        var localName: String { path.last ?? "" }

        /// The namespace URI bound to `prefix` ("" = default namespace) here.
        func namespaceURI(forPrefix prefix: String) -> String? {
            let key = prefix.isEmpty ? "xmlns" : "xmlns:\(prefix)"
            if let uri = attributes[key] { return uri }
            for scope in scopes.reversed() {
                if let uri = scope[key] { return uri }
            }
            return nil
        }

        /// The element's own namespace URI.
        var namespaceURI: String? {
            namespaceURI(forPrefix: XMLRewriter.prefix(of: qualifiedName))
        }

        /// The written name of the attribute `local` in namespace `uri`
        /// (whatever prefix the producer chose), if present.
        func attributeName(local: String, namespace uri: String) -> String? {
            for key in attributes.keys where key.hasSuffix(":" + local) {
                let prefix = XMLRewriter.prefix(of: key)
                if prefix != "xmlns", namespaceURI(forPrefix: prefix) == uri { return key }
            }
            return nil
        }

        /// A prefix bound to `uri` in scope here, if any.
        func prefix(forNamespace uri: String) -> String? {
            var bound: [String: String] = [:] // prefix -> uri, innermost wins
            for scope in scopes + [attributes] {
                for (key, value) in scope where key.hasPrefix("xmlns:") {
                    bound[String(key.dropFirst(6))] = value
                }
            }
            return bound.filter { $0.value == uri }.keys.sorted().first
        }
    }

    typealias Visitor = (inout Element) -> Action

    /// Rewrite `data`, returning the re-serialized part.
    static func rewrite(_ data: Data, _ visit: Visitor) throws -> Data {
        try withoutActuallyEscaping(visit) { visit in
            let delegate = Delegate(mode: .document, visit: visit)
            try run(data, delegate)
            return Data(delegate.output.utf8)
        }
    }

    /// Visit every element without producing output. Returning `.drop` from
    /// the visitor skips that element's subtree.
    static func scan(_ data: Data, _ visit: Visitor) throws {
        try withoutActuallyEscaping(visit) { visit in
            try run(data, Delegate(mode: .none, visit: visit))
        }
    }

    /// Serialize each element for which `matches` is true (and its subtree)
    /// as a standalone fragment. Namespace declarations in scope from its
    /// ancestors are copied onto the fragment root, so prefixes stay bound
    /// wherever the fragment is spliced. Matching elements nested inside an
    /// earlier match are part of that fragment, not separate ones.
    static func fragments(of data: Data, where matches: @escaping (Element) -> Bool) throws -> [String] {
        let delegate = Delegate(mode: .fragments(matches), visit: { _ in .keep })
        try run(data, delegate)
        return delegate.fragments
    }

    private static func run(_ data: Data, _ delegate: Delegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let detail = parser.parserError.map { " (\($0.localizedDescription))" } ?? ""
            throw XLSXError.invalidXML("XML parse failure\(detail)")
        }
    }

    static func localName(_ qualified: String) -> String {
        guard let idx = qualified.lastIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: idx)...])
    }

    static func prefix(of qualified: String) -> String {
        guard let idx = qualified.lastIndex(of: ":") else { return "" }
        return String(qualified[..<idx])
    }

    // MARK: Escaping (lossless for decoded text, unlike XML.escapeText)

    static func escapeText(_ s: String) -> String {
        guard s.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\r" }) else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\r": out += "&#13;" // a literal CR would be normalized away on re-read
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func escapeAttribute(_ s: String) -> String {
        guard s.contains(where: { "&<>\"\t\n\r".contains($0) }) else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // Attribute-value normalization turns literal whitespace into
            // spaces, so these must be written as character references.
            case "\t": out += "&#9;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// xmlns first (default, then prefixed), then the rest, each sorted.
    static func orderedAttributes(_ attributes: [String: String]) -> [(String, String)] {
        func rank(_ key: String) -> Int {
            if key == "xmlns" { return 0 }
            if key.hasPrefix("xmlns:") { return 1 }
            return 2
        }
        return attributes.sorted { a, b in
            let ra = rank(a.key), rb = rank(b.key)
            return ra != rb ? ra < rb : a.key < b.key
        }
    }

    // MARK: Parser delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        enum Mode {
            case none
            case document
            case fragments((Element) -> Bool)
        }

        let mode: Mode
        let visit: Visitor
        var output = ""
        var fragments: [String] = []
        var path: [String] = []
        /// Namespace declarations made by each open element.
        var scopes: [[String: String]] = []
        /// Depth (in path terms) of the element being skipped, if any.
        var dropDepth: Int?
        /// Depth of the fragment being captured, if any.
        var fragmentDepth: Int?
        /// True while the most recent start tag is still open ("<a b='c'").
        var startTagOpen = false

        init(mode: Mode, visit: @escaping Visitor) {
            self.mode = mode
            self.visit = visit
            if case .document = mode {
                output = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            }
        }

        var emitting: Bool {
            switch mode {
            case .none: return false
            case .document: return dropDepth == nil
            case .fragments: return fragmentDepth != nil
            }
        }

        private func closeStartTag() {
            if startTagOpen {
                output += ">"
                startTagOpen = false
            }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attributeDict: [String: String]) {
            path.append(XMLRewriter.localName(elementName))
            defer { scopes.append(attributeDict.filter { $0.key == "xmlns" || $0.key.hasPrefix("xmlns:") }) }
            guard dropDepth == nil else { return }
            var element = Element(path: path, qualifiedName: elementName,
                                  attributes: attributeDict, scopes: scopes)

            if case .fragments(let matches) = mode, fragmentDepth == nil, matches(element) {
                fragmentDepth = path.count
                output = ""
                // Bind every in-scope prefix so the fragment stands alone.
                element.attributes = Self.resolvedNamespaces(scopes: scopes, own: attributeDict)
            } else if visit(&element) == .drop {
                dropDepth = path.count
                return
            }

            guard emitting else { return }
            closeStartTag()
            output += "<" + elementName
            for (key, value) in XMLRewriter.orderedAttributes(element.attributes) {
                output += " \(key)=\"\(XMLRewriter.escapeAttribute(value))\""
            }
            startTagOpen = true
        }

        /// The element's own attributes plus each namespace binding in scope
        /// from ancestors that it doesn't override (innermost binding wins).
        static func resolvedNamespaces(scopes: [[String: String]], own: [String: String]) -> [String: String] {
            var result = own
            var inherited: [String: String] = [:]
            for scope in scopes {
                for (key, value) in scope { inherited[key] = value }
            }
            for (key, value) in inherited where result[key] == nil {
                result[key] = value
            }
            return result
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            defer {
                path.removeLast()
                scopes.removeLast()
            }
            if let depth = dropDepth {
                if depth == path.count { dropDepth = nil }
                return
            }
            guard emitting else { return }
            if startTagOpen {
                output += "/>"
                startTagOpen = false
            } else {
                output += "</\(elementName)>"
            }
            if let depth = fragmentDepth, depth == path.count {
                fragments.append(output)
                output = ""
                fragmentDepth = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard emitting, dropDepth == nil, !path.isEmpty else { return }
            closeStartTag()
            output += XMLRewriter.escapeText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard emitting, dropDepth == nil, !path.isEmpty else { return }
            closeStartTag()
            output += XMLRewriter.escapeText(String(decoding: CDATABlock, as: UTF8.self))
        }
    }
}
