//
//  UserCloudSyncService.swift
//  FuckYouXcode
//
//  Created by Codex on 2026/2/20.
//

import Foundation
import GRDB

// TEMP: iCloud disabled for non-paid Apple Developer account.
// Keep implementation for future re-enable.
#if false

nonisolated struct UserCloudSyncStatus: Sendable {
    var isEnabled: Bool
    var isICloudAvailable: Bool
    var isSyncing: Bool
    var lastSyncAt: Date?
    var lastErrorMessage: String?
}

nonisolated struct UserCloudMirrorMetadata: Codable, Sendable {
    var lastMutationAt: Int64
    var lastSyncedAt: Int64
    var deviceID: String
    var schemaVersion: Int
}

nonisolated enum UserCloudSyncTrigger: Sendable {
    case appLaunch
    case appForeground
    case localMutation
    case manual
}

actor UserCloudSyncService {
    static let shared = UserCloudSyncService()

    private enum Keys {
        static let syncEnabled = "user_sync_enabled"
        static let consentPrompted = "user_sync_consent_prompted"
        static let localLastMutationAt = "user_sync_local_last_mutation_at"
        static let lastSyncAt = "user_sync_last_sync_at"
        static let lastErrorMessage = "user_sync_last_error_message"
        static let deviceID = "user_sync_device_id"
    }

    private enum SyncDecision {
        case upload(localMutationAt: Int64)
        case download(cloudMetadata: UserCloudMirrorMetadata)
        case noop
    }

    private let defaults: UserDefaults
    private let fm = FileManager.default

    private var isSyncing = false
    private var hasPendingSyncRequest = false
    private var debounceTask: Task<Void, Never>?

    private var lastSyncAtCache: Date?
    private var lastErrorMessageCache: String?

    private let syncDebounceNanoseconds: UInt64 = 1_000_000_000
    private let syncSchemaVersion = 1

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let ts = defaults.object(forKey: Keys.lastSyncAt) as? TimeInterval {
            self.lastSyncAtCache = Date(timeIntervalSince1970: ts)
        }
        self.lastErrorMessageCache = defaults.string(forKey: Keys.lastErrorMessage)
    }

    func bootstrap() async {
        if localLastMutationAt() == nil {
            let estimated = estimateLocalMutationAt()
            setLocalLastMutationAt(estimated)
        }
        await performSyncIfNeeded(trigger: .appLaunch)
    }

    func sceneDidBecomeActive() async {
        await performSyncIfNeeded(trigger: .appForeground)
    }

    func shouldPromptForConsent() -> Bool {
        guard !defaults.bool(forKey: Keys.consentPrompted) else { return false }
        return UserStoragePaths.cloudMirrorRootURL(createIfNeeded: false) != nil
    }

    func markConsentPromptHandled() {
        defaults.set(true, forKey: Keys.consentPrompted)
    }

    func setSyncEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Keys.syncEnabled)
        defaults.set(true, forKey: Keys.consentPrompted)
        if enabled {
            await performSync(trigger: .manual, force: true)
        } else {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    func performManualSync() async {
        await performSync(trigger: .manual, force: true)
    }

    func notifyLocalMutation() async {
        setLocalLastMutationAt(Self.currentUnixTimestamp())
        guard defaults.bool(forKey: Keys.syncEnabled) else { return }

        debounceTask?.cancel()
        debounceTask = Task { [syncDebounceNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: syncDebounceNanoseconds)
            } catch {
                return
            }
            await self.performSync(trigger: .localMutation, force: false)
        }
    }

    func statusSnapshot() -> UserCloudSyncStatus {
        if let cachedError = defaults.string(forKey: Keys.lastErrorMessage), cachedError != lastErrorMessageCache {
            lastErrorMessageCache = cachedError
        }
        if let ts = defaults.object(forKey: Keys.lastSyncAt) as? TimeInterval {
            let cachedDate = Date(timeIntervalSince1970: ts)
            if cachedDate != lastSyncAtCache {
                lastSyncAtCache = cachedDate
            }
        }

        return UserCloudSyncStatus(
            isEnabled: defaults.bool(forKey: Keys.syncEnabled),
            isICloudAvailable: UserStoragePaths.cloudMirrorRootURL(createIfNeeded: false) != nil,
            isSyncing: isSyncing,
            lastSyncAt: lastSyncAtCache,
            lastErrorMessage: lastErrorMessageCache
        )
    }

    func disableSync(deleteCloudMirror: Bool) async {
        defaults.set(false, forKey: Keys.syncEnabled)
        defaults.set(true, forKey: Keys.consentPrompted)
        debounceTask?.cancel()
        debounceTask = nil

        guard deleteCloudMirror else { return }
        do {
            if let cloudRoot = UserStoragePaths.cloudMirrorRootURL(createIfNeeded: false) {
                try removeItemIfExists(at: cloudRoot)
            }
            lastErrorMessageCache = nil
            defaults.removeObject(forKey: Keys.lastErrorMessage)
        } catch {
            lastErrorMessageCache = error.localizedDescription
            defaults.set(lastErrorMessageCache, forKey: Keys.lastErrorMessage)
        }
    }

    private func performSyncIfNeeded(trigger: UserCloudSyncTrigger) async {
        guard defaults.bool(forKey: Keys.syncEnabled) else { return }
        await performSync(trigger: trigger, force: false)
    }

    private func performSync(trigger: UserCloudSyncTrigger, force: Bool) async {
        guard defaults.bool(forKey: Keys.syncEnabled) else { return }

        guard
            let cloudRoot = UserStoragePaths.cloudMirrorRootURL(createIfNeeded: true),
            let cloudDBURL = UserStoragePaths.cloudDatabaseURL(createIfNeeded: true),
            let cloudImagesURL = UserStoragePaths.cloudWordGroupImagesRootURL(createIfNeeded: true),
            let cloudMetaURL = UserStoragePaths.cloudMetadataURL(createIfNeeded: true)
        else {
            let message = "iCloud 不可用，请确认已登录 Apple ID 并开启 iCloud Drive。"
            lastErrorMessageCache = message
            defaults.set(message, forKey: Keys.lastErrorMessage)
            return
        }

        if isSyncing {
            hasPendingSyncRequest = true
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
            if hasPendingSyncRequest {
                hasPendingSyncRequest = false
                Task {
                    await self.performSync(trigger: .localMutation, force: false)
                }
            }
        }

        do {
            let decision = try makeSyncDecision(
                cloudRoot: cloudRoot,
                cloudDBURL: cloudDBURL,
                cloudMetaURL: cloudMetaURL,
                force: force
            )

            switch decision {
            case .upload(let localMutationAt):
                try uploadLocalMirror(
                    cloudDBURL: cloudDBURL,
                    cloudImagesURL: cloudImagesURL,
                    cloudMetaURL: cloudMetaURL,
                    localMutationAt: localMutationAt
                )
            case .download(let cloudMetadata):
                try downloadCloudMirror(
                    cloudDBURL: cloudDBURL,
                    cloudImagesURL: cloudImagesURL,
                    cloudMetadata: cloudMetadata
                )
            case .noop:
                break
            }

            let now = Date()
            lastSyncAtCache = now
            lastErrorMessageCache = nil
            defaults.set(now.timeIntervalSince1970, forKey: Keys.lastSyncAt)
            defaults.removeObject(forKey: Keys.lastErrorMessage)
        } catch {
            lastErrorMessageCache = error.localizedDescription
            defaults.set(lastErrorMessageCache, forKey: Keys.lastErrorMessage)
        }
    }

    private func makeSyncDecision(
        cloudRoot: URL,
        cloudDBURL: URL,
        cloudMetaURL: URL,
        force: Bool
    ) throws -> SyncDecision {
        guard fm.fileExists(atPath: cloudRoot.path) else {
            return .upload(localMutationAt: ensureLocalMutationAt())
        }

        let localMutationAt = ensureLocalMutationAt()
        let cloudMetadata = try loadCloudMetadata(at: cloudMetaURL)

        if cloudMetadata == nil {
            return .upload(localMutationAt: localMutationAt)
        }

        guard let cloudMetadata else {
            return .upload(localMutationAt: localMutationAt)
        }

        if !fm.fileExists(atPath: cloudDBURL.path) {
            return .upload(localMutationAt: localMutationAt)
        }

        if localMutationAt > cloudMetadata.lastMutationAt {
            return .upload(localMutationAt: localMutationAt)
        }

        if cloudMetadata.lastMutationAt > localMutationAt {
            return .download(cloudMetadata: cloudMetadata)
        }

        if force {
            return .upload(localMutationAt: localMutationAt)
        }

        return .noop
    }

    private func uploadLocalMirror(
        cloudDBURL: URL,
        cloudImagesURL: URL,
        cloudMetaURL: URL,
        localMutationAt: Int64
    ) throws {
        try backupLocalDatabase(toCloudURL: cloudDBURL)

        let localImagesRoot = try? UserStoragePaths.localWordGroupImagesRootURL(createIfNeeded: false)
        try mirrorDirectory(from: localImagesRoot, to: cloudImagesURL)

        let metadata = UserCloudMirrorMetadata(
            lastMutationAt: localMutationAt,
            lastSyncedAt: Self.currentUnixTimestamp(),
            deviceID: deviceID(),
            schemaVersion: syncSchemaVersion
        )
        try saveCloudMetadata(metadata, at: cloudMetaURL)
    }

    private func downloadCloudMirror(
        cloudDBURL: URL,
        cloudImagesURL: URL,
        cloudMetadata: UserCloudMirrorMetadata
    ) throws {
        try backupCloudDatabaseToLocal(fromCloudURL: cloudDBURL)

        let localImagesRoot = try UserStoragePaths.localWordGroupImagesRootURL(createIfNeeded: false)
        try mirrorDirectory(from: cloudImagesURL, to: localImagesRoot)

        setLocalLastMutationAt(cloudMetadata.lastMutationAt)
    }

    private func backupLocalDatabase(toCloudURL cloudDBURL: URL) throws {
        let localDBURL = try UserStoragePaths.localUserDatabaseURL(createIfNeeded: true)
        try backupDatabase(from: localDBURL, to: cloudDBURL)
    }

    private func backupCloudDatabaseToLocal(fromCloudURL cloudDBURL: URL) throws {
        let localDBURL = try UserStoragePaths.localUserDatabaseURL(createIfNeeded: true)
        try backupDatabase(from: cloudDBURL, to: localDBURL)
    }

    private func backupDatabase(from sourceURL: URL, to destinationURL: URL) throws {
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw NSError(
                domain: "UserCloudSyncService",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Source database does not exist: \(sourceURL.path)"]
            )
        }

        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourceQueue = try DatabaseQueue(path: sourceURL.path)
        let destinationQueue = try DatabaseQueue(path: destinationURL.path)

        defer {
            try? sourceQueue.close()
            try? destinationQueue.close()
        }

        try sourceQueue.backup(to: destinationQueue)
    }

    private func mirrorDirectory(from sourceURL: URL?, to destinationURL: URL) throws {
        if let sourceURL {
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                try removeItemIfExists(at: destinationURL)
                return
            }

            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tempURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(destinationURL.lastPathComponent)_tmp_\(UUID().uuidString)", isDirectory: true)

            try removeItemIfExists(at: tempURL)
            try fm.copyItem(at: sourceURL, to: tempURL)
            try removeItemIfExists(at: destinationURL)
            try fm.moveItem(at: tempURL, to: destinationURL)
            return
        }

        try removeItemIfExists(at: destinationURL)
    }

    private func loadCloudMetadata(at url: URL) throws -> UserCloudMirrorMetadata? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UserCloudMirrorMetadata.self, from: data)
    }

    private func saveCloudMetadata(_ metadata: UserCloudMirrorMetadata, at url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private func removeItemIfExists(at url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    private func localLastMutationAt() -> Int64? {
        if let value = defaults.object(forKey: Keys.localLastMutationAt) as? Int64 {
            return value
        }
        if let value = defaults.object(forKey: Keys.localLastMutationAt) as? Int {
            return Int64(value)
        }
        if let value = defaults.object(forKey: Keys.localLastMutationAt) as? Double {
            return Int64(value)
        }
        return nil
    }

    private func setLocalLastMutationAt(_ value: Int64) {
        defaults.set(value, forKey: Keys.localLastMutationAt)
    }

    private func ensureLocalMutationAt() -> Int64 {
        if let existing = localLastMutationAt() {
            return existing
        }
        let estimated = estimateLocalMutationAt()
        setLocalLastMutationAt(estimated)
        return estimated
    }

    private func estimateLocalMutationAt() -> Int64 {
        var latest: Date?
        if let dbURL = try? UserStoragePaths.localUserDatabaseURL(createIfNeeded: false) {
            latest = maxDate(latest, fileDate(at: dbURL))
        }
        if let imagesRoot = try? UserStoragePaths.localWordGroupImagesRootURL(createIfNeeded: false) {
            latest = maxDate(latest, newestDateInDirectory(at: imagesRoot))
        }
        return Int64((latest ?? Date()).timeIntervalSince1970)
    }

    private func fileDate(at url: URL) -> Date? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    private func newestDateInDirectory(at rootURL: URL) -> Date? {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        var latest = fileDate(at: rootURL)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return latest
        }

        for case let fileURL as URL in enumerator {
            if let date = fileDate(at: fileURL) {
                latest = maxDate(latest, date)
            }
        }

        return latest
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?):
            return max(l, r)
        case let (l?, nil):
            return l
        case let (nil, r?):
            return r
        case (nil, nil):
            return nil
        }
    }

    private func deviceID() -> String {
        if let existing = defaults.string(forKey: Keys.deviceID), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Keys.deviceID)
        return generated
    }

    private static func currentUnixTimestamp() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}

#endif
