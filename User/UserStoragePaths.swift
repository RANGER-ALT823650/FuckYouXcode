//
//  UserStoragePaths.swift
//  FuckYouXcode
//
//  Created by Codex on 2026/2/20.
//

import Foundation

nonisolated enum UserStoragePaths {
    static let userDatabaseFileName = "user_1.db"
    static let wordGroupImagesDirectoryName = "word_group_images"
    static let userProfileDirectoryName = "user_profile"
    static let userAvatarFileName = "avatar.jpg"
    static let dictionariesDirectoryName = "dictionaries"
    static let dictionaryCatalogFileName = "catalog.json"

    // TEMP: iCloud disabled for non-paid Apple Developer account.
    // private static let cloudMirrorDirectoryName = "user_data_mirror"
    // private static let cloudMetadataFileName = "meta.json"

    static func applicationSupportDirectory(createIfNeeded: Bool = true) throws -> URL {
        let fm = FileManager.default
        let url = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createIfNeeded
        )
        if createIfNeeded {
            try ensureDirectoryExists(url)
        }
        return url
    }

    static func localUserDatabaseURL(createIfNeeded: Bool = true) throws -> URL {
        try applicationSupportDirectory(createIfNeeded: createIfNeeded)
            .appendingPathComponent(userDatabaseFileName, isDirectory: false)
    }

    static func localWordGroupImagesRootURL(createIfNeeded: Bool = false) throws -> URL {
        let url = try applicationSupportDirectory(createIfNeeded: true)
            .appendingPathComponent(wordGroupImagesDirectoryName, isDirectory: true)
        if createIfNeeded {
            try ensureDirectoryExists(url)
        }
        return url
    }

    static func localUserProfileDirectoryURL(createIfNeeded: Bool = false) throws -> URL {
        let url = try applicationSupportDirectory(createIfNeeded: true)
            .appendingPathComponent(userProfileDirectoryName, isDirectory: true)
        if createIfNeeded {
            try ensureDirectoryExists(url)
        }
        return url
    }

    static func localUserAvatarURL(createIfNeeded: Bool = false) throws -> URL {
        try localUserProfileDirectoryURL(createIfNeeded: createIfNeeded)
            .appendingPathComponent(userAvatarFileName, isDirectory: false)
    }

    static func dictionariesRootURL(createIfNeeded: Bool = false) throws -> URL {
        let url = try applicationSupportDirectory(createIfNeeded: true)
            .appendingPathComponent(dictionariesDirectoryName, isDirectory: true)
        if createIfNeeded {
            try ensureDirectoryExists(url)
        }
        return url
    }

    static func dictionaryFolderURL(id: String, createIfNeeded: Bool = false) throws -> URL {
        let safeID = id.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#,
            with: "_",
            options: .regularExpression
        )
        let url = try dictionariesRootURL(createIfNeeded: true)
            .appendingPathComponent(safeID, isDirectory: true)
        if createIfNeeded {
            try ensureDirectoryExists(url)
        }
        return url
    }

    static func dictionaryCatalogURL(createIfNeeded: Bool = false) throws -> URL {
        let url = try dictionariesRootURL(createIfNeeded: createIfNeeded)
            .appendingPathComponent(dictionaryCatalogFileName, isDirectory: false)
        if createIfNeeded {
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try Data("[]".utf8).write(to: url, options: .atomic)
            }
        }
        return url
    }

    // TEMP: iCloud disabled for non-paid Apple Developer account.
    #if false
    static func ubiquityContainerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    static func cloudMirrorRootURL(createIfNeeded: Bool = false) -> URL? {
        guard let container = ubiquityContainerURL() else { return nil }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        let mirrorRoot = documents.appendingPathComponent(cloudMirrorDirectoryName, isDirectory: true)

        if createIfNeeded {
            do {
                try ensureDirectoryExists(documents)
                try ensureDirectoryExists(mirrorRoot)
            } catch {
                return nil
            }
        }
        return mirrorRoot
    }

    static func cloudDatabaseURL(createIfNeeded: Bool = false) -> URL? {
        cloudMirrorRootURL(createIfNeeded: createIfNeeded)?
            .appendingPathComponent(userDatabaseFileName, isDirectory: false)
    }

    static func cloudWordGroupImagesRootURL(createIfNeeded: Bool = false) -> URL? {
        cloudMirrorRootURL(createIfNeeded: createIfNeeded)?
            .appendingPathComponent(wordGroupImagesDirectoryName, isDirectory: true)
    }

    static func cloudMetadataURL(createIfNeeded: Bool = false) -> URL? {
        cloudMirrorRootURL(createIfNeeded: createIfNeeded)?
            .appendingPathComponent(cloudMetadataFileName, isDirectory: false)
    }
    #endif

    private static func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if exists {
            guard isDirectory.boolValue else {
                throw NSError(
                    domain: "UserStoragePaths",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected directory at \(url.path), found file."]
                )
            }
            return
        }

        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
