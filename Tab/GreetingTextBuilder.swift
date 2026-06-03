import Foundation

enum GreetingTextBuilder {
    static func makeGreeting(
        nickname: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let hour = calendar.component(.hour, from: now)
        let baseGreeting: String

        switch hour {
        case 6..<12:
            baseGreeting = "上午好"
        case 12..<18:
            baseGreeting = "下午好"
        default:
            baseGreeting = "晚上好"
        }

        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNickname.isEmpty {
            return "\(baseGreeting)👋"
        }
        return "\(baseGreeting)，\(trimmedNickname)👋"
    }
}
