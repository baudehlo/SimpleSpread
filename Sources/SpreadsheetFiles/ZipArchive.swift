import Foundation
import Compression

/// Minimal ZIP (PKZIP) container support — exactly what XLSX needs:
/// stored + deflate entries, correct CRC-32, no data descriptors, no ZIP64.
public enum ZipError: Error, Equatable {
    case notAZipFile
    case corrupt(String)
    case unsupported(String)
    case entryNotFound(String)
}

public struct ZipEntry: Sendable {
    public let name: String
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let crc32: UInt32
    public let compressionMethod: UInt16
    let localHeaderOffset: Int
}

// MARK: - CRC-32 (IEEE, reflected 0xEDB88320)

enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Raw DEFLATE via the Compression framework

enum Deflate {
    /// Raw deflate (COMPRESSION_ZLIB in the Compression framework is
    /// headerless DEFLATE — exactly the ZIP entry format). Returns nil when
    /// compression doesn't shrink the data.
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0, written < data.count else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }

    static func decompress(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        guard !data.isEmpty else { throw ZipError.corrupt("empty deflate stream") }
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else {
            throw ZipError.corrupt("deflate stream truncated (\(written)/\(uncompressedSize))")
        }
        return output
    }
}

// MARK: - Reader

public struct ZipArchiveReader {
    public let entries: [ZipEntry]
    private let data: Data
    private let entriesByName: [String: Int]

    public init(data: Data) throws {
        self.data = data
        // Encrypted Office files are CFB containers, not ZIPs.
        if data.count >= 8, data.prefix(8) == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            throw ZipError.unsupported("encrypted or legacy .xls file")
        }
        guard data.count >= 22 else { throw ZipError.notAZipFile }

        // Locate End Of Central Directory: scan backward (comment <= 64KB).
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var eocdOffset = -1
        let scanStart = max(0, data.count - 22 - 65536)
        var i = data.count - 22
        while i >= scanStart {
            if data[i] == eocdSig[0], data[i + 1] == eocdSig[1],
               data[i + 2] == eocdSig[2], data[i + 3] == eocdSig[3] {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.notAZipFile }

        func u16(_ offset: Int) throws -> Int {
            guard offset + 2 <= data.count else { throw ZipError.corrupt("truncated") }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset + 4 <= data.count else { throw ZipError.corrupt("truncated") }
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }

        let entryCount = try u16(eocdOffset + 10)
        let cdOffset = Int(try u32(eocdOffset + 16))
        guard cdOffset != 0xFFFFFFFF else { throw ZipError.unsupported("ZIP64 archives") }

        var parsed: [ZipEntry] = []
        var byName: [String: Int] = [:]
        var pos = cdOffset
        for _ in 0..<entryCount {
            guard try u32(pos) == 0x02014b50 else { throw ZipError.corrupt("bad central directory signature") }
            let method = UInt16(try u16(pos + 10))
            let crc = try u32(pos + 16)
            let compSize = Int(try u32(pos + 20))
            let uncompSize = Int(try u32(pos + 24))
            let nameLen = try u16(pos + 28)
            let extraLen = try u16(pos + 30)
            let commentLen = try u16(pos + 32)
            let localOffset = Int(try u32(pos + 42))
            guard compSize != 0xFFFFFFFF, uncompSize != 0xFFFFFFFF, localOffset != 0xFFFFFFFF else {
                throw ZipError.unsupported("ZIP64 entries")
            }
            guard pos + 46 + nameLen <= data.count else { throw ZipError.corrupt("truncated name") }
            let nameData = data.subdata(in: (pos + 46)..<(pos + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            let entry = ZipEntry(name: name, compressedSize: compSize,
                                 uncompressedSize: uncompSize, crc32: crc,
                                 compressionMethod: method, localHeaderOffset: localOffset)
            byName[name] = parsed.count
            parsed.append(entry)
            pos += 46 + nameLen + extraLen + commentLen
        }
        entries = parsed
        entriesByName = byName
    }

    public func entry(named name: String) -> ZipEntry? {
        if let idx = entriesByName[name] { return entries[idx] }
        // Defensive case-insensitive fallback.
        return entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func contents(of entry: ZipEntry) throws -> Data {
        // Read the local header to find where the payload starts (central
        // directory sizes are authoritative; local ones may be zeroed by
        // data-descriptor writers).
        let p = entry.localHeaderOffset
        func u16(_ offset: Int) throws -> Int {
            guard offset + 2 <= data.count else { throw ZipError.corrupt("truncated local header") }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset + 4 <= data.count else { throw ZipError.corrupt("truncated local header") }
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        guard try u32(p) == 0x04034b50 else { throw ZipError.corrupt("bad local header signature") }
        let nameLen = try u16(p + 26)
        let extraLen = try u16(p + 28)
        let start = p + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= data.count else {
            throw ZipError.corrupt("entry payload out of bounds")
        }
        let payload = data.subdata(in: start..<(start + entry.compressedSize))
        let raw: Data
        switch entry.compressionMethod {
        case 0:
            raw = payload
        case 8:
            raw = try Deflate.decompress(payload, uncompressedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupported("compression method \(entry.compressionMethod)")
        }
        guard CRC32.checksum(raw) == entry.crc32 else {
            throw ZipError.corrupt("CRC mismatch in \(entry.name)")
        }
        return raw
    }

    public func contents(named name: String) throws -> Data {
        guard let e = entry(named: name) else { throw ZipError.entryNotFound(name) }
        return try contents(of: e)
    }
}

// MARK: - Writer

public struct ZipArchiveWriter {
    private struct PendingEntry {
        let name: String
        let payload: Data
        let method: UInt16
        let crc: UInt32
        let uncompressedSize: Int
    }

    private var pending: [PendingEntry] = []

    public init() {}

    /// Add a file. Entry names use forward slashes with no leading slash.
    public mutating func addEntry(name: String, data: Data) {
        let crc = CRC32.checksum(data)
        if let compressed = Deflate.compress(data) {
            pending.append(PendingEntry(name: name, payload: compressed, method: 8,
                                        crc: crc, uncompressedSize: data.count))
        } else {
            pending.append(PendingEntry(name: name, payload: data, method: 0,
                                        crc: crc, uncompressedSize: data.count))
        }
    }

    public func finalize() -> Data {
        var out = Data()
        var centralDirectory = Data()

        func append16(_ v: Int, to data: inout Data) {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8((v >> 8) & 0xFF))
        }
        func append32(_ v: UInt32, to data: inout Data) {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8((v >> 8) & 0xFF))
            data.append(UInt8((v >> 16) & 0xFF))
            data.append(UInt8((v >> 24) & 0xFF))
        }

        // Fixed DOS timestamp: 2020-01-01 00:00 (consumers ignore it).
        let dosTime = 0
        let dosDate = (40 << 9) | (1 << 5) | 1

        for entry in pending {
            let nameBytes = Data(entry.name.utf8)
            let localOffset = UInt32(out.count)

            // Local file header
            append32(0x04034b50, to: &out)
            append16(20, to: &out)                    // version needed
            append16(0, to: &out)                     // flags (no data descriptor)
            append16(Int(entry.method), to: &out)
            append16(dosTime, to: &out)
            append16(dosDate, to: &out)
            append32(entry.crc, to: &out)
            append32(UInt32(entry.payload.count), to: &out)
            append32(UInt32(entry.uncompressedSize), to: &out)
            append16(nameBytes.count, to: &out)
            append16(0, to: &out)                     // extra length
            out.append(nameBytes)
            out.append(entry.payload)

            // Central directory header
            append32(0x02014b50, to: &centralDirectory)
            append16(20, to: &centralDirectory)       // version made by
            append16(20, to: &centralDirectory)       // version needed
            append16(0, to: &centralDirectory)        // flags
            append16(Int(entry.method), to: &centralDirectory)
            append16(dosTime, to: &centralDirectory)
            append16(dosDate, to: &centralDirectory)
            append32(entry.crc, to: &centralDirectory)
            append32(UInt32(entry.payload.count), to: &centralDirectory)
            append32(UInt32(entry.uncompressedSize), to: &centralDirectory)
            append16(nameBytes.count, to: &centralDirectory)
            append16(0, to: &centralDirectory)        // extra
            append16(0, to: &centralDirectory)        // comment
            append16(0, to: &centralDirectory)        // disk start
            append16(0, to: &centralDirectory)        // internal attrs
            append32(0, to: &centralDirectory)        // external attrs
            append32(localOffset, to: &centralDirectory)
            centralDirectory.append(nameBytes)
        }

        let cdOffset = UInt32(out.count)
        out.append(centralDirectory)

        // End of central directory
        append32(0x06054b50, to: &out)
        append16(0, to: &out)                          // disk number
        append16(0, to: &out)                          // cd disk
        append16(pending.count, to: &out)
        append16(pending.count, to: &out)
        append32(UInt32(centralDirectory.count), to: &out)
        append32(cdOffset, to: &out)
        append16(0, to: &out)                          // comment length
        return out
    }
}
