import Foundation
import Compression
import zlib

/// Minimal ZIP (PKZIP) container support — exactly what XLSX needs:
/// stored + deflate entries, correct CRC-32, no data descriptors, no ZIP64
/// (so no entry or archive of 4 GiB or more, and at most 65,534 entries).
public enum ZipError: Error, Equatable, LocalizedError {
    case notAZipFile
    case corrupt(String)
    case unsupported(String)
    case entryNotFound(String)
    /// Over a size limit: a part too big for the ZIP format to write, or an
    /// archive whose contents would inflate beyond what is believable.
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .notAZipFile: return "The file is not a valid workbook (it is not a ZIP package)."
        case .corrupt(let detail): return "The file is damaged (\(detail))."
        case .unsupported(let detail): return "This kind of file is not supported (\(detail))."
        case .entryNotFound(let name): return "The file is missing a part it needs (\(name))."
        case .tooLarge(let detail): return detail
        }
    }
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

/// zlib's crc32 (part of macOS), which is many times faster than a table
/// loop on the hundreds of megabytes a big sheet inflates to.
enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            guard var p = raw.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            var remaining = raw.count
            var crc = zlib.crc32(0, nil, 0)
            // zlib takes 32-bit lengths.
            while remaining > 0 {
                let chunk = min(remaining, 1 << 30)
                crc = zlib.crc32(crc, p, uInt(chunk))
                p += chunk
                remaining -= chunk
            }
            return UInt32(crc)
        }
    }
}

// MARK: - Raw DEFLATE (zlib to compress, the Compression framework to inflate)

enum Deflate {
    /// Raw deflate with zlib at its default level. Large data is compressed
    /// in 1 MB chunks on all cores, pigz-style: each chunk is primed with
    /// the 32 KB before it and ends on a byte boundary (a sync flush), so
    /// the pieces join into one ordinary deflate stream. Returns nil when
    /// compression doesn't shrink the data.
    static func compress(_ data: Data) -> Data? {
        compress(data, progress: { _ in })
    }

    /// As above, calling `progress` with the fraction of chunks done after
    /// each batch of chunks (a few per core, so the cores stay busy); it
    /// throws to stop.
    static func compress(_ data: Data, batchSize: Int? = nil,
                         progress: (Double) throws -> Void) rethrows -> Data? {
        guard !data.isEmpty else { return nil }
        let chunkSize = 1 << 20
        let chunkCount = (data.count + chunkSize - 1) / chunkSize
        let batchSize = max(1, batchSize ?? ProcessInfo.processInfo.activeProcessorCount * 4)
        var pieces = [Data?](repeating: nil, count: chunkCount)
        let failed = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let results = UnsafeMutableBufferPointer<Data?>.allocate(capacity: chunkCount)
            results.initialize(repeating: nil)
            defer {
                results.deinitialize()
                results.deallocate()
            }
            let job = ChunkJob(input: raw.bindMemory(to: Bytef.self), results: results,
                               chunkSize: chunkSize, chunkCount: chunkCount)
            var next = 0
            while next < chunkCount {
                let first = next, count = min(batchSize, chunkCount - next)
                if count == 1 {
                    job.compress(chunk: first)
                } else {
                    DispatchQueue.concurrentPerform(iterations: count) { job.compress(chunk: first + $0) }
                }
                next += count
                try progress(Double(next) / Double(chunkCount))
            }
            for i in 0..<chunkCount { pieces[i] = results[i] }
            return pieces.contains { $0 == nil }
        }
        guard !failed else { return nil }
        let total = pieces.reduce(0) { $0 + $1!.count }
        guard total < data.count else { return nil }
        var output = Data(capacity: total)
        for piece in pieces { output.append(piece!) }
        return output
    }

    /// The chunks of one `compress`, shared by the worker threads. Unchecked
    /// Sendable: each thread only reads `input` and writes its own slot of
    /// `results`, and both buffers outlive `concurrentPerform`, which
    /// returns only once every chunk is done.
    private struct ChunkJob: @unchecked Sendable {
        let input: UnsafeBufferPointer<Bytef>
        let results: UnsafeMutableBufferPointer<Data?>
        let chunkSize: Int
        let chunkCount: Int

        func compress(chunk index: Int) {
            guard let base = input.baseAddress else { return }
            let start = index * chunkSize
            let count = min(chunkSize, input.count - start)
            let primer = min(start, 32 * 1024)
            results[index] = Deflate.deflateChunk(base + start, count: count,
                                                  dictionary: base + start - primer, dictionaryCount: primer,
                                                  last: index == chunkCount - 1)
        }
    }

    /// Deflate one chunk at level 6. Every chunk but the last ends with a
    /// sync flush (byte-aligned, stream left open); the last finishes it.
    fileprivate static func deflateChunk(_ input: UnsafePointer<Bytef>, count: Int,
                                     dictionary: UnsafePointer<Bytef>, dictionaryCount: Int,
                                     last: Bool) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        if dictionaryCount > 0,
           deflateSetDictionary(&stream, dictionary, uInt(dictionaryCount)) != Z_OK { return nil }
        // Room for the worst case plus the flush marker.
        let capacity = Int(deflateBound(&stream, uLong(count))) + 16
        var output = Data(count: capacity)
        let status = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(count)
            stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress!
            stream.avail_out = uInt(capacity)
            return deflate(&stream, last ? Z_FINISH : Z_SYNC_FLUSH)
        }
        guard last ? status == Z_STREAM_END : (status == Z_OK && stream.avail_in == 0) else { return nil }
        output.removeSubrange(Int(stream.total_out)..<output.count)
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
    /// What a package may inflate to. Entries are inflated whole, so these
    /// bound the memory a hostile file (a "ZIP bomb") can make a read take.
    public struct Limits: Sendable {
        /// Largest single entry (the format's own limit without ZIP64).
        public var maxEntrySize: Int
        /// All entries together, as declared in the central directory.
        public var maxTotalSize: Int
        /// Deflate tops out near 1032:1, and real workbook parts stay far
        /// below; a deflated entry over `ratioCheckSize` claiming more is refused.
        public var maxCompressionRatio: Int
        public var ratioCheckSize: Int

        public init(maxEntrySize: Int, maxTotalSize: Int, maxCompressionRatio: Int, ratioCheckSize: Int) {
            self.maxEntrySize = maxEntrySize
            self.maxTotalSize = maxTotalSize
            self.maxCompressionRatio = maxCompressionRatio
            self.ratioCheckSize = ratioCheckSize
        }

        public static let standard = Limits(maxEntrySize: Int(UInt32.max), maxTotalSize: 8 << 30,
                                            maxCompressionRatio: 1000, ratioCheckSize: 8 << 20)
    }

    public let entries: [ZipEntry]
    private let data: Data
    private let entriesByName: [String: Int]
    private let limits: Limits

    public init(data: Data, limits: Limits = .standard) throws {
        // Indices below assume the bytes start at 0 (a slice may not).
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data
        self.limits = limits
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
        var totalSize = 0
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
            totalSize += uncompSize
            guard totalSize <= limits.maxTotalSize else {
                throw ZipError.tooLarge("The file’s contents would take more than \(Self.size(limits.maxTotalSize)) to open.")
            }
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
        try checkLimits(entry)
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

    /// Refuse an entry before inflating it when its declared size is over
    /// the limits, or implausible for its compressed size.
    private func checkLimits(_ entry: ZipEntry) throws {
        guard entry.uncompressedSize <= limits.maxEntrySize else {
            throw ZipError.tooLarge("“\(entry.name)” would take more than \(Self.size(limits.maxEntrySize)) to open.")
        }
        if entry.compressionMethod == 8, entry.uncompressedSize > limits.ratioCheckSize,
           entry.uncompressedSize / max(1, entry.compressedSize) > limits.maxCompressionRatio {
            throw ZipError.tooLarge("“\(entry.name)” claims to expand more than \(limits.maxCompressionRatio) times, "
                                    + "which no real workbook does; the file may be damaged or malicious.")
        }
    }

    /// "4 GB", "512 MB".
    static func size(_ bytes: Int) -> String {
        bytes >= 1 << 30 ? "\((bytes + (1 << 29)) >> 30) GB" : "\((bytes + (1 << 19)) >> 20) MB"
    }

    public func contents(named name: String) throws -> Data {
        guard let e = entry(named: name) else { throw ZipError.entryNotFound(name) }
        return try contents(of: e)
    }
}

// MARK: - Writer

public struct ZipArchiveWriter {
    /// Sizes and offsets are 32-bit and the entry count 16-bit without
    /// ZIP64 (all-ones values would mean "see ZIP64").
    static let maxSize = Int(UInt32.max) - 1
    static let maxEntries = Int(UInt16.max) - 1

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
        addEntry(name: name, data: data, progress: { _ in })
    }

    /// As above; `progress` gets the fraction compressed and throws to stop.
    mutating func addEntry(name: String, data: Data, progress: (Double) throws -> Void) rethrows {
        let crc = CRC32.checksum(data)
        if let compressed = try Deflate.compress(data, progress: progress) {
            pending.append(PendingEntry(name: name, payload: compressed, method: 8,
                                        crc: crc, uncompressedSize: data.count))
        } else {
            pending.append(PendingEntry(name: name, payload: data, method: 0,
                                        crc: crc, uncompressedSize: data.count))
        }
    }

    /// The archive's bytes. Throws `ZipError.tooLarge` rather than write a
    /// broken file when an entry, the whole archive or the entry count is
    /// beyond what ZIP records without ZIP64 can describe.
    public func finalize() throws -> Data {
        try finalize(maxSize: Self.maxSize, maxEntries: Self.maxEntries)
    }

    /// `maxSize`/`maxEntries`: lowered by tests.
    func finalize(maxSize: Int, maxEntries: Int) throws -> Data {
        guard pending.count <= maxEntries else {
            throw ZipError.tooLarge("The workbook has too many parts to save (\(pending.count); the limit is \(maxEntries)).")
        }
        for entry in pending where entry.uncompressedSize > maxSize || entry.payload.count > maxSize {
            throw ZipError.tooLarge("“\(entry.name)” is too large to save (\(ZipArchiveReader.size(entry.uncompressedSize)); "
                                    + "an XLSX part is limited to 4 GB). Try splitting the data across sheets.")
        }
        let localBytes = pending.reduce(0) { $0 + 30 + $1.name.utf8.count + $1.payload.count }
        let directoryBytes = pending.reduce(0) { $0 + 46 + $1.name.utf8.count }
        guard localBytes + directoryBytes <= maxSize else {
            throw ZipError.tooLarge("The workbook is too large to save as one file (over 4 GB compressed). "
                                    + "Try splitting the data across workbooks.")
        }
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
