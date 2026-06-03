import Foundation
import zlib

enum MDictParserError: LocalizedError {
    case invalidFormat(String)
    case unsupported(String)
    case checksumMismatch(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidFormat(message):
            return "MDict 格式错误：\(message)"
        case let .unsupported(message):
            return "暂不支持该 MDict 特性：\(message)"
        case let .checksumMismatch(message):
            return "MDict 校验失败：\(message)"
        case let .decodeFailed(message):
            return "MDict 解码失败：\(message)"
        }
    }
}

struct MDXEntryRecord: Hashable {
    let key: String
    let html: String
}

struct MDXParseResult {
    let entries: [MDXEntryRecord]
    let normalizationProfile: DictionaryNormalizationProfile
    let header: [String: String]
}

struct MDXStreamSummary {
    let entryCount: Int
    let normalizationProfile: DictionaryNormalizationProfile
    let header: [String: String]
}

final class MDXParser {
    func parse(fileURL: URL) throws -> MDXParseResult {
        var entries: [MDXEntryRecord] = []
        let summary = try streamEntries(fileURL: fileURL) { entry in
            entries.append(entry)
        }

        return MDXParseResult(
            entries: entries,
            normalizationProfile: summary.normalizationProfile,
            header: summary.header
        )
    }

    func streamEntries(
        fileURL: URL,
        onMetadata: (([String: String], DictionaryNormalizationProfile) -> Void)? = nil,
        onEntry: @escaping (MDXEntryRecord) throws -> Void
    ) throws -> MDXStreamSummary {
        var entryCount = 0
        var headerAttributes: [String: String] = [:]
        var profile = DictionaryNormalizationProfile(stripKey: false, keyCaseSensitive: false)

        _ = try MDictBinaryParser(fileURL: fileURL, forceEncodingName: nil).enumerateDecodedRecords(
            onHeader: { header in
                headerAttributes = header.attributes
                profile = Self.normalizationProfile(from: header.attributes)
                onMetadata?(header.attributes, profile)
            },
            onRecord: { record in
                guard !record.key.isEmpty else { return }
                entryCount += 1
                try onEntry(MDXEntryRecord(key: record.key, html: record.data))
            }
        )

        return MDXStreamSummary(
            entryCount: entryCount,
            normalizationProfile: profile,
            header: headerAttributes
        )
    }

    static func boolValue(from raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "yes", "true", "on":
            return true
        default:
            return false
        }
    }

    static func normalizationProfile(from header: [String: String]) -> DictionaryNormalizationProfile {
        DictionaryNormalizationProfile(
            stripKey: boolValue(from: header["StripKey"]),
            keyCaseSensitive: boolValue(from: header["KeyCaseSensitive"])
        )
    }
}

struct MDictDecodedRecord {
    let key: String
    let data: String
}

struct MDictBinaryRecord {
    let key: String
    let data: Data
}

struct MDictContainerHeader {
    let attributes: [String: String]
    let version: Double
    let encodingName: String
    let textEncoding: String.Encoding
    let encryptFlag: Int
    let numberWidth: Int
}

struct MDictBinaryParseResult {
    let header: MDictContainerHeader
    let records: [MDictDecodedRecord]
}

struct MDictBinaryDataParseResult {
    let header: MDictContainerHeader
    let records: [MDictBinaryRecord]
}

final class MDictBinaryParser {
    private struct KeyItem {
        let offset: UInt64
        let key: String
    }

    private let fileURL: URL
    private let forceEncodingName: String?

    init(fileURL: URL, forceEncodingName: String?) {
        self.fileURL = fileURL
        self.forceEncodingName = forceEncodingName
    }

    func parseAllRecords() throws -> MDictBinaryParseResult {
        var decodedRecords: [MDictDecodedRecord] = []
        let header = try enumerateDecodedRecords { record in
            decodedRecords.append(record)
        }
        return MDictBinaryParseResult(header: header, records: decodedRecords)
    }

    func parseAllBinaryRecords() throws -> MDictBinaryDataParseResult {
        var records: [MDictBinaryRecord] = []
        let header = try enumerateBinaryRecords { record in
            records.append(record)
        }
        return MDictBinaryDataParseResult(header: header, records: records)
    }

    func enumerateDecodedRecords(
        onHeader: ((MDictContainerHeader) -> Void)? = nil,
        onRecord: @escaping (MDictDecodedRecord) throws -> Void
    ) throws -> MDictContainerHeader {
        var textEncoding: String.Encoding = .utf8

        return try enumerateBinaryRecords(
            onHeader: { header in
                textEncoding = header.textEncoding
                onHeader?(header)
            },
            onRecord: { [self] record in
                let text = self.decodeText(record.data, encoding: textEncoding)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}"))
                try onRecord(MDictDecodedRecord(key: record.key, data: text))
            }
        )
    }

    func enumerateBinaryRecords(
        onHeader: ((MDictContainerHeader) -> Void)? = nil,
        onRecord: @escaping (MDictBinaryRecord) throws -> Void
    ) throws -> MDictContainerHeader {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var cursor = MDictByteCursor(data: data)

        let headerBytesSize = try cursor.readUInt32BE()
        let headerBytes = try cursor.readData(count: Int(headerBytesSize))
        let headerChecksum = try cursor.readUInt32LE()

        let calculatedChecksum = MDictCodec.adler32(headerBytes)
        guard headerChecksum == calculatedChecksum else {
            throw MDictParserError.checksumMismatch("header adler32 mismatch")
        }

        let parsedHeader = try Self.parseHeader(
            headerBytes: headerBytes,
            forceEncodingName: forceEncodingName
        )

        let unsupportedEncryptionBits = parsedHeader.encryptFlag & ~0x3
        if unsupportedEncryptionBits != 0 {
            throw MDictParserError.unsupported("未知加密标记：\(parsedHeader.encryptFlag)")
        }

        // Encrypted=1 needs registration-key decryption, which is still unsupported.
        if (parsedHeader.encryptFlag & 0x1) != 0 {
            throw MDictParserError.unsupported("加密词典暂不支持（Encrypted=1）")
        }

        onHeader?(parsedHeader)

        let keys: [KeyItem]
        let recordBlockOffset: Int

        if parsedHeader.version >= 3 {
            let parsed = try parseKeysV3(cursor: &cursor, header: parsedHeader)
            keys = parsed.keys
            recordBlockOffset = parsed.recordBlockOffset
        } else {
            let parsed = try parseKeysV1V2(cursor: &cursor, header: parsedHeader)
            keys = parsed.keys
            recordBlockOffset = parsed.recordBlockOffset
        }

        cursor.seek(to: recordBlockOffset)

        if parsedHeader.version >= 3 {
            try parseRecordsV3Raw(
                cursor: &cursor,
                header: parsedHeader,
                keys: keys,
                onRecord: onRecord
            )
        } else {
            try parseRecordsV1V2Raw(
                cursor: &cursor,
                header: parsedHeader,
                keys: keys,
                onRecord: onRecord
            )
        }

        return parsedHeader
    }

    private static func parseHeader(
        headerBytes: Data,
        forceEncodingName: String?
    ) throws -> MDictContainerHeader {
        let headerText: String
        if headerBytes.count >= 2, headerBytes.suffix(2) == Data([0x00, 0x00]) {
            let body = headerBytes.dropLast(2)
            if let decoded = String(data: body, encoding: .utf16LittleEndian) {
                headerText = decoded
            } else if let decoded = String(data: body, encoding: .utf16) {
                headerText = decoded
            } else {
                throw MDictParserError.decodeFailed("header utf16 decode failed")
            }
        } else {
            let body = headerBytes.dropLast(1)
            guard let decoded = String(data: body, encoding: .utf8) else {
                throw MDictParserError.decodeFailed("header utf8 decode failed")
            }
            headerText = decoded
        }

        var attributes: [String: String] = [:]
        let pattern = #"(\w+)="(.*?)""#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let nsText = headerText as NSString
        for match in regex.matches(in: headerText, range: NSRange(location: 0, length: nsText.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let key = nsText.substring(with: match.range(at: 1))
            let rawValue = nsText.substring(with: match.range(at: 2))
            attributes[key] = Self.unescape(rawValue)
        }

        let version = Double(attributes["GeneratedByEngineVersion"] ?? "") ?? 0
        guard version > 0 else {
            throw MDictParserError.invalidFormat("missing GeneratedByEngineVersion")
        }

        var encodingName = forceEncodingName ?? attributes["Encoding"] ?? "UTF-8"
        if encodingName.caseInsensitiveCompare("GBK") == .orderedSame
            || encodingName.caseInsensitiveCompare("GB2312") == .orderedSame {
            encodingName = "GB18030"
        }
        if version >= 3 {
            encodingName = "UTF-8"
        }

        guard let textEncoding = Self.textEncoding(from: encodingName) else {
            throw MDictParserError.unsupported("encoding \(encodingName) not supported")
        }

        let encryptedRaw = attributes["Encrypted"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let encryptFlag: Int
        if encryptedRaw == nil || encryptedRaw?.caseInsensitiveCompare("No") == .orderedSame {
            encryptFlag = 0
        } else if encryptedRaw?.caseInsensitiveCompare("Yes") == .orderedSame {
            encryptFlag = 1
        } else {
            encryptFlag = Int(encryptedRaw ?? "") ?? 0
        }

        let numberWidth = version < 2 ? 4 : 8

        return MDictContainerHeader(
            attributes: attributes,
            version: version,
            encodingName: encodingName,
            textEncoding: textEncoding,
            encryptFlag: encryptFlag,
            numberWidth: numberWidth
        )
    }

    private static func unescape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func textEncoding(from name: String) -> String.Encoding? {
        let normalized = name.uppercased()
        if normalized == "UTF-8" { return .utf8 }
        if normalized == "UTF-16" || normalized == "UTF-16LE" { return .utf16LittleEndian }
        if normalized == "UTF-16BE" { return .utf16BigEndian }

        let cfName = name as CFString
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(cfName)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }

        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private func parseKeysV1V2(
        cursor: inout MDictByteCursor,
        header: MDictContainerHeader
    ) throws -> (keys: [KeyItem], recordBlockOffset: Int) {
        let numbersByteCount = header.version >= 2 ? 8 * 5 : 4 * 4
        let numbersBlock = try cursor.readData(count: numbersByteCount)

        var numberCursor = MDictByteCursor(data: numbersBlock)
        let numKeyBlocks = try numberCursor.readNumber(width: header.numberWidth)
        _ = try numberCursor.readNumber(width: header.numberWidth)
        if header.version >= 2 {
            _ = try numberCursor.readNumber(width: header.numberWidth)
        }
        let keyBlockInfoSize = try numberCursor.readNumber(width: header.numberWidth)
        let keyBlockSize = try numberCursor.readNumber(width: header.numberWidth)

        if header.version >= 2 {
            let adler = try cursor.readUInt32BE()
            let calc = MDictCodec.adler32(numbersBlock)
            guard adler == calc else {
                throw MDictParserError.checksumMismatch("key block header checksum mismatch")
            }
        }

        let keyBlockInfoData = try cursor.readData(count: Int(keyBlockInfoSize))
        let keyBlockInfoList = try decodeKeyBlockInfo(
            keyBlockInfoData,
            header: header
        )

        guard UInt64(keyBlockInfoList.count) == numKeyBlocks else {
            throw MDictParserError.invalidFormat("key block count mismatch")
        }

        let keyBlockCompressed = try cursor.readData(count: Int(keyBlockSize))
        let keys = try decodeKeyBlocks(
            keyBlockCompressed,
            infoList: keyBlockInfoList,
            header: header
        )

        return (keys, cursor.position)
    }

    private func parseKeysV3(
        cursor: inout MDictByteCursor,
        header: MDictContainerHeader
    ) throws -> (keys: [KeyItem], recordBlockOffset: Int) {
        var recordBlockOffset: Int?
        var keyDataOffset: Int?

        while !cursor.isAtEnd {
            let blockType = try cursor.readUInt32BE()
            let blockSize = try cursor.readNumber(width: header.numberWidth)
            let blockOffset = cursor.position

            switch blockType {
            case 0x01000000:
                recordBlockOffset = blockOffset
            case 0x03000000:
                keyDataOffset = blockOffset
            case 0x02000000, 0x04000000:
                break
            default:
                throw MDictParserError.invalidFormat("unknown v3 block type: \(blockType)")
            }

            try cursor.advance(by: Int(blockSize))
        }

        guard let recordBlockOffset, let keyDataOffset else {
            throw MDictParserError.invalidFormat("v3 key/record block not found")
        }

        cursor.seek(to: keyDataOffset)

        let blockCount = try cursor.readUInt32BE()
        _ = try cursor.readNumber(width: header.numberWidth)

        var allKeys: [KeyItem] = []

        for _ in 0..<blockCount {
            let decompressedSize = try cursor.readUInt32BE()
            let compressedSize = try cursor.readUInt32BE()
            let blockData = try cursor.readData(count: Int(compressedSize))
            let decompressed = try decodeBlock(
                blockData,
                expectedDecompressedSize: Int(decompressedSize),
                header: header
            )
            allKeys.append(contentsOf: try splitKeyBlock(decompressed, header: header))
        }

        return (allKeys, recordBlockOffset)
    }

    private func decodeKeyBlockInfo(
        _ source: Data,
        header: MDictContainerHeader
    ) throws -> [(compressed: UInt64, decompressed: UInt64)] {
        let keyInfoData: Data

        if header.version >= 2 {
            guard source.count >= 8,
                  source.prefix(4) == Data([0x02, 0x00, 0x00, 0x00]) else {
                throw MDictParserError.invalidFormat("invalid key block info header")
            }

            let adler = MDictCodec.readUInt32BE(source.subdata(in: 4..<8))
            let checksumBytes = source.subdata(in: 4..<8)
            var compressedPayload = Data(source.dropFirst(8))
            if (header.encryptFlag & 0x2) != 0 {
                compressedPayload = try MDictCodec.decryptKeywordIndexPayload(
                    compressedPayload,
                    checksumBytes: checksumBytes
                )
            }
            let decompressed = try MDictCodec.decompressZlib(compressedPayload)
            let calc = MDictCodec.adler32(decompressed)
            guard adler == calc else {
                throw MDictParserError.checksumMismatch("key block info checksum mismatch")
            }
            keyInfoData = decompressed
        } else {
            keyInfoData = source
        }

        var cursor = MDictByteCursor(data: keyInfoData)
        var infoList: [(UInt64, UInt64)] = []

        let usesWideLength = header.version >= 2
        let textLengthWidth = usesWideLength ? 2 : 1
        let textTerminator = usesWideLength ? 1 : 0
        let utf16 = header.encodingName.uppercased().contains("UTF-16")

        while !cursor.isAtEnd {
            _ = try cursor.readNumber(width: header.numberWidth)

            let headSize = try cursor.readNumber(width: textLengthWidth)
            let headAdvance = utf16 ? (headSize + UInt64(textTerminator)) * 2 : headSize + UInt64(textTerminator)
            try cursor.advance(by: Int(headAdvance))

            let tailSize = try cursor.readNumber(width: textLengthWidth)
            let tailAdvance = utf16 ? (tailSize + UInt64(textTerminator)) * 2 : tailSize + UInt64(textTerminator)
            try cursor.advance(by: Int(tailAdvance))

            let compressed = try cursor.readNumber(width: header.numberWidth)
            let decompressed = try cursor.readNumber(width: header.numberWidth)
            infoList.append((compressed, decompressed))
        }

        return infoList
    }

    private func decodeKeyBlocks(
        _ compressedData: Data,
        infoList: [(compressed: UInt64, decompressed: UInt64)],
        header: MDictContainerHeader
    ) throws -> [KeyItem] {
        var offset = 0
        var keyList: [KeyItem] = []

        for info in infoList {
            let size = Int(info.compressed)
            guard offset + size <= compressedData.count else {
                throw MDictParserError.invalidFormat("key block data overflow")
            }

            let slice = compressedData.subdata(in: offset..<(offset + size))
            let decompressed = try decodeBlock(
                slice,
                expectedDecompressedSize: Int(info.decompressed),
                header: header
            )

            keyList.append(contentsOf: try splitKeyBlock(decompressed, header: header))
            offset += size
        }

        return keyList
    }

    private func splitKeyBlock(_ keyBlock: Data, header: MDictContainerHeader) throws -> [KeyItem] {
        var cursor = MDictByteCursor(data: keyBlock)
        var items: [KeyItem] = []

        let utf16 = header.encodingName.uppercased().contains("UTF-16")

        while !cursor.isAtEnd {
            let recordOffset = try cursor.readNumber(width: header.numberWidth)

            let keyData: Data
            if utf16 {
                keyData = try cursor.readUntil(delimiter: Data([0x00, 0x00]), step: 2)
            } else {
                keyData = try cursor.readUntil(delimiter: Data([0x00]), step: 1)
            }

            let key = decodeText(keyData, encoding: header.textEncoding)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            items.append(KeyItem(offset: recordOffset, key: key))
        }

        return items
    }

    private func parseRecordsV1V2Raw(
        cursor: inout MDictByteCursor,
        header: MDictContainerHeader,
        keys: [KeyItem],
        onRecord: (MDictBinaryRecord) throws -> Void
    ) throws {
        let numRecordBlocks = try cursor.readNumber(width: header.numberWidth)
        _ = try cursor.readNumber(width: header.numberWidth)
        _ = try cursor.readNumber(width: header.numberWidth)
        _ = try cursor.readNumber(width: header.numberWidth)

        var blockInfo: [(UInt64, UInt64)] = []
        blockInfo.reserveCapacity(Int(numRecordBlocks))

        for _ in 0..<numRecordBlocks {
            let compressed = try cursor.readNumber(width: header.numberWidth)
            let decompressed = try cursor.readNumber(width: header.numberWidth)
            blockInfo.append((compressed, decompressed))
        }

        try parseRecordBlocksRaw(
            cursor: &cursor,
            header: header,
            keys: keys,
            blockInfo: blockInfo,
            onRecord: onRecord
        )
    }

    private func parseRecordsV3Raw(
        cursor: inout MDictByteCursor,
        header: MDictContainerHeader,
        keys: [KeyItem],
        onRecord: (MDictBinaryRecord) throws -> Void
    ) throws {
        let numRecordBlocks = try cursor.readUInt32BE()
        _ = try cursor.readNumber(width: header.numberWidth)

        var blockInfo: [(UInt64, UInt64)] = []
        blockInfo.reserveCapacity(Int(numRecordBlocks))

        for _ in 0..<numRecordBlocks {
            let decompressed = try cursor.readUInt32BE()
            let compressed = try cursor.readUInt32BE()
            blockInfo.append((UInt64(compressed), UInt64(decompressed)))
        }

        try parseRecordBlocksRaw(
            cursor: &cursor,
            header: header,
            keys: keys,
            blockInfo: blockInfo,
            onRecord: onRecord
        )
    }

    private func parseRecordBlocksRaw(
        cursor: inout MDictByteCursor,
        header: MDictContainerHeader,
        keys: [KeyItem],
        blockInfo: [(compressed: UInt64, decompressed: UInt64)],
        onRecord: (MDictBinaryRecord) throws -> Void
    ) throws {
        var currentGlobalOffset: UInt64 = 0
        var keyIndex = 0

        for info in blockInfo {
            let compressedSize = Int(info.compressed)
            let blockCompressed = try cursor.readData(count: compressedSize)
            let recordBlock = try decodeBlock(
                blockCompressed,
                expectedDecompressedSize: Int(info.decompressed),
                header: header
            )

            while keyIndex < keys.count {
                let keyOffset = keys[keyIndex].offset
                guard keyOffset >= currentGlobalOffset else {
                    throw MDictParserError.invalidFormat("invalid key offset ordering")
                }
                let relative = Int(keyOffset - currentGlobalOffset)
                if relative >= recordBlock.count {
                    break
                }

                let endOffset: UInt64
                if keyIndex + 1 < keys.count {
                    endOffset = keys[keyIndex + 1].offset
                } else {
                    endOffset = currentGlobalOffset + UInt64(recordBlock.count)
                }
                guard endOffset >= currentGlobalOffset else {
                    throw MDictParserError.invalidFormat("invalid record end offset")
                }

                let endRelative = Int(endOffset - currentGlobalOffset)
                guard relative >= 0, endRelative >= relative, endRelative <= recordBlock.count else {
                    throw MDictParserError.invalidFormat("record slice out of bounds")
                }

                let recordData = recordBlock.subdata(in: relative..<endRelative)
                let record = MDictBinaryRecord(key: keys[keyIndex].key, data: recordData)
                try onRecord(record)
                keyIndex += 1
            }

            currentGlobalOffset += UInt64(recordBlock.count)
        }
    }

    private func decodeBlock(
        _ block: Data,
        expectedDecompressedSize: Int,
        header: MDictContainerHeader
    ) throws -> Data {
        guard block.count >= 8 else {
            throw MDictParserError.invalidFormat("compressed block too short")
        }

        let info = MDictCodec.readUInt32LE(block.subdata(in: 0..<4))
        let compressionMethod = info & 0xF
        let encryptionMethod = (info >> 4) & 0xF
        let encryptionSize = Int((info >> 8) & 0xFF)

        if encryptionMethod != 0 {
            throw MDictParserError.unsupported("block encryption method \(encryptionMethod)")
        }
        if encryptionSize != 0 {
            throw MDictParserError.unsupported("block encryption size \(encryptionSize)")
        }

        let checksum = MDictCodec.readUInt32BE(block.subdata(in: 4..<8))
        let payload = block.dropFirst(8)

        let decrypted = Data(payload)

        let output: Data
        switch compressionMethod {
        case 0:
            output = decrypted
        case 1:
            throw MDictParserError.unsupported("LZO compression")
        case 2:
            output = try MDictCodec.decompressZlib(payload)
        default:
            throw MDictParserError.unsupported("compression method \(compressionMethod)")
        }

        if header.version >= 3 {
            let calc = MDictCodec.adler32(decrypted)
            guard calc == checksum else {
                throw MDictParserError.checksumMismatch("compressed checksum mismatch")
            }
        } else {
            let calc = MDictCodec.adler32(output)
            guard calc == checksum else {
                throw MDictParserError.checksumMismatch("decompressed checksum mismatch")
            }
        }

        if expectedDecompressedSize > 0,
           output.count != expectedDecompressedSize,
           compressionMethod != 0 {
            throw MDictParserError.invalidFormat("decompressed size mismatch")
        }

        return output
    }

    private func decodeText(_ data: Data, encoding: String.Encoding) -> String {
        if let decoded = String(data: data, encoding: encoding) {
            return decoded
        }

        if encoding != .utf8, let fallback = String(data: data, encoding: .utf8) {
            return fallback
        }

        if encoding != .utf16LittleEndian,
           let fallback = String(data: data, encoding: .utf16LittleEndian) {
            return fallback
        }

        return String(decoding: data, as: UTF8.self)
    }
}

enum MDictCodec {
    static func readUInt16BE(_ data: Data) -> UInt16 {
        precondition(data.count == 2)
        return (UInt16(data[data.startIndex]) << 8)
            | UInt16(data[data.startIndex + 1])
    }

    static func readUInt32BE(_ data: Data) -> UInt32 {
        precondition(data.count == 4)
        let i = data.startIndex
        return (UInt32(data[i]) << 24)
            | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8)
            | UInt32(data[i + 3])
    }

    static func readUInt32LE(_ data: Data) -> UInt32 {
        precondition(data.count == 4)
        let i = data.startIndex
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    static func readUInt64BE(_ data: Data) -> UInt64 {
        precondition(data.count == 8)
        let i = data.startIndex
        return (UInt64(data[i]) << 56)
            | (UInt64(data[i + 1]) << 48)
            | (UInt64(data[i + 2]) << 40)
            | (UInt64(data[i + 3]) << 32)
            | (UInt64(data[i + 4]) << 24)
            | (UInt64(data[i + 5]) << 16)
            | (UInt64(data[i + 6]) << 8)
            | UInt64(data[i + 7])
    }

    static func adler32(_ data: Data) -> UInt32 {
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        let modulo: UInt32 = 65_521

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for idx in 0..<rawBuffer.count {
                s1 = (s1 + UInt32(base[idx])) % modulo
                s2 = (s2 + s1) % modulo
            }
        }

        return (s2 << 16) | s1
    }

    // MDict Encrypted=2 key-index decryption:
    // key = RIPEMD-128(checksum_bytes + [0x95, 0x36, 0x00, 0x00])
    // plain[i] = nibbleSwap(cipher[i]) ^ i ^ key[i % 16] ^ prevCipher
    static func decryptKeywordIndexPayload(
        _ payload: Data,
        checksumBytes: Data
    ) throws -> Data {
        let key = try keywordIndexKey(checksumBytes: checksumBytes)

        let encrypted = [UInt8](payload)
        var decrypted = [UInt8](repeating: 0, count: encrypted.count)
        var previousCipher: UInt8 = 0x36

        for idx in 0..<encrypted.count {
            let cipher = encrypted[idx]
            let mixed = nibbleSwap(cipher)
            decrypted[idx] = mixed
                ^ UInt8(truncatingIfNeeded: idx)
                ^ key[idx % key.count]
                ^ previousCipher
            previousCipher = cipher
        }

        return Data(decrypted)
    }

    static func encryptKeywordIndexPayload(
        _ payload: Data,
        checksumBytes: Data
    ) throws -> Data {
        let key = try keywordIndexKey(checksumBytes: checksumBytes)

        let plain = [UInt8](payload)
        var encrypted = [UInt8](repeating: 0, count: plain.count)
        var previousCipher: UInt8 = 0x36

        for idx in 0..<plain.count {
            let mixed = plain[idx]
                ^ UInt8(truncatingIfNeeded: idx)
                ^ key[idx % key.count]
                ^ previousCipher
            let cipher = nibbleSwap(mixed)
            encrypted[idx] = cipher
            previousCipher = cipher
        }

        return Data(encrypted)
    }

    private static func keywordIndexKey(checksumBytes: Data) throws -> [UInt8] {
        guard checksumBytes.count == 4 else {
            throw MDictParserError.invalidFormat("invalid keyword index checksum")
        }

        var keySeed = checksumBytes
        keySeed.append(contentsOf: [0x95, 0x36, 0x00, 0x00])
        let key = RIPEMD128.hash(keySeed)
        guard !key.isEmpty else {
            throw MDictParserError.decodeFailed("keyword index key derivation failed")
        }
        return key
    }

    private static func nibbleSwap(_ value: UInt8) -> UInt8 {
        ((value & 0x0F) << 4) | ((value & 0xF0) >> 4)
    }

    static func decompressZlib<S: DataProtocol>(_ source: S) throws -> Data {
        let sourceData = Data(source)
        if sourceData.isEmpty {
            return Data()
        }

        let wrapped = inflateStream(sourceData, windowBits: 15)
        switch wrapped {
        case let .success(data):
            return data
        case let .failure(wrappedReason):
            let raw = inflateStream(sourceData, windowBits: -15)
            switch raw {
            case let .success(data):
                return data
            case let .failure(rawReason):
                throw MDictParserError.decodeFailed(
                    "zlib 解压失败：\(wrappedReason.localizedDescription)；raw-deflate 回退失败：\(rawReason.localizedDescription)"
                )
            }
        }
    }

    private static func inflateStream(
        _ sourceData: Data,
        windowBits: Int32
    ) -> Result<Data, MDictParserError> {
        var output = Data()

        do {
            try sourceData.withUnsafeBytes { sourceBytes in
                guard let sourceBase = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                    throw MDictParserError.decodeFailed("空输入缓冲")
                }

                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: sourceBase)
                stream.avail_in = uInt(sourceBytes.count)

                let initStatus = inflateInit2_(
                    &stream,
                    windowBits,
                    ZLIB_VERSION,
                    Int32(MemoryLayout<z_stream>.size)
                )
                guard initStatus == Z_OK else {
                    throw MDictParserError.decodeFailed("inflateInit2 status=\(initStatus)")
                }
                defer {
                    inflateEnd(&stream)
                }

                let chunkSize = 64 * 1024
                var buffer = [UInt8](repeating: 0, count: chunkSize)

                while true {
                    let status = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int32 in
                        stream.next_out = bufferPtr.baseAddress
                        stream.avail_out = uInt(bufferPtr.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }

                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        output.append(contentsOf: buffer[..<produced])
                    }

                    if status == Z_STREAM_END {
                        break
                    }

                    if status != Z_OK {
                        throw MDictParserError.decodeFailed("status=\(status)")
                    }

                    if produced == 0 && stream.avail_in == 0 {
                        throw MDictParserError.decodeFailed("流提前结束")
                    }
                }
            }
            return .success(output)
        } catch let error as MDictParserError {
            return .failure(error)
        } catch {
            return .failure(.decodeFailed(error.localizedDescription))
        }
    }
}

private enum RIPEMD128 {
    private static let r: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2
    ]

    private static let rp: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14
    ]

    private static let s: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12
    ]

    private static let sp: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8
    ]

    static func hash(_ input: Data) -> [UInt8] {
        var message = [UInt8](input)
        let originalBitLength = UInt64(message.count) * 8

        message.append(0x80)
        while (message.count % 64) != 56 {
            message.append(0x00)
        }

        let bitLengthLE = withUnsafeBytes(of: originalBitLength.littleEndian, Array.init)
        message.append(contentsOf: bitLengthLE)

        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xEFCD_AB89
        var h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = chunkStart + i * 4
                x[i] = UInt32(message[j])
                    | (UInt32(message[j + 1]) << 8)
                    | (UInt32(message[j + 2]) << 16)
                    | (UInt32(message[j + 3]) << 24)
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3

            var aa = h0
            var bb = h1
            var cc = h2
            var dd = h3

            for j in 0..<64 {
                let t = rotateLeft(
                    a &+ f(j, b, c, d) &+ x[r[j]] &+ k(j),
                    by: s[j]
                )
                a = d
                d = c
                c = b
                b = t

                let tp = rotateLeft(
                    aa &+ fp(j, bb, cc, dd) &+ x[rp[j]] &+ kp(j),
                    by: sp[j]
                )
                aa = dd
                dd = cc
                cc = bb
                bb = tp
            }

            let t = h1 &+ c &+ dd
            h1 = h2 &+ d &+ aa
            h2 = h3 &+ a &+ bb
            h3 = h0 &+ b &+ cc
            h0 = t
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(16)

        for word in [h0, h1, h2, h3] {
            let le = word.littleEndian
            digest.append(UInt8(le & 0xFF))
            digest.append(UInt8((le >> 8) & 0xFF))
            digest.append(UInt8((le >> 16) & 0xFF))
            digest.append(UInt8((le >> 24) & 0xFF))
        }

        return digest
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0..<16:
            return x ^ y ^ z
        case 16..<32:
            return (x & y) | (~x & z)
        case 32..<48:
            return (x | ~y) ^ z
        default:
            return (x & z) | (y & ~z)
        }
    }

    private static func fp(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0..<16:
            return (x & z) | (y & ~z)
        case 16..<32:
            return (x | ~y) ^ z
        case 32..<48:
            return (x & y) | (~x & z)
        default:
            return x ^ y ^ z
        }
    }

    private static func k(_ j: Int) -> UInt32 {
        switch j {
        case 0..<16:
            return 0x0000_0000
        case 16..<32:
            return 0x5A82_7999
        case 32..<48:
            return 0x6ED9_EBA1
        default:
            return 0x8F1B_BCDC
        }
    }

    private static func kp(_ j: Int) -> UInt32 {
        switch j {
        case 0..<16:
            return 0x50A2_8BE6
        case 16..<32:
            return 0x5C4D_D124
        case 32..<48:
            return 0x6D70_3EF3
        default:
            return 0x0000_0000
        }
    }
}

struct MDictByteCursor {
    private let data: Data
    private(set) var position: Int

    init(data: Data, position: Int = 0) {
        self.data = data
        self.position = position
    }

    var isAtEnd: Bool {
        position >= data.count
    }

    mutating func seek(to newPosition: Int) {
        position = max(0, min(newPosition, data.count))
    }

    mutating func advance(by count: Int) throws {
        guard count >= 0, position + count <= data.count else {
            throw MDictParserError.invalidFormat("cursor overflow")
        }
        position += count
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, position + count <= data.count else {
            throw MDictParserError.invalidFormat("unexpected EOF")
        }

        let result = data.subdata(in: position..<(position + count))
        position += count
        return result
    }

    mutating func readUInt32BE() throws -> UInt32 {
        let block = try readData(count: 4)
        return MDictCodec.readUInt32BE(block)
    }

    mutating func readUInt32LE() throws -> UInt32 {
        let block = try readData(count: 4)
        return MDictCodec.readUInt32LE(block)
    }

    mutating func readNumber(width: Int) throws -> UInt64 {
        switch width {
        case 1:
            return UInt64(try readData(count: 1).first ?? 0)
        case 2:
            let block = try readData(count: 2)
            return UInt64(MDictCodec.readUInt16BE(block))
        case 4:
            return UInt64(try readUInt32BE())
        case 8:
            let block = try readData(count: 8)
            return MDictCodec.readUInt64BE(block)
        default:
            throw MDictParserError.invalidFormat("unsupported integer width \(width)")
        }
    }

    mutating func readUntil(delimiter: Data, step: Int) throws -> Data {
        guard !delimiter.isEmpty, step > 0 else {
            throw MDictParserError.invalidFormat("invalid delimiter")
        }

        let start = position
        var cursor = position

        while cursor + delimiter.count <= data.count {
            if data[cursor..<(cursor + delimiter.count)] == delimiter[0..<delimiter.count] {
                let result = data.subdata(in: start..<cursor)
                position = cursor + delimiter.count
                return result
            }
            cursor += step
        }

        throw MDictParserError.invalidFormat("delimiter not found")
    }
}
