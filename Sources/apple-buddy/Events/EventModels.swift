import ArgumentParser
import Foundation

enum ItemKind: String, Codable { case event, reminder }

struct EventSource: Codable, Equatable {
    let id: String
    let title: String
    let type: String
}

struct EventCalendar: Codable, Equatable {
    let id: String
    var title: String
    let kind: ItemKind
    let source: String
    let sourceID: String
    let type: String
    let color: String?
    let readOnly: Bool
    let isDefault: Bool
}

struct Recurrence: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable, ExpressibleByArgument { case daily, weekly, monthly, yearly }
    var frequency: Frequency
    var interval: Int
    var until: Date?
    var count: Int?
}

struct LocationAlarm: Codable, Equatable {
    enum Proximity: String, Codable { case arrive, leave }
    var title: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var proximity: Proximity
}

struct ReminderAttachment: Codable, Equatable {
    enum Kind: String, Codable { case image, file, url }
    var id: String
    var kind: Kind
    var uti: String?
    var name: String?
    var path: String?
    var size: Int?
    var width: Int?
    var height: Int?
    var url: String?
}

struct ReminderSection: Codable, Equatable {
    var id: String
    var title: String
    var listID: String
}

struct ReminderItem: Codable, Equatable {
    var id: String
    var title: String
    var notes: String?
    var listID: String
    var list: String
    var due: Date?
    var dueHasTime: Bool
    var priority: Int
    var completed: Bool
    var completionDate: Date?
    var url: String?
    var alarms: [Int]
    var location: LocationAlarm?
    var recurrence: Recurrence?
    var flagged = false
    var tags: [String] = []
    var parentID: String?
    var sectionID: String?
    var section: String?
    var attachments: [ReminderAttachment] = []
    var created: Date?
    var modified: Date?
}

struct Attendee: Codable, Equatable {
    let name: String?
    let email: String?
    let status: String
    let role: String
}

struct EventItem: Codable, Equatable {
    var id: String
    var title: String
    var calendarID: String
    var calendar: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String?
    var notes: String?
    var url: String?
    var alarms: [Int]
    var recurrence: Recurrence?
    var occurrence: Date?
    var isDetached: Bool
    var status: String
    var organizer: String?
    var attendees: [Attendee]
    var created: Date?
    var modified: Date?
}

enum EditSpan: String, ExpressibleByArgument { case this, future }

struct DateArgument: ExpressibleByArgument, Equatable {
    let date: Date
    let hasTime: Bool

    init?(argument: String) {
        guard let parsed = DateArgument.parse(argument) else { return nil }
        self = parsed
    }

    init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }

    static func parse(_ text: String, calendar: Calendar = .current) -> DateArgument? {
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: text) { return DateArgument(date: date, hasTime: true) }
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return DateArgument(date: date, hasTime: true) }
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        guard let date = day.date(from: text) else { return nil }
        return DateArgument(date: date, hasTime: false)
    }

    static let help = "ISO 8601 date, 2026-10-07T09:00, 2026-10-07T09:00:00+11:00 or 2026-10-07 for a whole day, local time zone unless given"
}

enum DateText {
    static func stamp(_ date: Date, hasTime: Bool = true, calendar: Calendar = .current) -> String {
        if hasTime {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = calendar.timeZone
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return day.string(from: date)
    }
}

extension JSONEncoder {
    static func events() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DateText.stamp(date))
        }
        return encoder
    }
}
