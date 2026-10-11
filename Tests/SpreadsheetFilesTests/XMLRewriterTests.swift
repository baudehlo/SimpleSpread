import Foundation
import Testing
@testable import SpreadsheetFiles

@Suite("XML rewriter")
struct XMLRewriterTests {
    private func identity(_ xml: String) throws -> String {
        let out = try XMLRewriter.rewrite(Data(xml.utf8)) { _ in .keep }
        return String(decoding: out, as: UTF8.self)
    }

    private let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    @Test func identityPreservesStructureNamespacesAndPrefixes() throws {
        let xml = header + """
        <pivotTableDefinition xmlns="urn:main" xmlns:mc="urn:mc" mc:Ignorable="xr" xmlns:xr="urn:xr" name="P1" xr:uid="{A}">\
        <location ref="A3:B7" firstHeaderRow="1"/>\
        <extLst><ext uri="{X}" xmlns:x14="urn:x14"><x14:pivotTableDefinition hideValuesRow="1"/></ext></extLst>\
        </pivotTableDefinition>
        """
        let out = try identity(xml)
        #expect(out == header + """
        <pivotTableDefinition xmlns="urn:main" xmlns:mc="urn:mc" xmlns:xr="urn:xr" mc:Ignorable="xr" name="P1" xr:uid="{A}">\
        <location firstHeaderRow="1" ref="A3:B7"/>\
        <extLst><ext xmlns:x14="urn:x14" uri="{X}"><x14:pivotTableDefinition hideValuesRow="1"/></ext></extLst>\
        </pivotTableDefinition>
        """)
    }

    @Test func outputIsAFixedPoint() throws {
        let xml = header + "<a xmlns=\"urn:a\" z=\"1\" b=\"2\"><b>text &amp; more</b><c/></a>"
        let once = try identity(xml)
        #expect(try identity(once) == once)
    }

    @Test func attributeValuesRoundTripLosslessly() throws {
        // Character references for whitespace must survive: literal TAB/LF/CR
        // inside an attribute would be normalized to spaces on re-read.
        let xml = header + "<a v=\"x&#10;y&#9;z&#13;w &amp; &lt;q&gt; &quot;\"/>"
        let out = try identity(xml)
        #expect(out == header + "<a v=\"x&#10;y&#9;z&#13;w &amp; &lt;q&gt; &quot;\"/>")
        var seen: String?
        try XMLRewriter.scan(Data(out.utf8)) { element in
            seen = element.attributes["v"]
            return .keep
        }
        #expect(seen == "x\ny\tz\rw & <q> \"")
    }

    @Test func textIsReEscapedAndCDATAFlattened() throws {
        let xml = header + "<a><t>1 &lt; 2 &#x1F389; _x0007_</t><u><![CDATA[<b>&]]></u></a>"
        let out = try identity(xml)
        // _xHHHH_ escapes are OOXML-level and pass through untouched.
        #expect(out == header + "<a><t>1 &lt; 2 🎉 _x0007_</t><u>&lt;b&gt;&amp;</u></a>")
    }

    @Test func commentsAreDropped() throws {
        let out = try identity(header + "<a><!-- note --><b/></a>")
        #expect(out == header + "<a><b/></a>")
    }

    @Test func emptyElementsStayCompactAndNonEmptyStayExpanded() throws {
        let out = try identity(header + "<a><b></b><c>x</c><d><e/></d></a>")
        #expect(out == header + "<a><b/><c>x</c><d><e/></d></a>")
    }

    @Test func visitorSeesLocalNamePathsAndCanRewriteAttributes() throws {
        let xml = header + "<x:root xmlns:x=\"urn:x\"><x:fields><x:field numFmtId=\"164\"/><x:field/></x:fields></x:root>"
        var paths: [[String]] = []
        let out = try XMLRewriter.rewrite(Data(xml.utf8)) { element in
            paths.append(element.path)
            if element.path == ["root", "fields", "field"], element.attributes["numFmtId"] == "164" {
                element.attributes["numFmtId"] = "170"
            }
            return .keep
        }
        #expect(paths == [["root"], ["root", "fields"], ["root", "fields", "field"], ["root", "fields", "field"]])
        #expect(String(decoding: out, as: UTF8.self)
            == header + "<x:root xmlns:x=\"urn:x\"><x:fields><x:field numFmtId=\"170\"/><x:field/></x:fields></x:root>")
    }

    @Test func dropRemovesWholeSubtreeIncludingSameNamedDescendants() throws {
        let xml = header + "<a><drop><drop><k/></drop>text</drop><keep/><drop/></a>"
        var visited: [String] = []
        let out = try XMLRewriter.rewrite(Data(xml.utf8)) { element in
            visited.append(element.path.joined(separator: "/"))
            return element.localName == "drop" ? .drop : .keep
        }
        #expect(String(decoding: out, as: UTF8.self) == header + "<a><keep/></a>")
        // Nothing inside a dropped subtree is visited.
        #expect(visited == ["a", "a/drop", "a/keep", "a/drop"])
    }

    @Test func malformedInputThrows() {
        #expect(throws: XLSXError.self) {
            _ = try XMLRewriter.rewrite(Data("<a><b></a>".utf8)) { _ in .keep }
        }
    }

    @Test func largePartRewritesInReasonableTime() throws {
        // A cache definition can carry tens of thousands of shared items.
        var xml = header + "<sharedItems count=\"60000\">"
        for i in 0..<60_000 { xml += "<s v=\"Item \(i) &amp; co\"/>" }
        xml += "</sharedItems>"
        let start = Date()
        let out = try XMLRewriter.rewrite(Data(xml.utf8)) { _ in .keep }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(String(decoding: out, as: UTF8.self) == xml)
    }

    @Test func namespaceResolutionFollowsScopeNotPrefixSpelling() throws {
        // A producer may bind the relationships namespace to any prefix, and
        // may declare it on the element itself.
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let xml = header + """
        <d xmlns="urn:main" xmlns:rel="\(rel)" rel:id="rIdA"><s xmlns:r="urn:not-rel" r:id="x"/>\
        <t xmlns:q="\(rel)" q:id="rIdB"/></d>
        """
        var found: [String: String] = [:]
        try XMLRewriter.scan(Data(xml.utf8)) { element in
            if let name = element.attributeName(local: "id", namespace: rel) {
                found[element.localName] = element.attributes[name]
            }
            #expect(element.namespaceURI == "urn:main")
            return .keep
        }
        #expect(found == ["d": "rIdA", "t": "rIdB"])
    }

    @Test func prefixForNamespaceFindsInnermostBinding() throws {
        let xml = header + "<a xmlns:p=\"urn:x\"><b xmlns:p=\"urn:y\" xmlns:z=\"urn:x\"><c/></b></a>"
        var prefixes: [String: String?] = [:]
        try XMLRewriter.scan(Data(xml.utf8)) { element in
            prefixes[element.localName] = element.prefix(forNamespace: "urn:x")
            return .keep
        }
        #expect(prefixes["a"] == "p")
        #expect(prefixes["c"] == "z") // p was rebound to urn:y inside b
    }

    @Test func fragmentsCarryInScopeNamespaces() throws {
        let xml = header + """
        <styleSheet xmlns="urn:main" xmlns:x14="urn:x14"><dxfs count="2">\
        <dxf><font><b/></font></dxf><dxf><fill><patternFill><bgColor rgb="FFFF0000"/></patternFill></fill>\
        <extLst><ext><x14:thing/></ext></extLst></dxf></dxfs><tableStyles count="0"/></styleSheet>
        """
        let dxfs = try XMLRewriter.fragments(of: Data(xml.utf8)) { $0.path == ["styleSheet", "dxfs", "dxf"] }
        #expect(dxfs == [
            "<dxf xmlns=\"urn:main\" xmlns:x14=\"urn:x14\"><font><b/></font></dxf>",
            "<dxf xmlns=\"urn:main\" xmlns:x14=\"urn:x14\"><fill><patternFill><bgColor rgb=\"FFFF0000\"/></patternFill></fill>"
                + "<extLst><ext><x14:thing/></ext></extLst></dxf>",
        ])
        let styles = try XMLRewriter.fragments(of: Data(xml.utf8)) { $0.localName == "tableStyles" }
        #expect(styles == ["<tableStyles xmlns=\"urn:main\" xmlns:x14=\"urn:x14\" count=\"0\"/>"])
    }

    @Test func nestedMatchesBelongToTheOuterFragment() throws {
        let xml = header + "<a><m><m/></m><m/></a>"
        let found = try XMLRewriter.fragments(of: Data(xml.utf8)) { $0.localName == "m" }
        #expect(found == ["<m><m/></m>", "<m/>"])
    }

    @Test func fragmentOverridesKeepTheirOwnBinding() throws {
        let xml = header + "<a xmlns:p=\"urn:outer\"><f xmlns:p=\"urn:inner\"/></a>"
        let found = try XMLRewriter.fragments(of: Data(xml.utf8)) { $0.localName == "f" }
        #expect(found == ["<f xmlns:p=\"urn:inner\"/>"])
    }
}
