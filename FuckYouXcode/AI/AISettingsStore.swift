import Combine
import Foundation
import Security

enum AISettingsDefaults {
    static let baseURLString = "https://api.openai.com/v1"
    static let systemPrompt = "你是一个面向英语学习者的词典助手。回答要准确、简洁，并优先解释词义、用法、例句和易混点。"
}

enum AIKeychainStore {
    private static let service = "FuckYouXcode.AIProvider"
    private static let account = "OpenAICompatibleAPIKey"

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func saveAPIKey(_ apiKey: String) {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        guard !normalized.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(normalized.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

@MainActor
final class AISettingsStore: ObservableObject {
    private enum Keys {
        static let baseURLString = "ai.provider.base_url"
        static let model = "ai.provider.model"
        static let systemPrompt = "ai.provider.system_prompt"
    }

    @Published var baseURLString: String {
        didSet {
            defaults.set(baseURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURLString)
        }
    }

    @Published var apiKey: String {
        didSet {
            AIKeychainStore.saveAPIKey(apiKey)
        }
    }

    @Published var model: String {
        didSet {
            defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.model)
        }
    }

    @Published var systemPrompt: String {
        didSet {
            let normalized = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(normalized.isEmpty ? AISettingsDefaults.systemPrompt : normalized, forKey: Keys.systemPrompt)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedBaseURL = defaults.string(forKey: Keys.baseURLString)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedModel = defaults.string(forKey: Keys.model)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedPrompt = defaults.string(forKey: Keys.systemPrompt)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        self.baseURLString = storedBaseURL.isEmpty ? AISettingsDefaults.baseURLString : storedBaseURL
        self.apiKey = AIKeychainStore.loadAPIKey()
        self.model = storedModel
        self.systemPrompt = storedPrompt.isEmpty ? AISettingsDefaults.systemPrompt : storedPrompt
    }

    var configuration: AIProviderConfiguration {
        AIProviderConfiguration(
            baseURLString: baseURLString,
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt
        )
    }

    var isConfigured: Bool {
        configuration.isReady
    }
}
