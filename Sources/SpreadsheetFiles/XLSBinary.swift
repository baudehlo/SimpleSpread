import Foundation

enum XLSBinaryError: Error, LocalizedError, Equatable {
    case truncated
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .truncated: return "The XLS file is truncated."
        case .invalid(let message): return message
        }
    }
}

struct BIFFRecord {
    let type: UInt16
    let data: Data
}

struct BIFFRecordReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func next() throws -> BIFFRecord? {
        guard offset < data.count else { return nil }
        guard data.count - offset >= 4 else { throw XLSBinaryError.truncated }
        let type = try u16(at: offset)
        let length = Int(try u16(at: offset + 2))
        guard length <= data.count - offset - 4 else { throw XLSBinaryError.truncated }
        let start = offset + 4
        let payload = data.subdata(in: start..<(start + length))
        offset = start + length
        return BIFFRecord(type: type, data: payload)
    }

    func u8(at position: Int, in bytes: Data? = nil) throws -> UInt8 {
        let source = bytes ?? data
        guard position >= 0, position < source.count else { throw XLSBinaryError.truncated }
        return source[source.startIndex + position]
    }

    func u16(at position: Int, in bytes: Data? = nil) throws -> UInt16 {
        let a = UInt16(try u8(at: position, in: bytes))
        let b = UInt16(try u8(at: position + 1, in: bytes))
        return a | (b << 8)
    }

    func u32(at position: Int, in bytes: Data? = nil) throws -> UInt32 {
        UInt32(try u16(at: position, in: bytes)) | (UInt32(try u16(at: position + 2, in: bytes)) << 16)
    }

    func f64(at position: Int, in bytes: Data? = nil) throws -> Double {
        Double(bitPattern: try u64(at: position, in: bytes))
    }

    func u64(at position: Int, in bytes: Data? = nil) throws -> UInt64 {
        UInt64(try u32(at: position, in: bytes)) | (UInt64(try u32(at: position + 4, in: bytes)) << 32)
    }
}
