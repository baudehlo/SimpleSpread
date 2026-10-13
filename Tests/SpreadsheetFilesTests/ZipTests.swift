import Foundation
import Testing
@testable import SpreadsheetFiles

@Suite("ZIP container")
struct ZipTests {
    @Test func roundTripStoredAndDeflated() throws {
        var writer = ZipArchiveWriter()
        let small = Data("hi".utf8) // too small to compress -> stored
        let big = Data(String(repeating: "hello world ", count: 1000).utf8) // compresses
        writer.addEntry(name: "small.txt", data: small)
        writer.addEntry(name: "dir/big.txt", data: big)
        let archive = try writer.finalize()

        let reader = try ZipArchiveReader(data: archive)
        #expect(reader.entries.count == 2)
        #expect(try reader.contents(named: "small.txt") == small)
        #expect(try reader.contents(named: "dir/big.txt") == big)
        // Big entry actually got compressed.
        let bigEntry = reader.entry(named: "dir/big.txt")!
        #expect(bigEntry.compressionMethod == 8)
        #expect(bigEntry.compressedSize < big.count)
    }

    @Test func emptyFileEntry() throws {
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "empty.txt", data: Data())
        let archive = try writer.finalize()
        let reader = try ZipArchiveReader(data: archive)
        #expect(try reader.contents(named: "empty.txt") == Data())
    }

    @Test func binaryDataRoundTrip() throws {
        var bytes = Data()
        for i in 0..<10_000 {
            bytes.append(UInt8((i &* 31) & 0xFF))
        }
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "bin.dat", data: bytes)
        let reader = try ZipArchiveReader(data: try writer.finalize())
        #expect(try reader.contents(named: "bin.dat") == bytes)
    }

    @Test func missingEntryThrows() throws {
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "a.txt", data: Data("x".utf8))
        let reader = try ZipArchiveReader(data: try writer.finalize())
        #expect(throws: ZipError.self) {
            try reader.contents(named: "nope.txt")
        }
    }

    @Test func garbageDataRejected() {
        #expect(throws: ZipError.self) {
            _ = try ZipArchiveReader(data: Data("this is not a zip file at all!!".utf8))
        }
        #expect(throws: ZipError.self) {
            _ = try ZipArchiveReader(data: Data())
        }
    }

    @Test func cfbContainerRejectedClearly() {
        // Encrypted Office files start with the CFB magic.
        var data = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        data.append(Data(count: 100))
        #expect(throws: ZipError.unsupported("encrypted or legacy .xls file")) {
            _ = try ZipArchiveReader(data: data)
        }
    }

    @Test func crcValidation() throws {
        var writer = ZipArchiveWriter()
        let payload = Data("important data".utf8)
        writer.addEntry(name: "f.txt", data: payload)
        var archive = try writer.finalize()
        // Corrupt one payload byte (stored entry: payload directly after the
        // 30-byte local header + 5-byte name).
        archive[35] = archive[35] &+ 1
        let reader = try ZipArchiveReader(data: archive)
        #expect(throws: ZipError.self) {
            _ = try reader.contents(named: "f.txt")
        }
    }

    @Test func crc32KnownValues() {
        // Standard test vector: "123456789" -> 0xCBF43926
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func manyEntries() throws {
        var writer = ZipArchiveWriter()
        for i in 0..<200 {
            writer.addEntry(name: "file\(i).txt", data: Data("content \(i)".utf8))
        }
        let reader = try ZipArchiveReader(data: try writer.finalize())
        #expect(reader.entries.count == 200)
        #expect(try reader.contents(named: "file123.txt") == Data("content 123".utf8))
    }

    @Test func xmlEscaping() {
        #expect(XML.escapeText("a<b>&c") == "a&lt;b&gt;&amp;c")
        #expect(XML.escapeAttribute("say \"hi\"") == "say &quot;hi&quot;")
        #expect(XML.escapeText("keep\nnewline") == "keep\nnewline")
        #expect(XML.escapeText("drop\rcr") == "dropcr")
    }

    @Test func illegalCharacterEncoding() {
        let bell = "a\u{07}b"
        #expect(XML.encodeIllegalCharacters(bell) == "a_x0007_b")
        #expect(XML.decodeIllegalCharacters("a_x0007_b") == bell)
        // Literal "_x0007_" text must survive a round trip.
        let literal = "price_x0007_tag"
        let encoded = XML.encodeIllegalCharacters(literal)
        #expect(encoded == "price_x005F_x0007_tag")
        #expect(XML.decodeIllegalCharacters(encoded) == literal)
        // Tab and newline are legal and untouched.
        #expect(XML.encodeIllegalCharacters("a\tb\nc") == "a\tb\nc")
    }
}

@Suite("Parallel deflate")
struct ParallelDeflateTests {
    @Test func chunkedStreamInflatesToTheOriginal() throws {
        // Several chunks of compressible, varied text, plus odd sizes.
        var rng = SystemRandomNumberGenerator()
        for size in [1, 100, (1 << 20) - 1, 1 << 20, (1 << 20) + 1, 5 * (1 << 20) + 12345] {
            var bytes = [UInt8](repeating: 0, count: size)
            for i in 0..<size { bytes[i] = UInt8(ascii: "a") &+ UInt8((i / 7 + Int.random(in: 0...2, using: &rng)) % 26) }
            let data = Data(bytes)
            guard let compressed = Deflate.compress(data) else {
                #expect(size < 200) // tiny inputs may not shrink
                continue
            }
            #expect(compressed.count < data.count)
            #expect(try Deflate.decompress(compressed, uncompressedSize: data.count) == data)
        }
    }

    @Test func zipRoundTripOfABigEntry() throws {
        let text = String(repeating: "<row r=\"1\"><c r=\"A1\"><v>12345</v></c></row>", count: 120_000)
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "big.xml", data: Data(text.utf8))
        let reader = try ZipArchiveReader(data: try writer.finalize())
        #expect(try reader.contents(named: "big.xml") == Data(text.utf8))
    }
}

@Suite("ZIP limits")
struct ZipLimitTests {
    /// Patch a little-endian UInt32 into the archive.
    func put32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for k in 0..<4 { data[offset + k] = UInt8((value >> (8 * UInt32(k))) & 0xFF) }
    }

    /// Offset of the (last) central directory header.
    func centralDirectory(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        return (0..<(bytes.count - 4)).last {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x01 && bytes[$0 + 3] == 0x02
        }!
    }

    func isTooLarge(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch ZipError.tooLarge {
            return true
        } catch {
            return false
        }
    }

    @Test func aLyingSizeIsRefusedBeforeInflating() throws {
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "x.xml", data: Data(String(repeating: "abc", count: 2000).utf8))
        var archive = try writer.finalize()
        // Claim 3.9 GB uncompressed from a few hundred bytes.
        put32(3_900_000_000, at: centralDirectory(archive) + 24, in: &archive)
        let reader = try ZipArchiveReader(data: archive)
        #expect(isTooLarge { _ = try reader.contents(named: "x.xml") })
    }

    @Test func aBombIsRefused() throws {
        // Two MB of zeros deflates past 1000:1.
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "zeros", data: Data(count: 2 << 20))
        let archive = try writer.finalize()
        let strict = ZipArchiveReader.Limits(maxEntrySize: 1 << 30, maxTotalSize: 1 << 30,
                                             maxCompressionRatio: 1000, ratioCheckSize: 1 << 20)
        #expect(isTooLarge { _ = try ZipArchiveReader(data: archive, limits: strict).contents(named: "zeros") })
        // Under the standard limits it is below the size the ratio is checked at.
        #expect(try ZipArchiveReader(data: archive).contents(named: "zeros").count == 2 << 20)
    }

    @Test func entryAndTotalCaps() throws {
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "a", data: Data(repeating: 7, count: 5000))
        writer.addEntry(name: "b", data: Data(repeating: 8, count: 5000))
        let archive = try writer.finalize()
        let small = ZipArchiveReader.Limits(maxEntrySize: 4000, maxTotalSize: 1 << 20,
                                            maxCompressionRatio: 1000, ratioCheckSize: 1 << 20)
        #expect(isTooLarge { _ = try ZipArchiveReader(data: archive, limits: small).contents(named: "a") })
        let total = ZipArchiveReader.Limits(maxEntrySize: 1 << 20, maxTotalSize: 8000,
                                            maxCompressionRatio: 1000, ratioCheckSize: 1 << 20)
        #expect(isTooLarge { _ = try ZipArchiveReader(data: archive, limits: total) })
    }

    @Test func aSliceReads() throws {
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "a.txt", data: Data("hello".utf8))
        var padded = Data([1, 2, 3])
        padded.append(try writer.finalize())
        #expect(try ZipArchiveReader(data: padded[3...]).contents(named: "a.txt") == Data("hello".utf8))
    }

    @Test func oversizedArchivesThrowInsteadOfTrapping() throws {
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "big.bin", data: Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7919) }))
        #expect(isTooLarge { _ = try writer.finalize(maxSize: 4000, maxEntries: 10) })
        var many = ZipArchiveWriter()
        for i in 0..<5 { many.addEntry(name: "f\(i)", data: Data("x".utf8)) }
        #expect(isTooLarge { _ = try many.finalize(maxSize: 1 << 20, maxEntries: 4) })
        // Small entries adding up past the limit.
        var total = ZipArchiveWriter()
        var state: UInt64 = 42 // xorshift: incompressible bytes
        for i in 0..<10 {
            total.addEntry(name: "p\(i)", data: Data((0..<500).map { _ in
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return UInt8(truncatingIfNeeded: state)
            }))
        }
        #expect(isTooLarge { _ = try total.finalize(maxSize: 4000, maxEntries: 100) })
        #expect(try total.finalize(maxSize: 1 << 20, maxEntries: 100).count > 4000)
        // The message says what to do.
        #expect(ZipError.tooLarge("x").localizedDescription == "x")
    }
}
