import Foundation

enum CompoundFileError: Error, LocalizedError {
    case invalid(String)
    case truncated
    case corruptChain

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .truncated: return "The compound file is truncated."
        case .corruptChain: return "The compound file contains a corrupt sector chain."
        }
    }
}

struct CompoundFileReader {
    private static let endOfChain: UInt32 = 0xFFFFFFFE
    private static let freeSector: UInt32 = 0xFFFFFFFF
    private static let fatSector: UInt32 = 0xFFFFFFFD
    private static let difatSector: UInt32 = 0xFFFFFFFC
    private static let maxRegularSector: UInt32 = 0xFFFFFFFA

    private struct DirectoryEntry {
        let name: String
        let type: UInt8
        let left: UInt32
        let right: UInt32
        let child: UInt32
        let startSector: UInt32
        let size: UInt64
    }

    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize = 64
    private let sectorCount: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let rootMiniStream: Data
    private let rootStreams: [String: DirectoryEntry]

    var streamNames: [String] { rootStreams.keys.sorted() }

    init(data: Data) throws {
        try self.init(normalizedData: Data(data))
    }

    private init(normalizedData data: Data) throws {
        self.data = data
        guard data.count >= 512 else { throw CompoundFileError.truncated }
        guard Array(data[0..<8]) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] else {
            throw CompoundFileError.invalid("The file is not a compound file.")
        }

        let major = try Self.readUInt16(data, at: 26)
        let shift = try Self.readUInt16(data, at: 30)
        let miniShift = try Self.readUInt16(data, at: 32)
        guard (major == 3 && shift == 9) || (major == 4 && shift == 12) else {
            throw CompoundFileError.invalid("The compound file version is unsupported.")
        }
        guard miniShift == 6, try Self.readUInt16(data, at: 28) == 0xFFFE else {
            throw CompoundFileError.invalid("The compound file header is invalid.")
        }
        sectorSize = 1 << Int(shift)
        guard data.count >= sectorSize else { throw CompoundFileError.truncated }
        sectorCount = data.count / sectorSize - 1
        let declaredDirectorySectors = try Self.readUInt32(data, at: 40)
        if major == 3 && declaredDirectorySectors != 0 {
            throw CompoundFileError.invalid("The version 3 directory sector count must be zero.")
        }
        let fatSectorCount = Int(try Self.readUInt32(data, at: 44))
        let firstDirectorySector = try Self.readUInt32(data, at: 48)
        let miniCutoff = try Self.readUInt32(data, at: 56)
        guard miniCutoff == 4096 else { throw CompoundFileError.invalid("The mini stream cutoff is invalid.") }
        let firstMiniFATSector = try Self.readUInt32(data, at: 60)
        let miniFATSectorCount = Int(try Self.readUInt32(data, at: 64))
        let firstDIFATSector = try Self.readUInt32(data, at: 68)
        let difatSectorCount = Int(try Self.readUInt32(data, at: 72))

        let fatSectorIDs = try Self.readDIFAT(data, sectorSize: sectorSize, sectorCount: sectorCount,
                                             firstSector: firstDIFATSector, sectorCountInChain: difatSectorCount,
                                             expectedFATSectors: fatSectorCount)
        var fatEntries: [UInt32] = []
        for sectorID in fatSectorIDs {
            let bytes = try Self.sector(data, id: sectorID, size: sectorSize, count: sectorCount)
            for offset in stride(from: 0, to: sectorSize, by: 4) {
                fatEntries.append(try Self.readUInt32(bytes, at: offset))
            }
        }
        guard fatEntries.count >= sectorCount else { throw CompoundFileError.corruptChain }
        for sectorID in fatSectorIDs where fatEntries[Int(sectorID)] != Self.fatSector {
            throw CompoundFileError.corruptChain
        }
        fat = fatEntries

        let directoryBytes = try Self.readRegularChain(start: firstDirectorySector, expectedSize: nil,
                                                       fat: fat, data: data, sectorSize: sectorSize,
                                                       sectorCount: sectorCount)
        if major == 4 && directoryBytes.count / sectorSize != Int(declaredDirectorySectors) {
            throw CompoundFileError.corruptChain
        }
        let entries = try Self.parseDirectory(directoryBytes, majorVersion: major)
        guard let root = entries.first, root.type == 5 else { throw CompoundFileError.invalid("The root directory entry is missing.") }
        rootStreams = try Self.readRootStreams(entries: entries, root: root)

        let miniFATBytes: Data
        if miniFATSectorCount == 0 {
            guard firstMiniFATSector == Self.endOfChain || firstMiniFATSector == Self.freeSector else {
                throw CompoundFileError.corruptChain
            }
            miniFATBytes = Data()
        } else {
            miniFATBytes = try Self.readRegularChain(start: firstMiniFATSector,
                                                     expectedSize: miniFATSectorCount * sectorSize,
                                                     fat: fat, data: data, sectorSize: sectorSize,
                                                     sectorCount: sectorCount)
        }
        var miniFATEntries: [UInt32] = []
        for offset in stride(from: 0, to: miniFATBytes.count, by: 4) {
            miniFATEntries.append(try Self.readUInt32(miniFATBytes, at: offset))
        }
        miniFAT = miniFATEntries
        guard let rootMiniStreamSize = Int(exactly: root.size) else {
            throw CompoundFileError.invalid("The root mini stream is too large.")
        }
        rootMiniStream = try Self.readRegularChain(start: root.startSector,
                                                   expectedSize: rootMiniStreamSize, fat: fat,
                                                   data: data, sectorSize: sectorSize,
                                                   sectorCount: sectorCount)
    }

    func stream(named name: String) throws -> Data? {
        guard let entry = rootStreams[name] else { return nil }
        guard let size = Int(exactly: entry.size) else { throw CompoundFileError.invalid("The stream is too large.") }
        guard size > 0 else { return Data() }
        if entry.size < 4096 {
            let bytes = try Self.readMiniChain(start: entry.startSector, size: size, miniFAT: miniFAT,
                                               miniStream: rootMiniStream, miniSectorSize: miniSectorSize)
            return bytes
        }
        return try Self.readRegularChain(start: entry.startSector, expectedSize: size, fat: fat,
                                         data: data, sectorSize: sectorSize, sectorCount: sectorCount)
    }

    private static func readDIFAT(_ data: Data, sectorSize: Int, sectorCount: Int,
                                  firstSector: UInt32, sectorCountInChain: Int,
                                  expectedFATSectors: Int) throws -> [UInt32] {
        var fatIDs: [UInt32] = []
        for offset in stride(from: 76, to: 512, by: 4) {
            let id = try readUInt32(data, at: offset)
            if id != freeSector { fatIDs.append(id) }
        }
        var seenDIFAT: Set<UInt32> = []
        var current = firstSector
        let valuesPerSector = sectorSize / 4 - 1
        for _ in 0..<sectorCountInChain {
            guard current <= maxRegularSector, Int(current) < sectorCount, seenDIFAT.insert(current).inserted else {
                throw CompoundFileError.corruptChain
            }
            let bytes = try Self.sector(data, id: current, size: sectorSize, count: sectorCount)
            for offset in stride(from: 0, to: valuesPerSector * 4, by: 4) {
                let id = try readUInt32(bytes, at: offset)
                if id != freeSector { fatIDs.append(id) }
            }
            current = try readUInt32(bytes, at: valuesPerSector * 4)
        }
        guard (sectorCountInChain == 0 && (firstSector == endOfChain || firstSector == freeSector)) || current == endOfChain,
              fatIDs.count == expectedFATSectors, Set(fatIDs).count == fatIDs.count else {
            throw CompoundFileError.corruptChain
        }
        for id in fatIDs {
            guard id <= maxRegularSector, Int(id) < sectorCount else { throw CompoundFileError.corruptChain }
        }
        return fatIDs
    }

    private static func parseDirectory(_ bytes: Data, majorVersion: UInt16) throws -> [DirectoryEntry] {
        guard bytes.count % 128 == 0 else { throw CompoundFileError.corruptChain }
        var entries: [DirectoryEntry] = []
        for offset in stride(from: 0, to: bytes.count, by: 128) {
            let type = bytes[offset + 66]
            if type == 0 {
                entries.append(DirectoryEntry(name: "", type: 0, left: 0xFFFFFFFF, right: 0xFFFFFFFF,
                                              child: 0xFFFFFFFF, startSector: endOfChain, size: 0))
                continue
            }
            guard type == 1 || type == 2 || type == 5 else { throw CompoundFileError.invalid("The directory contains an invalid entry type.") }
            let nameLength = Int(try readUInt16(bytes, at: offset + 64))
            guard nameLength >= 2, nameLength <= 64, nameLength % 2 == 0 else { throw CompoundFileError.invalid("A directory entry name is invalid.") }
            var units: [UInt16] = []
            for nameOffset in stride(from: 0, to: nameLength - 2, by: 2) {
                units.append(try readUInt16(bytes, at: offset + nameOffset))
            }
            guard let name = String(utf16CodeUnits: units, count: units.count).nilIfEmpty else {
                throw CompoundFileError.invalid("A directory entry name is empty.")
            }
            let rawSize = try readUInt64(bytes, at: offset + 120)
            let size = majorVersion == 3 ? rawSize & 0xFFFFFFFF : rawSize
            entries.append(DirectoryEntry(name: name, type: type,
                                          left: try readUInt32(bytes, at: offset + 68),
                                          right: try readUInt32(bytes, at: offset + 72),
                                          child: try readUInt32(bytes, at: offset + 76),
                                          startSector: try readUInt32(bytes, at: offset + 116),
                                          size: size))
        }
        return entries
    }

    private static func readRootStreams(entries: [DirectoryEntry], root: DirectoryEntry) throws -> [String: DirectoryEntry] {
        var streams: [String: DirectoryEntry] = [:]
        var visited: Set<UInt32> = []
        var pending = root.child == freeSector ? [] : [root.child]
        while let index = pending.popLast() {
            guard Int(index) < entries.count, visited.insert(index).inserted else { throw CompoundFileError.corruptChain }
            let entry = entries[Int(index)]
            guard entry.type == 1 || entry.type == 2 else { throw CompoundFileError.corruptChain }
            if entry.left != freeSector { pending.append(entry.left) }
            if entry.right != freeSector { pending.append(entry.right) }
            if entry.type == 2 {
                guard streams[entry.name] == nil else { throw CompoundFileError.invalid("The root directory contains duplicate stream names.") }
                streams[entry.name] = entry
            }
        }
        return streams
    }

    private static func readRegularChain(start: UInt32, expectedSize: Int?, fat: [UInt32], data: Data,
                                         sectorSize: Int, sectorCount: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        guard start <= maxRegularSector else { throw CompoundFileError.corruptChain }
        var output = Data()
        var current = start
        var seen: Set<UInt32> = []
        let expectedSectors = expectedSize.map { $0 / sectorSize + ($0 % sectorSize == 0 ? 0 : 1) }
        while current <= maxRegularSector {
            guard Int(current) < sectorCount, Int(current) < fat.count, seen.insert(current).inserted else {
                throw CompoundFileError.corruptChain
            }
            output.append(try sector(data, id: current, size: sectorSize, count: sectorCount))
            current = fat[Int(current)]
            if let expectedSectors, seen.count == expectedSectors {
                guard current == endOfChain else { throw CompoundFileError.corruptChain }
                break
            }
        }
        if let expectedSectors {
            guard seen.count == expectedSectors else { throw CompoundFileError.corruptChain }
            if let expectedSize { output = output.prefix(expectedSize).withData }
        } else {
            guard current == endOfChain else { throw CompoundFileError.corruptChain }
        }
        return output
    }

    private static func readMiniChain(start: UInt32, size: Int, miniFAT: [UInt32], miniStream: Data,
                                      miniSectorSize: Int) throws -> Data {
        let expectedCount = size / miniSectorSize + (size % miniSectorSize == 0 ? 0 : 1)
        var output = Data()
        var current = start
        var seen: Set<UInt32> = []
        while current <= maxRegularSector && seen.count < expectedCount {
            guard Int(current) < miniFAT.count, seen.insert(current).inserted else { throw CompoundFileError.corruptChain }
            let startOffset = Int(current) * miniSectorSize
            guard startOffset <= miniStream.count, miniSectorSize <= miniStream.count - startOffset else {
                throw CompoundFileError.corruptChain
            }
            output.append(miniStream.subdata(in: startOffset..<(startOffset + miniSectorSize)))
            current = miniFAT[Int(current)]
        }
        guard seen.count == expectedCount, current == endOfChain else { throw CompoundFileError.corruptChain }
        return output.prefix(size).withData
    }

    private static func sector(_ data: Data, id: UInt32, size: Int, count: Int) throws -> Data {
        guard id <= maxRegularSector, Int(id) < count else { throw CompoundFileError.truncated }
        let (offset, overflow) = (Int(id) + 1).multipliedReportingOverflow(by: size)
        guard !overflow, offset <= data.count, size <= data.count - offset else { throw CompoundFileError.truncated }
        return data.subdata(in: offset..<(offset + size))
    }

    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count, 2 <= data.count - offset else { throw CompoundFileError.truncated }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        UInt32(try readUInt16(data, at: offset)) | (UInt32(try readUInt16(data, at: offset + 2)) << 16)
    }

    private static func readUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
        UInt64(try readUInt32(data, at: offset)) | (UInt64(try readUInt32(data, at: offset + 4)) << 32)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Data.SubSequence {
    var withData: Data { Data(self) }
}
