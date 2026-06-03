//
//  DictionaryDB.swift
//  LearningThroughVideos
//
//  Created by 马逸凡 on 2026/2/5.
//
import Foundation
import GRDB

final class DictionaryDB {
    static let shared = DictionaryDB()
    private(set) var dbQueue: DatabaseQueue!
    private static let dictionaryFileName = "dic_.db"
    private static let dictionaryFingerprintFileName = "dic_.db.bundle-fingerprint"

    private init() {}

    func prepareIfNeeded_() throws {
        let fm = FileManager.default

        let appSupport = try UserStoragePaths.applicationSupportDirectory(createIfNeeded: true)
        let dbURL = appSupport.appendingPathComponent(Self.dictionaryFileName)
        let fingerprintURL = appSupport.appendingPathComponent(Self.dictionaryFingerprintFileName)

        guard let bundledURL = Bundle.main.url(forResource: "dic_", withExtension: "db") else {
            throw NSError(domain: "DictionaryDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "dictionary.db not found in app bundle"])
        }

        let bundledFingerprint = try Self.fileFingerprint(for: bundledURL)
        let installedFingerprint = try? String(contentsOf: fingerprintURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !fm.fileExists(atPath: dbURL.path) || installedFingerprint != bundledFingerprint {
            try Self.installBundledDictionary(
                from: bundledURL,
                to: dbURL,
                fingerprintURL: fingerprintURL,
                fingerprint: bundledFingerprint
            )
        }

        // 打开数据库
        var config = Configuration()
        // 目前你只读也行，后续要写（比如 rebuild / 统计缓存）可以改为 false
        config.readonly = false

        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        

    }

    private static func installBundledDictionary(
        from bundledURL: URL,
        to dbURL: URL,
        fingerprintURL: URL,
        fingerprint: String
    ) throws {
        let fm = FileManager.default
        let tempURL = dbURL.deletingLastPathComponent().appendingPathComponent("\(dictionaryFileName).installing")

        try removeIfExists(tempURL)
        try fm.copyItem(at: bundledURL, to: tempURL)

        try removeDatabaseSidecarFiles(for: dbURL)
        try removeIfExists(dbURL)
        try fm.moveItem(at: tempURL, to: dbURL)
        try fingerprint.write(to: fingerprintURL, atomically: true, encoding: .utf8)
    }

    private static func fileFingerprint(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = values.fileSize ?? 0
        let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(fileSize):\(Int(modifiedAt))"
    }

    private static func removeDatabaseSidecarFiles(for dbURL: URL) throws {
        try removeIfExists(URL(fileURLWithPath: dbURL.path + "-wal"))
        try removeIfExists(URL(fileURLWithPath: dbURL.path + "-shm"))
    }

    private static func removeIfExists(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
