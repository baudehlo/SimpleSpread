import Foundation
import XCTest
import SpreadsheetCore
@testable import SpreadsheetFiles

final class CompoundFileReaderTests: XCTestCase {
    func testReadsRegularRootStream() throws {
        let bytes = makeCompoundFile(stream: Data((0..<5000).map { UInt8($0 % 251) }))
        let reader = try CompoundFileReader(data: bytes)
        XCTAssertEqual(reader.streamNames, ["Workbook"])
        XCTAssertEqual(try reader.stream(named: "Workbook"), Data((0..<5000).map { UInt8($0 % 251) }))
        XCTAssertNil(try reader.stream(named: "Book"))
    }

    func testReadsMiniStream() throws {
        let payload = Data((0..<300).map { UInt8($0 % 251) })
        let reader = try CompoundFileReader(data: makeCompoundFile(stream: payload))
        XCTAssertEqual(try reader.stream(named: "Workbook"), payload)
    }

    func testReadsStreamAcrossMultipleRegularSectors() throws {
        let payload = Data((0..<1100).map { UInt8($0 % 239) })
        let reader = try CompoundFileReader(data: makeCompoundFile(stream: payload))
        XCTAssertEqual(try reader.stream(named: "Workbook"), payload)
    }

    func testRejectsCyclicStreamChain() throws {
        let bytes = makeCompoundFile(stream: Data(repeating: 0x41, count: 5000))
        var corrupted = bytes
        setUInt32(512 + 4 * 4, value: 4, in: &corrupted)
        let reader = try CompoundFileReader(data: corrupted)
        XCTAssertThrowsError(try reader.stream(named: "Workbook"))
    }

    func testRejectsTruncatedContainer() {
        XCTAssertThrowsError(try CompoundFileReader(data: Data(repeating: 0, count: 100)))
    }

    func testAcceptsDataSliceWithNonzeroStartIndex() throws {
        let container = makeCompoundFile(stream: Data("sliced".utf8))
        let wrapped = Data([0xFF]) + container + Data([0xEE])
        let slice = wrapped[1..<(wrapped.count - 1)]
        let reader = try CompoundFileReader(data: slice)
        XCTAssertEqual(try reader.stream(named: "Workbook"), Data("sliced".utf8))
    }

    func testIgnoresHighStreamSizeBitsInVersionThree() throws {
        var bytes = makeCompoundFile(stream: Data("low bits".utf8))
        setDirectoryEntry(index: 0, offset: 124, value: 0xFFFFFFFF, in: &bytes)
        setDirectoryEntry(index: 1, offset: 124, value: 0xFFFFFFFF, in: &bytes)
        let reader = try CompoundFileReader(data: bytes)
        XCTAssertEqual(try reader.stream(named: "Workbook"), Data("low bits".utf8))
    }

    func testRejectsUnrepresentableRootMiniStreamSize() {
        var bytes = makeCompoundFile(stream: Data("v4".utf8), sectorSize: 4096)
        setUInt32(sectorOffset(1, sectorSize: 4096) + 124, value: 0xFFFFFFFF, in: &bytes)
        XCTAssertThrowsError(try CompoundFileReader(data: bytes))
    }

    func testReadsAndValidatesExternalDIFATChain() throws {
        let valid = makeCompoundFileWithExternalDIFAT()
        let reader = try CompoundFileReader(data: valid)
        XCTAssertEqual(try reader.stream(named: "Workbook"), Data("DIFAT".utf8))

        var repeatedFATSector = valid
        setUInt32(sectorOffset(110, sectorSize: 512), value: 108, in: &repeatedFATSector)
        XCTAssertThrowsError(try CompoundFileReader(data: repeatedFATSector))

        var cyclicDIFAT = valid
        setUInt32(sectorOffset(110, sectorSize: 512) + 508, value: 110, in: &cyclicDIFAT)
        XCTAssertThrowsError(try CompoundFileReader(data: cyclicDIFAT))
    }

    func testNestedStreamIsNotReportedAsRootStream() throws {
        var bytes = makeCompoundFile(stream: Data("Workbook".utf8), includeNestedStream: true)
        // Make the root stream's sibling a storage that contains a nested stream.
        setDirectoryEntry(index: 1, offset: 72, value: 2, in: &bytes)
        let reader = try CompoundFileReader(data: bytes)
        XCTAssertEqual(reader.streamNames, ["Workbook"])
        XCTAssertEqual(try reader.stream(named: "Workbook"), Data("Workbook".utf8))
        XCTAssertNil(try reader.stream(named: "NestedWorkbook"))
    }

    func testReadsStreamsFromRealExcelContainers() throws {
        let fixtureRoot = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/LegacyXLS")
        for name in ["business-export.xls", "dates-1904.xls"] {
            let bytes = try Data(contentsOf: fixtureRoot.appendingPathComponent(name))
            let reader = try CompoundFileReader(data: bytes)
            XCTAssertTrue(reader.streamNames.contains("Workbook") || reader.streamNames.contains("Book"), name)
            let stream = try reader.stream(named: reader.streamNames.contains("Workbook") ? "Workbook" : "Book")
            XCTAssertNotNil(stream, name)
            XCTAssertGreaterThan(stream?.count ?? 0, 0, name)
        }
    }

    func testReadsVersionFourContainer() throws {
        let payload = Data("v4 workbook stream".utf8)
        let reader = try CompoundFileReader(data: makeCompoundFile(stream: payload, sectorSize: 4096))
        XCTAssertEqual(try reader.stream(named: "Workbook"), payload)
    }

    func testXLSRejectsEncryptionAndOlderBIFFVersions() throws {
        let encrypted = biffWorkbook(cells: biffNumber(7), extraGlobals: biffRecord(0x002F, Data([0, 0])))
        XCTAssertThrowsError(try XLSReader.read(data: makeCompoundFile(stream: encrypted))) {
            XCTAssertEqual($0 as? XLSError, .encrypted)
        }
        var oldVersion = biffWorkbook(cells: biffNumber(7))
        setUInt16(4, value: 0x0500, in: &oldVersion)
        XCTAssertThrowsError(try XLSReader.read(data: makeCompoundFile(stream: oldVersion))) {
            XCTAssertEqual($0 as? XLSError, .unsupportedVersion)
        }
    }

    func testXLSRejectsMissingEOFAndInvalidSharedStringReference() {
        let missingEOF = biffWorkbook(cells: biffNumber(7), includeSheetEOF: false)
        XCTAssertThrowsError(try XLSReader.read(data: makeCompoundFile(stream: missingEOF)))
        let badString = biffRecord(0x00FD, Data(repeating: 0, count: 10))
        XCTAssertThrowsError(try XLSReader.read(data: makeCompoundFile(stream: biffWorkbook(cells: badString))))
    }

    func testXLSRejectsDisplacedAndMissingFormulaString() {
        var formula = Data(repeating: 0, count: 22)
        formula[12] = 255
        formula[13] = 255
        let stringFormula = biffRecord(0x0006, formula)
        let string = biffRecord(0x0207, Data([1, 0, 0, 65]))
        let displaced = biffWorkbook(cells: stringFormula + biffNumber(2) + string)
        XCTAssertThrowsError(try XLSReader.read(data: makeCompoundFile(stream: displaced)))
        let missing = biffWorkbook(cells: stringFormula)
        XCTAssertThrowsError(try XLSReader.read(data: makeCompoundFile(stream: missing)))
    }

    func testXLSNestedChartDoesNotEndTheWorksheetOrOverwriteCells() throws {
        let chart = biffBOF(0x0020) + biffNumber(999) + biffRecord(0x000A, Data())
        let stream = biffWorkbook(cells: biffNumber(7) + chart + biffNumber(8, row: 1))
        var warnings: [String] = []
        let workbook = try XLSReader.read(data: makeCompoundFile(stream: stream), unsupportedContent: &warnings)
        XCTAssertEqual(workbook.sheets[0].value(at: CellAddress(row: 0, column: 0)), .number(7))
        XCTAssertEqual(workbook.sheets[0].value(at: CellAddress(row: 1, column: 0)), .number(8))
        XCTAssertTrue(warnings.contains { $0.contains("charts") })
    }

    func testXLSStringRejectsMissingExtendedMetadata() {
        let string = Data([1, 0, 0x04, 1, 0, 0, 0, 65])
        XCTAssertThrowsError(try BIFFString.read(string, at: 0))
    }

    func testXLSCanCancelWithinASingleWorksheet() throws {
        var cells = Data()
        for row in 0..<600 { cells.append(biffNumber(Double(row), row: UInt16(row))) }
        var progressCalls = 0
        var warnings: [String] = []
        XCTAssertThrowsError(try XLSReader.read(
            data: makeCompoundFile(stream: biffWorkbook(cells: cells)),
            unsupportedContent: &warnings,
            progress: { _ in progressCalls += 1; return progressCalls == 1 })) {
                XCTAssertEqual($0 as? XLSError, .cancelled)
            }
        XCTAssertEqual(progressCalls, 2)
    }

    private func biffRecord(_ type: UInt16, _ payload: Data) -> Data {
        var record = Data(repeating: 0, count: 4)
        setUInt16(0, value: type, in: &record)
        setUInt16(2, value: UInt16(payload.count), in: &record)
        record.append(payload)
        return record
    }

    private func biffBOF(_ type: UInt16) -> Data {
        var payload = Data(repeating: 0, count: 16)
        setUInt16(0, value: 0x0600, in: &payload)
        setUInt16(2, value: type, in: &payload)
        return biffRecord(0x0809, payload)
    }

    private func biffNumber(_ value: Double, row: UInt16 = 0) -> Data {
        var payload = Data(repeating: 0, count: 14)
        setUInt16(0, value: row, in: &payload)
        setUInt64(6, value: value.bitPattern, in: &payload)
        return biffRecord(0x0203, payload)
    }

    private func biffWorkbook(cells: Data, extraGlobals: Data = Data(),
                              includeSheetEOF: Bool = true) -> Data {
        let globals = biffBOF(0x0005) + biffRecord(0x00E0, Data(repeating: 0, count: 20)) + extraGlobals
        var bound = Data([0, 0, 0, 0, 0, 0, 1, 0, 65])
        setUInt32(0, value: UInt32(globals.count + bound.count + 8), in: &bound)
        return globals + biffRecord(0x0085, bound) + biffRecord(0x000A, Data())
            + biffBOF(0x0010) + cells + (includeSheetEOF ? biffRecord(0x000A, Data()) : Data())
    }

    private func makeCompoundFile(stream payload: Data, includeNestedStream: Bool = false,
                                  sectorSize: Int = 512) -> Data {
        let miniCount = payload.count < 4096 ? max(1, (payload.count + 63) / 64) : 0
        let regularCount = payload.count >= 4096 ? (payload.count + sectorSize - 1) / sectorSize : 0
        let dataStart = 3
        let rootSectorCount = max(1, (miniCount * 64 + sectorSize - 1) / sectorSize)
        let regularDataStart = dataStart + rootSectorCount
        let dataSectorCount = rootSectorCount + regularCount
        let miniFATSector = dataStart + dataSectorCount
        let totalSectors = miniFATSector + 1
        var file = Data(repeating: 0, count: sectorSize * (totalSectors + 1))
        let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        file.replaceSubrange(0..<8, with: signature)
        setUInt16(24, value: 0x003E, in: &file)
        setUInt16(26, value: sectorSize == 512 ? 3 : 4, in: &file)
        setUInt16(28, value: 0xFFFE, in: &file)
        setUInt16(30, value: sectorSize == 512 ? 9 : 12, in: &file)
        setUInt16(32, value: 6, in: &file)
        setUInt32(40, value: sectorSize == 512 ? 0 : 1, in: &file)
        setUInt32(44, value: 1, in: &file)
        setUInt32(48, value: 1, in: &file)
        setUInt32(56, value: 4096, in: &file)
        setUInt32(60, value: UInt32(miniFATSector), in: &file)
        setUInt32(64, value: 1, in: &file)
        setUInt32(68, value: 0xFFFFFFFE, in: &file)
        setUInt32(72, value: 0, in: &file)
        for offset in stride(from: 76, to: 512, by: 4) { setUInt32(offset, value: 0xFFFFFFFF, in: &file) }
        setUInt32(76, value: 0, in: &file)

        let fatOffset = sectorOffset(0, sectorSize: sectorSize)
        var fat = [UInt32](repeating: 0xFFFFFFFF, count: sectorSize / 4)
        fat[0] = 0xFFFFFFFD
        fat[1] = 0xFFFFFFFE
        fat[2] = 0xFFFFFFFE
        for index in 0..<rootSectorCount { fat[dataStart + index] = index + 1 == rootSectorCount ? 0xFFFFFFFE : UInt32(dataStart + index + 1) }
        for index in 0..<regularCount { fat[regularDataStart + index] = index + 1 == regularCount ? 0xFFFFFFFE : UInt32(regularDataStart + index + 1) }
        fat[miniFATSector] = 0xFFFFFFFE
        for (index, value) in fat.enumerated() { setUInt32(fatOffset + index * 4, value: value, in: &file) }

        var directory = Data(repeating: 0, count: sectorSize)
        writeDirectoryEntry(index: 0, name: "Root Entry", type: 5, child: 1,
                            startSector: UInt32(dataStart), size: UInt64(miniCount * 64), in: &directory)
        writeDirectoryEntry(index: 1, name: "Workbook", type: 2, startSector: payload.count < 4096 ? 0 : UInt32(regularDataStart),
                            size: UInt64(payload.count), in: &directory)
        if includeNestedStream {
            writeDirectoryEntry(index: 2, name: "Folder", type: 1, child: 3, in: &directory)
            writeDirectoryEntry(index: 3, name: "NestedWorkbook", type: 2, startSector: 0, size: 8, in: &directory)
        }
        file.replaceSubrange(sectorOffset(1, sectorSize: sectorSize)..<sectorOffset(1, sectorSize: sectorSize) + sectorSize, with: directory)

        if payload.count < 4096 {
            let miniStreamOffset = sectorOffset(dataStart, sectorSize: sectorSize)
            file.replaceSubrange(miniStreamOffset..<(miniStreamOffset + payload.count), with: payload)
            let miniFATOffset = sectorOffset(miniFATSector, sectorSize: sectorSize)
            for index in 0..<miniCount { setUInt32(miniFATOffset + index * 4, value: index + 1 == miniCount ? 0xFFFFFFFE : UInt32(index + 1), in: &file) }
        } else {
            for index in 0..<regularCount {
                let start = index * sectorSize
                let end = min(start + sectorSize, payload.count)
                let destination = sectorOffset(regularDataStart + index, sectorSize: sectorSize)
                file.replaceSubrange(destination..<(destination + end - start), with: payload[start..<end])
            }
        }
        return file
    }

    private func makeCompoundFileWithExternalDIFAT() -> Data {
        let sectorSize = 512
        let fatSectorCount = 110
        let difatSector = 110
        let directorySector = 111
        let rootMiniStreamSector = 112
        let miniFATSector = 113
        let totalSectors = miniFATSector + 1
        var file = Data(repeating: 0, count: sectorSize * (totalSectors + 1))
        file.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        setUInt16(24, value: 0x003E, in: &file)
        setUInt16(26, value: 3, in: &file)
        setUInt16(28, value: 0xFFFE, in: &file)
        setUInt16(30, value: 9, in: &file)
        setUInt16(32, value: 6, in: &file)
        setUInt32(44, value: UInt32(fatSectorCount), in: &file)
        setUInt32(48, value: UInt32(directorySector), in: &file)
        setUInt32(56, value: 4096, in: &file)
        setUInt32(60, value: UInt32(miniFATSector), in: &file)
        setUInt32(64, value: 1, in: &file)
        setUInt32(68, value: UInt32(difatSector), in: &file)
        setUInt32(72, value: 1, in: &file)
        for index in 0..<109 { setUInt32(76 + index * 4, value: UInt32(index), in: &file) }

        let externalDIFATOffset = sectorOffset(difatSector, sectorSize: sectorSize)
        setUInt32(externalDIFATOffset, value: 109, in: &file)
        for index in 1..<127 { setUInt32(externalDIFATOffset + index * 4, value: 0xFFFFFFFF, in: &file) }
        setUInt32(externalDIFATOffset + 508, value: 0xFFFFFFFE, in: &file)

        var fatEntries = [UInt32](repeating: 0xFFFFFFFF, count: fatSectorCount * (sectorSize / 4))
        for index in 0..<fatSectorCount { fatEntries[index] = 0xFFFFFFFD }
        fatEntries[difatSector] = 0xFFFFFFFC
        fatEntries[directorySector] = 0xFFFFFFFE
        fatEntries[rootMiniStreamSector] = 0xFFFFFFFE
        fatEntries[miniFATSector] = 0xFFFFFFFE
        for sectorIndex in 0..<fatSectorCount {
            let start = sectorIndex * (sectorSize / 4)
            let offset = sectorOffset(sectorIndex, sectorSize: sectorSize)
            for item in 0..<(sectorSize / 4) {
                setUInt32(offset + item * 4, value: fatEntries[start + item], in: &file)
            }
        }

        var directory = Data(repeating: 0, count: sectorSize)
        writeDirectoryEntry(index: 0, name: "Root Entry", type: 5, child: 1,
                            startSector: UInt32(rootMiniStreamSector), size: 64, in: &directory)
        writeDirectoryEntry(index: 1, name: "Workbook", type: 2, startSector: 0,
                            size: 5, in: &directory)
        let directoryOffset = sectorOffset(directorySector, sectorSize: sectorSize)
        file.replaceSubrange(directoryOffset..<(directoryOffset + sectorSize), with: directory)
        let miniStreamOffset = sectorOffset(rootMiniStreamSector, sectorSize: sectorSize)
        file.replaceSubrange(miniStreamOffset..<(miniStreamOffset + 5), with: Data("DIFAT".utf8))
        setUInt32(sectorOffset(miniFATSector, sectorSize: sectorSize), value: 0xFFFFFFFE, in: &file)
        return file
    }

    private func writeDirectoryEntry(index: Int, name: String, type: UInt8, left: UInt32 = 0xFFFFFFFF,
                                     right: UInt32 = 0xFFFFFFFF, child: UInt32 = 0xFFFFFFFF,
                                     startSector: UInt32 = 0xFFFFFFFE, size: UInt64 = 0, in data: inout Data) {
        let offset = index * 128
        let units = Array(name.utf16)
        for (index, unit) in units.enumerated() { setUInt16(offset + index * 2, value: unit, in: &data) }
        setUInt16(offset + 64, value: UInt16((units.count + 1) * 2), in: &data)
        data[offset + 66] = type
        setUInt32(offset + 68, value: left, in: &data)
        setUInt32(offset + 72, value: right, in: &data)
        setUInt32(offset + 76, value: child, in: &data)
        setUInt32(offset + 116, value: startSector, in: &data)
        setUInt64(offset + 120, value: size, in: &data)
    }

    private func sectorOffset(_ id: Int, sectorSize: Int) -> Int { (id + 1) * sectorSize }

    private func setDirectoryEntry(index: Int, offset: Int, value: UInt32, in data: inout Data) {
        setUInt32(sectorOffset(1, sectorSize: 512) + index * 128 + offset, value: value, in: &data)
    }

    private func setUInt16(_ offset: Int, value: UInt16, in data: inout Data) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func setUInt32(_ offset: Int, value: UInt32, in data: inout Data) {
        setUInt16(offset, value: UInt16(value & 0xFFFF), in: &data)
        setUInt16(offset + 2, value: UInt16(value >> 16), in: &data)
    }

    private func setUInt64(_ offset: Int, value: UInt64, in data: inout Data) {
        setUInt32(offset, value: UInt32(value & 0xFFFFFFFF), in: &data)
        setUInt32(offset + 4, value: UInt32(value >> 32), in: &data)
    }
}
