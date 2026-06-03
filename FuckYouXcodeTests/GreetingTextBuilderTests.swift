import Foundation
import Testing
@testable import FuckYouXcode

struct GreetingTextBuilderTests {
    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    private func makeDate(hour: Int, minute: Int, calendar: Calendar) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 1,
            day: 1,
            hour: hour,
            minute: minute
        )
        guard let date = calendar.date(from: components) else {
            preconditionFailure("Failed to create deterministic test date")
        }
        return date
    }

    @Test func morningGreetingRange() {
        let calendar = makeCalendar()
        let atSix = makeDate(hour: 6, minute: 0, calendar: calendar)
        let beforeNoon = makeDate(hour: 11, minute: 59, calendar: calendar)

        #expect(GreetingTextBuilder.makeGreeting(nickname: "", now: atSix, calendar: calendar) == "上午好👋")
        #expect(GreetingTextBuilder.makeGreeting(nickname: "", now: beforeNoon, calendar: calendar) == "上午好👋")
    }

    @Test func afternoonGreetingRange() {
        let calendar = makeCalendar()
        let atNoon = makeDate(hour: 12, minute: 0, calendar: calendar)
        let beforeEvening = makeDate(hour: 17, minute: 59, calendar: calendar)

        #expect(GreetingTextBuilder.makeGreeting(nickname: "", now: atNoon, calendar: calendar) == "下午好👋")
        #expect(GreetingTextBuilder.makeGreeting(nickname: "", now: beforeEvening, calendar: calendar) == "下午好👋")
    }

    @Test func eveningGreetingRange() {
        let calendar = makeCalendar()
        let atEvening = makeDate(hour: 18, minute: 0, calendar: calendar)
        let beforeMorning = makeDate(hour: 5, minute: 59, calendar: calendar)

        #expect(GreetingTextBuilder.makeGreeting(nickname: "", now: atEvening, calendar: calendar) == "晚上好👋")
        #expect(GreetingTextBuilder.makeGreeting(nickname: "", now: beforeMorning, calendar: calendar) == "晚上好👋")
    }

    @Test func greetingIncludesNicknameWhenPresent() {
        let calendar = makeCalendar()
        let morning = makeDate(hour: 9, minute: 0, calendar: calendar)

        #expect(GreetingTextBuilder.makeGreeting(nickname: "小明", now: morning, calendar: calendar) == "上午好，小明👋")
    }

    @Test func greetingOmitsNicknameWhenBlank() {
        let calendar = makeCalendar()
        let afternoon = makeDate(hour: 14, minute: 0, calendar: calendar)

        #expect(GreetingTextBuilder.makeGreeting(nickname: "   \n\t", now: afternoon, calendar: calendar) == "下午好👋")
    }
}
