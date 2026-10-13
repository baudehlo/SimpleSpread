import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Pivot parts with bad indices and numbers must never trap: every pivot in
/// the fixtures is parsed again with one attribute at a time set to a hostile
/// value, then validated, computed (it either computes or is refused as
/// preserve-only) and read by GETPIVOTDATA.
@Suite("Pivot tables: malformed parts", .serialized)
struct PivotMalformedTests {
    static let hostile = ["-1", "-2", "999999", "0", "nan", "1e308", "9223372036854775807"]

    /// `xml` with the `occurrence`-th value of `attribute` replaced.
    static func mutate(_ xml: String, attribute: String, occurrence: Int, to value: String) -> String? {
        let pattern = "\\b\(attribute)=\"[^\"]*\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        guard occurrence < matches.count, let range = Range(matches[occurrence].range, in: xml) else { return nil }
        var out = xml
        out.replaceSubrange(range, with: "\(attribute)=\"\(value)\"")
        return out
    }

    /// Everything that reads a pivot, none of which may trap.
    static func exercise(_ data: PivotCacheData, _ definition: PivotDefinition) {
        let engine = PivotEngine(cache: data, definition: definition)
        _ = engine.unsupportedReason
        _ = try? engine.compute()
        let table = PivotTable(sheetID: 1, name: "P", cacheID: 1, location: CellRange(a1: "A3:F40")!,
                               payload: PivotTablePayload(definition: Data()), definition: definition)
        let field = data.fields.first?.name ?? ""
        _ = table.dataCellAddress(dataField: definition.dataFields.first?.name ?? "", constraints: [], cache: data)
        _ = table.dataCellAddress(dataField: field, constraints: [(field, .string("x"))], cache: data)
    }

    static let tableAttributes = ["x", "fld", "item", "baseField", "baseItem", "iMeasureFld", "val", "r", "i",
                                  "indent", "pageWrap", "v"]
    static let cacheAttributes = ["groupInterval", "startNum", "endNum", "base", "par", "v", "startDate", "endDate"]

    @Test(arguments: PivotFixtures.all)
    func hostileTableAttributesNeverTrap(_ name: String) throws {
        let (workbook, _) = try PivotFixtures.read(name)
        let formats = PivotXMLParser.FormatTable(custom: workbook.preservedStyles?.numberFormats ?? [:])
        for table in workbook.pivotTables {
            guard let payload = table.payload as? PivotTablePayload,
                  let data = workbook.pivotCache(withID: table.cacheID)?.data else { continue }
            let xml = String(decoding: payload.definition, as: UTF8.self)
            for attribute in Self.tableAttributes {
                for occurrence in 0..<3 {
                    for value in Self.hostile {
                        guard let bad = Self.mutate(xml, attribute: attribute, occurrence: occurrence, to: value) else { continue }
                        guard let definition = try? PivotXMLParser.parseTable(Data(bad.utf8), formats: formats) else { continue }
                        Self.exercise(data, definition)
                    }
                }
            }
        }
    }

    @Test(arguments: PivotFixtures.all)
    func hostileCacheAttributesNeverTrap(_ name: String) throws {
        let (workbook, _) = try PivotFixtures.read(name)
        let formats = PivotXMLParser.FormatTable(custom: workbook.preservedStyles?.numberFormats ?? [:])
        for cache in workbook.pivotCaches {
            guard let payload = cache.payload as? PivotCachePayload,
                  let records = payload.records, records.count < 200_000 else { continue }
            let definitions = workbook.pivotTables.filter { $0.cacheID == cache.cacheID }.compactMap(\.definition)
            let xml = String(decoding: payload.definition, as: UTF8.self)
            for attribute in Self.cacheAttributes {
                for occurrence in 0..<2 {
                    for value in Self.hostile {
                        guard let bad = Self.mutate(xml, attribute: attribute, occurrence: occurrence, to: value),
                              let data = try? PivotXMLParser.parseCache(definition: Data(bad.utf8), records: records,
                                                                        formats: formats) else { continue }
                        for definition in definitions { Self.exercise(data, definition) }
                    }
                }
            }
            // Record indices out of range.
            let recordsXML = String(decoding: records, as: UTF8.self)
            for value in ["-1", "999999"] {
                guard let bad = Self.mutate(recordsXML, attribute: "v", occurrence: 0, to: value),
                      let data = try? PivotXMLParser.parseCache(definition: payload.definition, records: Data(bad.utf8),
                                                                formats: formats) else { continue }
                for definition in definitions { Self.exercise(data, definition) }
            }
        }
    }

    // MARK: The review's cases, one by one

    /// Name | Qty, three records, a row field and a value field.
    static func small() -> (PivotCacheData, PivotDefinition) {
        let data = PivotCacheData(fields: [
            PivotCacheField(name: "Name", sharedItems: [.string("a"), .string("b")]),
            PivotCacheField(name: "Qty"),
        ], records: [[.shared(0), .value(.number(1))], [.shared(1), .value(.number(2))], [.shared(0), .value(.number(3))]])
        var d = PivotDefinition.new(name: "P", cache: data)
        d.place(field: 0, in: .rows, cache: data)
        d.place(field: 1, in: .values, cache: data)
        return (data, d)
    }

    @Test func aRowFieldTheCacheDoesntHaveIsPreserveOnly() {
        var (data, d) = Self.small()
        d.rowFields = [5]
        let engine = PivotEngine(cache: data, definition: d)
        #expect(engine.unsupportedReason?.contains("field 5") == true)
        #expect(throws: PivotEngineError.self) { try engine.compute() }
        data.fields[0].sharedItems = []
        #expect(PivotEngine(cache: data, definition: Self.small().1).unsupportedReason != nil)
    }

    @Test func outOfRangeItemsAreRefused() {
        var (data, d) = Self.small()
        d.fields[0].items[0].index = 7
        #expect(PivotEngine(cache: data, definition: d).unsupportedReason?.contains("Name") == true)
        d = Self.small().1
        d.place(field: 0, in: .filters, cache: data)
        d.pageFields[0].selectedItem = -3
        #expect(PivotEngine(cache: data, definition: d).unsupportedReason != nil)
        data.records[0][0] = .shared(42) // a record pointing past the shared items computes (as blank)
        #expect((try? PivotEngine(cache: data, definition: Self.small().1).compute()) != nil)
    }

    @Test func aZeroGroupIntervalIsRefused() {
        var (data, d) = Self.small()
        data.fields[1].group = PivotFieldGroup(base: 1, range: .init(groupBy: .range, startNumber: 0, endNumber: 5, interval: 0),
                                               items: [.string("<0"), .string("0-5"), .string(">5")])
        d.place(field: 1, in: .rows, cache: data)
        #expect(PivotEngine(cache: data, definition: d).unsupportedReason?.contains("interval") == true)
        // The bucket itself never traps, whatever the interval.
        for interval in [0, -1, 1e-300, .nan, .infinity] {
            let range = PivotFieldGroup.Range(groupBy: .range, startNumber: 0, endNumber: 1e300, interval: interval)
            _ = PivotEngine.bucket(range, itemCount: 3, value: .number(1e299))
            _ = PivotEngine.bucket(PivotFieldGroup.Range(groupBy: .days, startDate: 0, endDate: 1e6, interval: interval),
                                   itemCount: 3, value: .date(5000))
        }
    }

    @Test func aNegativeTopTenIsRefusedAndNeverTraps() throws {
        var (data, d) = Self.small()
        d.filters = [PivotFilter(field: 0, type: "count", top10Value: -5)]
        #expect(PivotEngine(cache: data, definition: d).unsupportedReason != nil)
        d.filters = [PivotFilter(field: 0, type: "count", top10Value: 1e300)]
        let all = try PivotEngine(cache: data, definition: d).compute()
        #expect(all.rowLines.count == 3) // a, b, grand total
        d.filters = [PivotFilter(field: 0, type: "count", top10Value: 1)]
        let top = try PivotEngine(cache: data, definition: d).compute()
        #expect(top.rowLines.count == 2) // a (4), grand total
        data.records = []
        _ = try PivotEngine(cache: data, definition: d).compute()
    }

    @Test func aCalculatedFieldReferringToItselfIsRefused() {
        var (data, d) = Self.small()
        data.fields.append(PivotCacheField(name: "Loop", formula: "Loop*2", isDatabaseField: false))
        data.fields.append(PivotCacheField(name: "A", formula: "B+1", isDatabaseField: false))
        data.fields.append(PivotCacheField(name: "B", formula: "'A'+Qty", isDatabaseField: false))
        d.fields += [PivotFieldSettings(), PivotFieldSettings(), PivotFieldSettings()]
        d.place(field: 2, in: .values, cache: data)
        let engine = PivotEngine(cache: data, definition: d)
        #expect(engine.unsupportedReason?.contains("refers to itself") == true)
        // Mutual recursion is caught too, and the engine never recurses forever.
        #expect(data.calculatedFieldCycle() != nil)
        #expect(engine.value(field: 3, subtotal: .sum, records: [0, 1, 2]) != nil)
    }

    @Test func hugeIndentsAndWrapsAreRefused() {
        var (data, d) = Self.small()
        d.layout.indent = Int.max
        #expect(PivotEngine(cache: data, definition: d).unsupportedReason != nil)
        d = Self.small().1
        d.layout.pageWrap = Int.max
        #expect(PivotEngine(cache: data, definition: d).unsupportedReason != nil)
        _ = data
    }

    @Test func getPivotDataSurvivesNegativeRepeats() {
        let (data, d) = Self.small()
        var table = PivotTable(sheetID: 1, name: "P", cacheID: 1, location: CellRange(a1: "A3:B6")!,
                               payload: PivotTablePayload(definition: Data()), definition: d)
        table.definition?.rowLines = [PivotAxisLine(kind: .data, repeated: -4, members: [0]),
                                      PivotAxisLine(kind: .data, repeated: 99, members: [1])]
        _ = table.dataCellAddress(dataField: "Sum of Qty", constraints: [("Name", .string("a"))], cache: data)
    }
}
