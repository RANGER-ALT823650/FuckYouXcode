import Compression
import Foundation
import Testing
@testable import FuckYouXcode

struct MDictCompatFormatTests {
    @Test func headerProfileMappingRespectsStripAndCaseFlags() {
        let profile = MDXParser.normalizationProfile(
            from: [
                "StripKey": "Yes",
                "KeyCaseSensitive": "1"
            ]
        )

        #expect(profile.stripKey == true)
        #expect(profile.keyCaseSensitive == true)
    }

    @Test func encryptedMdxReportsUnsupportedError() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("encrypted_test_\(UUID().uuidString).mdx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let headerText = #"<Dictionary GeneratedByEngineVersion="2.0" Encoding="UTF-8" Encrypted="Yes" StripKey="No" KeyCaseSensitive="No"></Dictionary>"#
        var headerBytes = Data(headerText.utf8)
        headerBytes.append(0x00)

        var payload = Data()
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(headerBytes.count).bigEndian, Array.init))
        payload.append(headerBytes)
        payload.append(contentsOf: withUnsafeBytes(of: MDictCodec.adler32(headerBytes).littleEndian, Array.init))

        try payload.write(to: tempURL, options: .atomic)

        let parser = MDXParser()
        do {
            _ = try parser.parse(fileURL: tempURL)
            Issue.record("Expected parser to throw unsupported encryption error")
        } catch let error as MDictParserError {
            if case .unsupported = error {
                #expect(true)
            } else {
                Issue.record("Unexpected parser error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error.localizedDescription)")
        }
    }

    @Test func encryptedKeywordIndexMdxIsSupported() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("encrypted_index_test_\(UUID().uuidString).mdx")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try makeEncryptedKeywordIndexMDX(
            at: tempURL,
            entryKey: "hello",
            html: "<div>Hello HTML</div>"
        )

        let parser = MDXParser()
        let parsed = try parser.parse(fileURL: tempURL)

        #expect(parsed.entries.count == 1)
        #expect(parsed.entries.first?.key == "hello")
        #expect(parsed.entries.first?.html.contains("Hello HTML") == true)
    }

    @Test func zlibDecoderSupportsStandardStream() throws {
        // zlib("hello") = 0x78 0x9c cb 48 cd c9 c9 07 00 06 2c 02 15
        let compressed = Data([
            0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07,
            0x00, 0x06, 0x2c, 0x02, 0x15
        ])
        let decompressed = try MDictCodec.decompressZlib(compressed)
        #expect(String(data: decompressed, encoding: .utf8) == "hello")
    }

    @Test func zlibDecoderReportsMDictDecodeErrorForInvalidData() {
        let invalid = Data([0x78, 0x9c, 0x00, 0x01, 0x02, 0x03])
        do {
            _ = try MDictCodec.decompressZlib(invalid)
            Issue.record("Expected invalid zlib payload to fail")
        } catch let error as MDictParserError {
            if case .decodeFailed = error {
                #expect(true)
            } else {
                Issue.record("Unexpected parser error: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error.localizedDescription)")
        }
    }

    private func makeEncryptedKeywordIndexMDX(
        at url: URL,
        entryKey: String,
        html: String
    ) throws {
        let numberWidth = 8
        let header = #"<Dictionary GeneratedByEngineVersion="2.0" Encoding="UTF-8" Encrypted="2" StripKey="No" KeyCaseSensitive="No"></Dictionary>"#
        var headerBytes = Data(header.utf8)
        headerBytes.append(0x00)

        var keyPayload = Data()
        keyPayload += packedUInt(0, width: numberWidth)
        keyPayload += Data(entryKey.utf8)
        keyPayload += Data([0x00])
        let keyBlockCompressed = makeStoredBlock(from: keyPayload)

        var keyInfoRaw = Data()
        keyInfoRaw += packedUInt(1, width: numberWidth)
        keyInfoRaw += packedUInt(1, width: 2)
        keyInfoRaw += Data("a".utf8)
        keyInfoRaw += Data([0x00])
        keyInfoRaw += packedUInt(1, width: 2)
        keyInfoRaw += Data("a".utf8)
        keyInfoRaw += Data([0x00])
        keyInfoRaw += packedUInt(UInt64(keyBlockCompressed.count), width: numberWidth)
        keyInfoRaw += packedUInt(UInt64(keyPayload.count), width: numberWidth)

        let keyInfoCompressedBody = try compressZlib(keyInfoRaw)
        let keyInfoChecksum = MDictCodec.adler32(keyInfoRaw)
        let keyInfoEncryptedBody = try encryptKeywordIndexPayload(
            keyInfoCompressedBody,
            checksum: keyInfoChecksum
        )
        var keyInfoCompressed = Data([0x02, 0x00, 0x00, 0x00])
        keyInfoCompressed += packedUInt(UInt64(keyInfoChecksum), width: 4)
        keyInfoCompressed += keyInfoEncryptedBody

        var numbersBlock = Data()
        numbersBlock += packedUInt(1, width: numberWidth)
        numbersBlock += packedUInt(1, width: numberWidth)
        numbersBlock += packedUInt(UInt64(keyInfoRaw.count), width: numberWidth)
        numbersBlock += packedUInt(UInt64(keyInfoCompressed.count), width: numberWidth)
        numbersBlock += packedUInt(UInt64(keyBlockCompressed.count), width: numberWidth)

        let recordPayload = Data(html.utf8)
        let recordBlockCompressed = makeStoredBlock(from: recordPayload)

        var recordHeader = Data()
        recordHeader += packedUInt(1, width: numberWidth)
        recordHeader += packedUInt(1, width: numberWidth)
        recordHeader += packedUInt(16, width: numberWidth)
        recordHeader += packedUInt(UInt64(recordBlockCompressed.count), width: numberWidth)
        recordHeader += packedUInt(UInt64(recordBlockCompressed.count), width: numberWidth)
        recordHeader += packedUInt(UInt64(recordPayload.count), width: numberWidth)

        var fileData = Data()
        fileData += packedUInt(UInt64(headerBytes.count), width: 4)
        fileData += headerBytes
        fileData += packedUInt(UInt64(MDictCodec.adler32(headerBytes)), width: 4, littleEndian: true)
        fileData += numbersBlock
        fileData += packedUInt(UInt64(MDictCodec.adler32(numbersBlock)), width: 4)
        fileData += keyInfoCompressed
        fileData += keyBlockCompressed
        fileData += recordHeader
        fileData += recordBlockCompressed

        try fileData.write(to: url, options: .atomic)
    }

    private func encryptKeywordIndexPayload(
        _ plaintext: Data,
        checksum: UInt32
    ) throws -> Data {
        let checksumBytes = packedUInt(UInt64(checksum), width: 4)
        return try MDictCodec.encryptKeywordIndexPayload(
            plaintext,
            checksumBytes: checksumBytes
        )
    }

    private func compressZlib(_ input: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk {
                output.append(chunk)
            }
        }
        _ = try filter.write(input)
        try filter.finalize()
        return output
    }

    private func makeStoredBlock(from payload: Data) -> Data {
        packedUInt(0, width: 4, littleEndian: true)
            + packedUInt(UInt64(MDictCodec.adler32(payload)), width: 4)
            + payload
    }

    private func packedUInt(_ value: UInt64, width: Int, littleEndian: Bool = false) -> Data {
        var data = Data(count: width)
        for offset in 0..<width {
            let index = littleEndian ? offset : (width - 1 - offset)
            let byte = UInt8((value >> (offset * 8)) & 0xFF)
            data[index] = byte
        }
        return data
    }
}
