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
        let archive = writer.finalize()

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
        let archive = writer.finalize()
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
        let reader = try ZipArchiveReader(data: writer.finalize())
        #expect(try reader.contents(named: "bin.dat") == bytes)
    }

    @Test func missingEntryThrows() throws {
        var writer = ZipArchiveWriter()
        writer.addEntry(name: "a.txt", data: Data("x".utf8))
        let reader = try ZipArchiveReader(data: writer.finalize())
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
        var archive = writer.finalize()
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
        let reader = try ZipArchiveReader(data: writer.finalize())
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
