//
//  UserProfileSettingsStore.swift
//  FuckYouXcode
//
//  Created by Codex on 2026/2/20.
//

import Foundation
import UIKit
import Combine

enum AppAppearanceController {
    static let darkModeStorageKey = "appearance_is_dark_mode"

    @MainActor
    static func applyDarkMode(_ isDarkModeEnabled: Bool, animated: Bool = false, duration: TimeInterval = 0.3) {
        let style: UIUserInterfaceStyle = isDarkModeEnabled ? .dark : .light

        guard let window = activeKeyWindow() else { return }
        guard window.overrideUserInterfaceStyle != style else { return }

        if animated {
            UIView.transition(
                with: window,
                duration: duration,
                options: [.transitionCrossDissolve, .allowAnimatedContent, .beginFromCurrentState]
            ) {
                window.overrideUserInterfaceStyle = style
            }
        } else {
            window.overrideUserInterfaceStyle = style
        }
    }

    @MainActor
    private static func activeKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, rhs in
                lhs.activationState.sortPriority < rhs.activationState.sortPriority
            }

        return scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private extension UIScene.ActivationState {
    var sortPriority: Int {
        switch self {
        case .foregroundActive:
            return 0
        case .foregroundInactive:
            return 1
        case .background:
            return 2
        case .unattached:
            return 3
        @unknown default:
            return 4
        }
    }
}

final class UserProfileSettingsStore: ObservableObject {
    private enum Keys {
        static let nickname = "user_profile_nickname"
        static let avatarFileName = "user_profile_avatar_file_name"
    }

    @Published var nickname: String {
        didSet {
            defaults.set(nickname, forKey: Keys.nickname)
        }
    }

    @Published var avatarFileName: String {
        didSet {
            defaults.set(avatarFileName, forKey: Keys.avatarFileName)
        }
    }

    @Published private(set) var avatarImage: UIImage?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedName = defaults.string(forKey: Keys.nickname)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.nickname = storedName.isEmpty ? "" : storedName
        self.avatarFileName = defaults.string(forKey: Keys.avatarFileName) ?? ""
        self.avatarImage = nil
        self.avatarImage = loadAvatarImage()
    }

    func updateNickname(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        nickname = trimmed.isEmpty ? "" : trimmed
    }

    @discardableResult
    func saveAvatar(imageData: Data) -> Bool {
        guard let image = UIImage(data: imageData) else {
            return false
        }
        return saveAvatar(image: image)
    }

    @discardableResult
    func saveAvatar(image: UIImage) -> Bool {
        guard let jpegData = image.jpegData(compressionQuality: 0.82) else {
            return false
        }

        do {
            let avatarURL = try UserStoragePaths.localUserAvatarURL(createIfNeeded: true)
            try jpegData.write(to: avatarURL, options: .atomic)
            avatarFileName = UserStoragePaths.userAvatarFileName
            avatarImage = UIImage(data: jpegData) ?? image
            return true
        } catch {
            return false
        }
    }

    func loadAvatarImage() -> UIImage? {
        let normalized = avatarFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        do {
            let fileURL = try UserStoragePaths.localUserProfileDirectoryURL(createIfNeeded: false)
                .appendingPathComponent(normalized, isDirectory: false)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            let data = try Data(contentsOf: fileURL)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
