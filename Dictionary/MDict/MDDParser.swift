import Foundation
import UniformTypeIdentifiers

struct MDDAssetRecord {
    let originalKey: String
    let pathNorm: String
    let data: Data
    let mimeType: String
}

struct MDDParseResult {
    let assets: [MDDAssetRecord]
}

final class MDDParser {
    @discardableResult
    func enumerateAssets(
        fileURL: URL,
        onAsset: @escaping (MDDAssetRecord) throws -> Void
    ) throws -> Int {
        var seenNormalized: Set<String> = []
        var assetCount = 0

        _ = try MDictBinaryParser(fileURL: fileURL, forceEncodingName: "UTF-16")
            .enumerateBinaryRecords { record in
                let canonical = MDictResourcePath.canonicalPath(record.key)
                guard !canonical.isEmpty else { return }

                let normalized = MDictResourcePath.normalizedLookupPath(canonical)
                guard !normalized.isEmpty else { return }
                guard seenNormalized.insert(normalized).inserted else { return }

                let asset = MDDAssetRecord(
                    originalKey: canonical,
                    pathNorm: normalized,
                    data: record.data,
                    mimeType: Self.mimeType(forPath: canonical)
                )
                try onAsset(asset)
                assetCount += 1
            }

        return assetCount
    }

    func parse(fileURL: URL) throws -> MDDParseResult {
        var assets: [MDDAssetRecord] = []
        assets.reserveCapacity(256)

        _ = try enumerateAssets(fileURL: fileURL) { asset in
            assets.append(asset)
        }

        return MDDParseResult(assets: assets)
    }

    static func mimeType(forPath path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty,
              let utType = UTType(filenameExtension: ext),
              let mimeType = utType.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }
}
