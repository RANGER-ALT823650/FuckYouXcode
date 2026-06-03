import Combine
import Foundation

@MainActor
final class AIChatHistoryStore: ObservableObject {
    private enum Keys {
        static let sessions = "ai.chat.sessions"
    }

    @Published private(set) var sessions: [AIChatSession] = []

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var sortedSessions: [AIChatSession] {
        sessions.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    func session(id: UUID) -> AIChatSession? {
        sessions.first { $0.id == id }
    }

    func existingSessionID(contextWord: String) -> UUID? {
        let normalized = normalizedWord(contextWord)
        return sessions.first { session in
            normalizedWord(session.contextWord ?? "") == normalized
        }?.id
    }

    func ensureSessionID(contextWord: String) -> UUID {
        let normalized = normalizedWord(contextWord)
        if let existingID = existingSessionID(contextWord: normalized) {
            return existingID
        }

        let title = normalized.isEmpty ? "AI 对话" : normalized
        let session = AIChatSession(title: title, contextWord: normalized.isEmpty ? nil : normalized)
        sessions.append(session)
        persist()
        return session.id
    }

    func appendMessage(_ message: AIChatMessage, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(message)
        sessions[index].updatedAt = message.createdAt
        persist()
    }

    func appendContent(_ contentDelta: String, to messageID: UUID, in sessionID: UUID) {
        guard !contentDelta.isEmpty,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        let now = Date()
        sessions[sessionIndex].messages[messageIndex].content += contentDelta
        sessions[sessionIndex].updatedAt = now
        persist()
    }

    func replaceMessages(_ messages: [AIChatMessage], in sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages = messages
        sessions[index].updatedAt = messages.last?.createdAt ?? Date()
        persist()
    }

    func clearMessages(in sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.removeAll()
        sessions[index].updatedAt = Date()
        persist()
    }

    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    func deleteSessions(at offsets: IndexSet) {
        let sorted = sortedSessions
        let ids = offsets.map { sorted[$0].id }
        sessions.removeAll { ids.contains($0.id) }
        persist()
    }

    func clearAll() {
        sessions.removeAll()
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: Keys.sessions),
              let decoded = try? decoder.decode([AIChatSession].self, from: data) else {
            sessions = []
            return
        }
        sessions = decoded
    }

    private func persist() {
        guard let data = try? encoder.encode(sessions) else { return }
        defaults.set(data, forKey: Keys.sessions)
    }

    private func normalizedWord(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
