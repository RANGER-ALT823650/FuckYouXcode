import Foundation

enum AIChatRole: String, Codable, CaseIterable, Hashable {
    case user
    case assistant
    case system
}

struct AIChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var role: AIChatRole
    var content: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: AIChatRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

struct AIChatSession: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var contextWord: String?
    var messages: [AIChatMessage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        contextWord: String? = nil,
        messages: [AIChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.contextWord = contextWord
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AIProviderConfiguration: Equatable {
    var baseURLString: String
    var apiKey: String
    var model: String
    var systemPrompt: String

    var isReady: Bool {
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
