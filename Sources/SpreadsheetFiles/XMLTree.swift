import Foundation

/// A small XML tree for parts SimpleSpread carries through a save and
/// adjusts on the way (charts, comments, conditional formatting, …), where
/// an edit needs to see an element's children before deciding what to do
/// with it.
///
/// Like XMLRewriter, it keeps what matters to a reader: element and
/// attribute names with their prefixes, namespace declarations where they
/// were made, text and its whitespace. Lost on the way through: attribute
/// order (written xmlns first, then sorted), comments, processing
/// instructions, CDATA sections (written as escaped text) and the spelling
/// of character references.
final class XMLNode {
    /// The qualified name as written ("xdr:twoCellAnchor").
    var name: String
    var attributes: [String: String]
    var children: [Child]

    enum Child {
        case element(XMLNode)
        case text(String)
    }

    init(name: String, attributes: [String: String] = [:], children: [Child] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    var localName: String { XMLRewriter.localName(name) }

    var elements: [XMLNode] {
        children.compactMap { if case .element(let e) = $0 { return e } else { return nil } }
    }

    /// The element's text (its text children joined).
    var text: String {
        get { children.map { if case .text(let t) = $0 { return t } else { return "" } }.joined() }
        set { children = [.text(newValue)] }
    }

    func firstChild(_ local: String) -> XMLNode? {
        elements.first { $0.localName == local }
    }

    /// Remove the element children for which `shouldRemove` is true.
    func removeElements(where shouldRemove: (XMLNode) -> Bool) {
        children.removeAll { if case .element(let e) = $0 { return shouldRemove(e) } else { return false } }
    }

    /// Visit this element and every element below it, parents first.
    func forEach(_ body: (XMLNode) -> Void) {
        body(self)
        for case .element(let child) in children { child.forEach(body) }
    }

    /// Visit every element below this one bottom-up; `body` returns false
    /// to remove the element it was given.
    func prune(_ body: (XMLNode) -> Bool) {
        children.removeAll { child in
            guard case .element(let e) = child else { return false }
            e.prune(body)
            return !body(e)
        }
    }

    // MARK: Parsing and writing

    /// The document element of `data`.
    static func parse(_ data: Data) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            let detail = parser.parserError.map { " (\($0.localizedDescription))" } ?? ""
            throw XLSXError.invalidXML("XML parse failure\(detail)")
        }
        return root
    }

    static func parse(_ fragment: String) throws -> XMLNode {
        try parse(Data(fragment.utf8))
    }

    /// The element and everything below it.
    var xml: String {
        var out = ""
        write(to: &out)
        return out
    }

    /// A standalone part: the XML declaration, then the element.
    var document: Data {
        Data((XLSXWriter.xmlHeader + xml).utf8)
    }

    private func write(to out: inout String) {
        out += "<" + name
        for (key, value) in XMLRewriter.orderedAttributes(attributes) {
            out += " \(key)=\"\(XMLRewriter.escapeAttribute(value))\""
        }
        guard !children.isEmpty else {
            out += "/>"
            return
        }
        out += ">"
        for child in children {
            switch child {
            case .element(let e): e.write(to: &out)
            case .text(let t): out += XMLRewriter.escapeText(t)
            }
        }
        out += "</" + name + ">"
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []
        var pendingText = ""

        func flushText() {
            guard !pendingText.isEmpty else { return }
            stack.last?.children.append(.text(pendingText))
            pendingText = ""
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attributeDict: [String: String]) {
            flushText()
            let node = XMLNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(.element(node)) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            flushText()
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // Whitespace outside the document element isn't kept.
            if !stack.isEmpty { pendingText += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if !stack.isEmpty { pendingText += String(decoding: CDATABlock, as: UTF8.self) }
        }
    }
}
