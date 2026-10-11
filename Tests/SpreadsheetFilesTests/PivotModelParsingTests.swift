import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("Pivot model parsing", .serialized)
struct PivotModelParsingTests {
    @Test(arguments: PivotFixtures.all)
    func everyKeptPivotParsesConsistently(_ name: String) throws {
        let (workbook, _) = try PivotFixtures.read(name)
        for cache in workbook.pivotCaches {
            let data = try cache.parsedData(styles: workbook.preservedStyles)
            let payload = try #require(cache.payload as? PivotCachePayload)
            var recordCount: Int?
            try XMLRewriter.scan(payload.definition) { element in
                if element.path == ["pivotCacheDefinition"] { recordCount = Int(element.attributes["recordCount"] ?? "") }
                return .keep
            }
            if payload.records != nil, let recordCount {
                #expect(data.records.count == recordCount, "\(name) cache \(cache.cacheID)")
            }
            let databaseFields = data.fields.filter(\.isDatabaseField).count
            for (r, record) in data.records.enumerated() {
                #expect(record.count == databaseFields, "\(name) cache \(cache.cacheID) record \(r)")
                for (f, value) in record.enumerated() {
                    if case .shared(let i) = value {
                        #expect(i >= 0 && i < data.fields[f].sharedItems.count,
                                "\(name) cache \(cache.cacheID) record \(r) field \(f) index \(i)")
                    }
                }
            }
        }
        for table in workbook.pivotTables {
            let definition = try table.parsedDefinition(styles: workbook.preservedStyles)
            let cache = try #require(workbook.pivotCache(withID: table.cacheID))
            let data = try cache.parsedData(styles: workbook.preservedStyles)
            #expect(definition.name == table.name)
            #expect(definition.fields.count == data.fields.count, "\(name) \(table.name) field count")
            for index in definition.rowFields + definition.columnFields where index != pivotValuesFieldIndex {
                #expect(index >= 0 && index < definition.fields.count)
            }
            for dataField in definition.dataFields {
                #expect(dataField.field >= 0 && dataField.field < data.fields.count)
            }
            for (f, field) in definition.fields.enumerated() {
                let itemCount = data.fields[f].axisItems.count
                for item in field.items where item.kind == .data {
                    #expect(item.index.map { $0 >= 0 && $0 < itemCount } ?? false,
                            "\(name) \(table.name) field \(f) item \(item.index ?? -1) of \(itemCount)")
                }
            }
            // rowItems/colItems were read (any table with axis fields has lines).
            if !definition.rowFields.isEmpty { #expect(!definition.rowLines.isEmpty, "\(name) \(table.name) rowItems") }
        }
    }

    @Test func parsesTheCalaminePivotInDetail() throws {
        let (workbook, _) = try PivotFixtures.read("calamine-pivots.xlsx")
        let sheet = try #require(workbook.sheet(named: "PivotSheet1"))
        let table = try #require(workbook.pivotTables(onSheet: sheet.id).first)
        let d = try table.parsedDefinition(styles: workbook.preservedStyles)
        #expect(d.rowFields == [2])
        #expect(d.columnFields == [pivotValuesFieldIndex])
        #expect(d.pageFields == [PivotPageField(field: 5, selectedItem: nil)])
        #expect(d.dataFields.map(\.name) == ["Sum of Size", "Average of Value", "Count of Size", "Sum of Value x 2"])
        #expect(d.dataFields.map(\.subtotal) == [.sum, .average, .count, .sum])
        #expect(d.fields[5].items.filter(\.hidden).count == 7)
        #expect(d.rowLines.count == 2)
        #expect(d.rowLines[1].kind == .grand)
        #expect(d.columnLines.map(\.dataFieldIndex) == [0, 1, 2, 3])
        let data = try workbook.pivotCache(withID: table.cacheID)!.parsedData(styles: workbook.preservedStyles)
        #expect(data.fields[1].sharedItems.first == .string("a"))
        #expect(data.fields[10].formula != nil)            // "Value x 2"
        #expect(data.fields[10].isDatabaseField == false)
        #expect(data.records.count == 10)
    }

    @Test func parsesDateGrouping() throws {
        let (workbook, _) = try PivotFixtures.read("libreoffice-shared-nested-dategroup.xlsx")
        let data = try workbook.pivotCaches[0].parsedData(styles: workbook.preservedStyles)
        let grouped = data.fields.filter { $0.group?.range != nil }
        #expect(!grouped.isEmpty)
        let groupings = Set(grouped.compactMap { $0.group?.range?.groupBy })
        #expect(groupings.contains(.months))
    }
}
