import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

extension Package {
    /// What's wrong with the package as an OPC/OOXML container: a part
    /// without a content type, a relationship to a part that isn't there,
    /// an `r:` attribute naming no relationship, XML that doesn't parse.
    func integrityProblems() throws -> [String] {
        var problems: [String] = []
        let typesData = try part("[Content_Types].xml")
        let types = try ContentTypes.parse(typesData)
        let names = Set(partNames)
        for name in partNames where !name.hasSuffix("/") && name != "[Content_Types].xml" {
            guard let type = types.contentType(ofPart: name) else {
                problems.append("\(name): no content type")
                continue
            }
            let isXML = type.hasSuffix("xml") || name.hasSuffix(".rels") || name.hasSuffix(".vml")
            guard isXML, !name.hasSuffix(".rels") else { continue }
            let rels = (try? relationships(of: name)) ?? []
            for rel in rels where !rel.isExternal && !names.contains(rel.target) {
                problems.append("\(name): relationship \(rel.id) to missing \(rel.target)")
            }
            let ids = Set(rels.map(\.id))
            do {
                try XMLRewriter.scan(part(name)) { element in
                    for key in element.attributes.keys where key.contains(":") && !key.hasPrefix("xmlns") {
                        let prefix = XMLRewriter.prefix(of: key)
                        guard OOXMLNamespace.allRelationships.contains(element.namespaceURI(forPrefix: prefix) ?? ""),
                              let value = element.attributes[key], !value.isEmpty else { continue }
                        if !ids.contains(value) { problems.append("\(name): \(key)=\"\(value)\" names no relationship") }
                    }
                    return .keep
                }
            } catch {
                // VML from some producers isn't well-formed XML; Excel reads it anyway.
                if !name.hasSuffix(".vml") { problems.append("\(name): \(error)") }
            }
        }
        for name in partNames where name.hasSuffix(".rels") {
            if (try? XLSXReader.parseRelationships(part(name), baseDir: "")) == nil {
                problems.append("\(name): unreadable")
            }
        }
        return problems
    }

    func names(under prefix: String) -> [String] {
        partNames.filter { $0.hasPrefix(prefix) && !$0.contains("/_rels/") && !$0.hasSuffix("/") }.sorted()
    }
}

@Suite("Carried parts: fixtures")
struct CarriedPartsFixtureTests {
    static var fixtures: [URL] {
        let base = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let all = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return all.filter { $0.pathExtension == "xlsx" }.sorted { $0.path < $1.path }
    }

    @Test func everyFixtureSavesAsAWellFormedPackage() throws {
        #expect(!Self.fixtures.isEmpty)
        for url in Self.fixtures {
            let workbook = try XLSXReader.read(data: Data(contentsOf: url))
            let written = try Package(XLSXWriter.data(for: workbook))
            let problems = try written.integrityProblems()
            #expect(problems.isEmpty, "\(url.lastPathComponent): \(problems.prefix(5))")
            // And reads back.
            _ = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        }
    }

    @Test func chartsCommentsAndTablesSurviveASave() throws {
        for url in Self.fixtures {
            let original = try Package(Data(contentsOf: url))
            let workbook = try XLSXReader.read(data: Data(contentsOf: url))
            let written = try Package(XLSXWriter.data(for: workbook))
            // Chart sheets aren't kept, nor the charts on them.
            let chartSheets = !original.names(under: "xl/chartsheets/").isEmpty
            for folder in ["xl/tables/", "xl/comments", "xl/threadedComments/", "xl/theme/", "xl/media/"]
            + (chartSheets ? [] : ["xl/charts/", "xl/drawings/"]) {
                #expect(written.names(under: folder).count == original.names(under: folder).count,
                        "\(url.lastPathComponent): \(folder) \(original.names(under: folder)) -> \(written.names(under: folder))")
            }
        }
    }
}
