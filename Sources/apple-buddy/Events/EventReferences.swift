import ArgumentParser
import Foundation

enum EventHelp {
    static let list = "list name, UUID or unique prefix of at least 8 characters from reminders lists"
    static let calendar = "calendar name, UUID or unique prefix of at least 8 characters from calendar calendars"
    static let reminder = "Reminder UUID or unique prefix of at least 8 characters from reminders ls"
    static let event = "Event UUID or unique prefix of at least 8 characters from calendar events"
    static let source = "source name or id from calendar calendars --json, for example iCloud"
}

func resolveCalendar(_ store: EventStore, kind: ItemKind, _ reference: String) throws -> EventCalendar {
    let calendars = try store.calendars(kind)
    let noun = kind == .reminder ? "List" : "Calendar"
    let command = kind == .reminder ? "reminders lists" : "calendar calendars"
    if let exact = calendars.first(where: { $0.id == reference }) { return exact }
    if reference.count >= 8 {
        let prefixed = calendars.filter { $0.id.lowercased().hasPrefix(reference.lowercased()) }
        if prefixed.count == 1 { return prefixed[0] }
    }
    let named = calendars.filter { $0.title.caseInsensitiveCompare(reference) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.count > 1 {
        throw NotesError(description: "\(noun) name is ambiguous: \(reference). Use a UUID from abdy \(command): " + named.map { "\($0.title) (\($0.source)) \($0.id)" }.joined(separator: ", "))
    }
    throw NotesError(description: "\(noun) not found: \(reference). Use a name, a UUID or its prefix of at least 8 characters from abdy \(command)")
}

func resolveSource(_ store: EventStore, _ reference: String) throws -> EventSource {
    let sources = try store.sources()
    if let exact = sources.first(where: { $0.id == reference }) { return exact }
    let named = sources.filter { $0.title.caseInsensitiveCompare(reference) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.count > 1 { throw NotesError(description: "Source name is ambiguous: \(reference). Use an id: " + named.map { "\($0.title) \($0.id)" }.joined(separator: ", ")) }
    throw NotesError(description: "Source not found: \(reference). Use a name or id from abdy calendar calendars --json")
}

func resolveReminders(_ store: EventStore, _ references: [String]) throws -> [ReminderItem] {
    let all = try store.reminders(listIDs: nil)
    return try references.map { reference in
        if let exact = all.first(where: { $0.id == reference }) { return exact }
        guard reference.count >= 8 else { throw NotesError(description: "Reminder not found: \(reference). Use a UUID or its prefix of at least 8 characters from abdy reminders ls") }
        let matches = all.filter { $0.id.lowercased().hasPrefix(reference.lowercased()) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw NotesError(description: "Reminder prefix is ambiguous: \(reference). Use a longer prefix or the UUID") }
        throw NotesError(description: "Reminder not found: \(reference). Use a UUID or its prefix of at least 8 characters from abdy reminders ls")
    }
}

func resolveEvents(_ store: EventStore, _ references: [String], occurrence: Date?) throws -> [EventItem] {
    var window: [EventItem]?
    return try references.map { reference in
        if let exact = try store.event(reference, occurrence: occurrence) { return exact }
        guard reference.count >= 8 else { throw NotesError(description: "Event not found: \(reference). Use a UUID or its prefix of at least 8 characters from abdy calendar events") }
        if window == nil { window = try store.events(from: Date().addingTimeInterval(-366 * 86400), to: Date().addingTimeInterval(2 * 366 * 86400), calendarIDs: nil) }
        let ids = Set(window!.filter { $0.id.lowercased().hasPrefix(reference.lowercased()) }.map(\.id))
        if ids.count > 1 { throw NotesError(description: "Event prefix is ambiguous: \(reference). Use a longer prefix or the UUID") }
        guard let id = ids.first, let event = try store.event(id, occurrence: occurrence) else {
            throw NotesError(description: "Event not found: \(reference). Prefixes match events from 1 year ago to 2 years ahead, use the UUID from abdy calendar events otherwise")
        }
        return event
    }
}

func eventJSON<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder.events().encode(value), options: .fragmentsAllowed)
}
