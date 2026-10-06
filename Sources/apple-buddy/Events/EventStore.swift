import AppKit
import CoreLocation
import EventKit
import Foundation
import ImageIO
import RemindersNative
import UniformTypeIdentifiers

protocol EventStore {
    func accessStatus(_ kind: ItemKind) -> String
    func requestAccess(_ kind: ItemKind) throws -> Bool
    func sources() throws -> [EventSource]
    func calendars(_ kind: ItemKind) throws -> [EventCalendar]
    func createCalendar(_ title: String, kind: ItemKind, sourceID: String?) throws -> EventCalendar
    func renameCalendar(_ id: String, to title: String) throws -> EventCalendar
    func removeCalendar(_ id: String) throws
    func reminders(listIDs: [String]?) throws -> [ReminderItem]
    func reminder(_ id: String) throws -> ReminderItem?
    func saveReminders(_ items: [ReminderItem]) throws -> [ReminderItem]
    func removeReminders(_ ids: [String]) throws
    func addAttachment(_ reminderID: String, file: String?, url: String?) throws -> ReminderAttachment
    func removeAttachment(_ reminderID: String, attachment: String) throws
    func sections(listID: String) throws -> [ReminderSection]
    func createSection(listID: String, title: String) throws -> ReminderSection
    func renameSection(_ id: String, to title: String) throws -> ReminderSection
    func removeSection(_ id: String) throws
    func events(from: Date, to: Date, calendarIDs: [String]?) throws -> [EventItem]
    func event(_ id: String, occurrence: Date?) throws -> EventItem?
    func saveEvents(_ items: [EventItem], span: EditSpan) throws -> [EventItem]
    func removeEvents(_ items: [EventItem], span: EditSpan) throws
}

func openEventStore() -> EventStore {
    if let path = ProcessInfo.processInfo.environment["ABDY_EVENT_STORE_FILE"] { return MemoryEventStore(file: URL(fileURLWithPath: path)) }
    return SystemEventStore()
}

struct AttachmentFile {
    let path: String
    let uti: String
    let width: Int
    let height: Int

    init(_ file: String) throws {
        path = try readableFilePath(file)
        let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) ?? .data
        uti = type.identifier
        var size = (0, 0)
        if type.conforms(to: .image), let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            size = (width, height)
        }
        width = size.0
        height = size.1
    }
}

func requireAccess(_ store: EventStore, _ kind: ItemKind) throws {
    let status = store.accessStatus(kind)
    guard status == "fullAccess" else {
        let group = kind == .reminder ? "reminders" : "calendar"
        let holder = ProcessInfo.processInfo.environment["ABDY_IN_APP"] != nil ? " for Abdy.app" : ""
        throw NotesError(description: "\(kind == .reminder ? "Reminders" : "Calendar") access is \(status)\(holder). Run abdy \(group) access and allow it in the system dialog, or enable it in System Settings, Privacy and Security")
    }
}

final class SystemEventStore: EventStore {
    private var store = EKEventStore()
    private var kit: ABReminderKit?

    private func reminderKit() throws -> ABReminderKit {
        if let kit { return kit }
        let opened = try ABReminderKit.open()
        kit = opened
        return opened
    }

    private static func entity(_ kind: ItemKind) -> EKEntityType { kind == .reminder ? .reminder : .event }

    func accessStatus(_ kind: ItemKind) -> String {
        switch EKEventStore.authorizationStatus(for: Self.entity(kind)) {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess, .authorized: return "fullAccess"
        case .writeOnly: return "writeOnly"
        @unknown default: return "unknown"
        }
    }

    func requestAccess(_ kind: ItemKind) throws -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        var failure: Error?
        let completion: (Bool, Error?) -> Void = { ok, error in granted = ok; failure = error; semaphore.signal() }
        if kind == .reminder { store.requestFullAccessToReminders(completion: completion) } else { store.requestFullAccessToEvents(completion: completion) }
        let deadline = Date().addingTimeInterval(300)
        while semaphore.wait(timeout: .now()) == .timedOut {
            guard Date() < deadline else { throw NotesError(description: "No answer to the access request within 5 minutes") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let failure { throw NotesError(description: "Access request failed: \(failure.localizedDescription)") }
        store = EKEventStore()
        return granted
    }

    func sources() throws -> [EventSource] {
        store.sources.map { EventSource(id: $0.sourceIdentifier, title: $0.title, type: Self.sourceType($0.sourceType)) }
    }

    private static func sourceType(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "iCloud"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "other"
        }
    }

    private static func calendarType(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "calDAV"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "other"
        }
    }

    private func describe(_ calendar: EKCalendar, kind: ItemKind) -> EventCalendar {
        let fallback = kind == .reminder ? store.defaultCalendarForNewReminders() : store.defaultCalendarForNewEvents
        var color: String?
        if let components = calendar.color?.usingColorSpace(.sRGB) {
            color = String(format: "#%02X%02X%02X", Int(components.redComponent * 255), Int(components.greenComponent * 255), Int(components.blueComponent * 255))
        }
        return EventCalendar(id: calendar.calendarIdentifier, title: calendar.title, kind: kind, source: calendar.source?.title ?? "", sourceID: calendar.source?.sourceIdentifier ?? "",
                             type: Self.calendarType(calendar.type), color: color, readOnly: !calendar.allowsContentModifications, isDefault: calendar.calendarIdentifier == fallback?.calendarIdentifier)
    }

    func calendars(_ kind: ItemKind) throws -> [EventCalendar] {
        store.calendars(for: Self.entity(kind)).map { describe($0, kind: kind) }
    }

    private func calendar(_ id: String, kind: ItemKind) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id), store.calendars(for: Self.entity(kind)).contains(calendar) else {
            throw NotesError(description: "\(kind == .reminder ? "List" : "Calendar") not found: \(id)")
        }
        return calendar
    }

    func createCalendar(_ title: String, kind: ItemKind, sourceID: String?) throws -> EventCalendar {
        let calendar = EKCalendar(for: Self.entity(kind), eventStore: store)
        calendar.title = title
        if let sourceID {
            guard let source = store.source(withIdentifier: sourceID) else { throw NotesError(description: "Source not found: \(sourceID)") }
            calendar.source = source
        } else {
            let fallback = kind == .reminder ? store.defaultCalendarForNewReminders() : store.defaultCalendarForNewEvents
            guard let source = fallback?.source else { throw NotesError(description: "No default \(kind == .reminder ? "reminder list" : "calendar") source, pass --source") }
            calendar.source = source
        }
        try store.saveCalendar(calendar, commit: true)
        return describe(calendar, kind: kind)
    }

    func renameCalendar(_ id: String, to title: String) throws -> EventCalendar {
        guard let calendar = store.calendar(withIdentifier: id) else { throw NotesError(description: "Calendar not found: \(id)") }
        calendar.title = title
        try store.saveCalendar(calendar, commit: true)
        return describe(calendar, kind: calendar.allowedEntityTypes.contains(.reminder) ? .reminder : .event)
    }

    func removeCalendar(_ id: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else { throw NotesError(description: "Calendar not found: \(id)") }
        try store.removeCalendar(calendar, commit: true)
    }

    private func describe(_ reminder: EKReminder, details: [String: Any]) -> ReminderItem {
        var due: Date?
        var hasTime = false
        if let components = reminder.dueDateComponents {
            due = Calendar.current.date(from: components)
            hasTime = components.hour != nil
        }
        let attachments = (details["attachments"] as? [[String: Any]] ?? []).compactMap { value -> ReminderAttachment? in
            guard let id = value["id"] as? String, let kind = (value["kind"] as? String).flatMap(ReminderAttachment.Kind.init) else { return nil }
            return ReminderAttachment(id: id, kind: kind, uti: value["uti"] as? String, name: value["name"] as? String, path: value["path"] as? String,
                                      size: value["size"] as? Int, width: value["width"] as? Int, height: value["height"] as? Int, url: value["url"] as? String)
        }
        return ReminderItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes, listID: reminder.calendar.calendarIdentifier, list: reminder.calendar.title, due: due, dueHasTime: hasTime,
                            priority: reminder.priority, completed: reminder.isCompleted, completionDate: reminder.completionDate, url: reminder.url?.absoluteString,
                            alarms: (reminder.alarms ?? []).filter { $0.structuredLocation == nil }.map { Int(-$0.relativeOffset / 60) }, location: (reminder.alarms ?? []).compactMap(Self.locationAlarm).first,
                            recurrence: reminder.recurrenceRules?.first.map(Self.describe), flagged: details["flagged"] as? Bool ?? false, tags: details["tags"] as? [String] ?? [],
                            parentID: details["parent"] as? String, sectionID: details["sectionID"] as? String, section: details["section"] as? String, attachments: attachments,
                            created: reminder.creationDate, modified: reminder.lastModifiedDate)
    }

    private func details(_ ids: [String]?) throws -> [String: [String: Any]] {
        try reminderKit().details(forReminders: ids) as? [String: [String: Any]] ?? [:]
    }

    private static func locationAlarm(_ alarm: EKAlarm) -> LocationAlarm? {
        guard let place = alarm.structuredLocation, let point = place.geoLocation else { return nil }
        return LocationAlarm(title: place.title ?? "", latitude: point.coordinate.latitude, longitude: point.coordinate.longitude, radius: place.radius, proximity: alarm.proximity == .leave ? .leave : .arrive)
    }

    private static func describe(_ rule: EKRecurrenceRule) -> Recurrence {
        let frequency: Recurrence.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: frequency = .daily
        }
        return Recurrence(frequency: frequency, interval: rule.interval, until: rule.recurrenceEnd?.endDate, count: rule.recurrenceEnd.map { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil } ?? nil)
    }

    private static func rule(_ recurrence: Recurrence) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch recurrence.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        var end: EKRecurrenceEnd?
        if let until = recurrence.until { end = EKRecurrenceEnd(end: until) }
        if let count = recurrence.count { end = EKRecurrenceEnd(occurrenceCount: count) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: recurrence.interval, end: end)
    }

    func reminders(listIDs: [String]?) throws -> [ReminderItem] {
        var calendars: [EKCalendar]?
        if let listIDs { calendars = try listIDs.map { try calendar($0, kind: .reminder) } }
        let predicate = store.predicateForReminders(in: calendars)
        let semaphore = DispatchSemaphore(value: 0)
        var found: [EKReminder] = []
        store.fetchReminders(matching: predicate) { reminders in found = reminders ?? []; semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 60) == .success else { throw NotesError(description: "Reminders did not answer within 60 seconds") }
        let extras = try details(nil)
        return found.map { describe($0, details: extras[$0.calendarItemIdentifier] ?? [:]) }
    }

    func reminder(_ id: String) throws -> ReminderItem? {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return describe(reminder, details: try details([id])[id] ?? [:])
    }

    private func reminderKitOptions(_ item: ReminderItem, current: [String: Any]) -> [String: Any] {
        var options: [String: Any] = [:]
        if item.flagged != (current["flagged"] as? Bool ?? false) { options["flagged"] = item.flagged }
        if Set(item.tags) != Set(current["tags"] as? [String] ?? []) { options["tags"] = item.tags }
        if item.parentID != current["parent"] as? String {
            if let parent = item.parentID { options["parent"] = parent } else { options["clearParent"] = true }
        }
        if item.sectionID != current["sectionID"] as? String {
            if let section = item.sectionID { options["section"] = section } else { options["clearSection"] = true }
        }
        return options
    }

    private func apply(_ item: ReminderItem, to reminder: EKReminder) throws {
        reminder.title = item.title
        reminder.notes = item.notes
        reminder.calendar = try calendar(item.listID, kind: .reminder)
        if let due = item.due {
            let parts: Set<Calendar.Component> = item.dueHasTime ? [.year, .month, .day, .hour, .minute, .second] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due)
        } else {
            reminder.dueDateComponents = nil
        }
        reminder.priority = item.priority
        reminder.isCompleted = item.completed
        if item.completed, let date = item.completionDate { reminder.completionDate = date }
        reminder.url = item.url.flatMap(URL.init(string:))
        for alarm in reminder.alarms ?? [] { reminder.removeAlarm(alarm) }
        for minutes in item.alarms { reminder.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60))) }
        if let location = item.location {
            let place = EKStructuredLocation(title: location.title)
            place.geoLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
            place.radius = location.radius
            let alarm = EKAlarm()
            alarm.structuredLocation = place
            alarm.proximity = location.proximity == .leave ? .leave : .enter
            reminder.addAlarm(alarm)
        }
        if reminder.recurrenceRules?.first.map(Self.describe) != item.recurrence {
            for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
            if let recurrence = item.recurrence { reminder.addRecurrenceRule(Self.rule(recurrence)) }
        }
    }

    func saveReminders(_ items: [ReminderItem]) throws -> [ReminderItem] {
        var saved: [(EKReminder, ReminderItem)] = []
        let existing = try details(items.filter { !$0.id.isEmpty }.map(\.id))
        do {
            for var item in items {
                let reminder: EKReminder
                if item.id.isEmpty, let parent = item.parentID {
                    item.id = try reminderKit().createSubtask(item.title, parent: parent)
                    store.refreshSourcesIfNecessary()
                    guard let created = store.calendarItem(withIdentifier: item.id) as? EKReminder else { throw NotesError(description: "Reminders created subtask \(item.id) but EventKit cannot read it") }
                    reminder = created
                } else if item.id.isEmpty { reminder = EKReminder(eventStore: store) } else {
                    guard let found = store.calendarItem(withIdentifier: item.id) as? EKReminder else { throw NotesError(description: "Reminder not found: \(item.id)") }
                    reminder = found
                }
                try apply(item, to: reminder)
                try store.save(reminder, commit: false)
                saved.append((reminder, item))
            }
            try store.commit()
        } catch { store.reset(); throw error }
        for (reminder, item) in saved {
            var current = existing[item.id] ?? [:]
            if item.parentID != nil && existing[item.id] == nil { current["parent"] = item.parentID }
            let options = reminderKitOptions(item, current: current)
            if !options.isEmpty { try reminderKit().updateReminder(reminder.calendarItemIdentifier, options: options) }
        }
        let fresh = try details(saved.map { $0.0.calendarItemIdentifier })
        return saved.map { describe($0.0, details: fresh[$0.0.calendarItemIdentifier] ?? [:]) }
    }

    func removeReminders(_ ids: [String]) throws {
        do {
            for id in ids {
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw NotesError(description: "Reminder not found: \(id)") }
                try store.remove(reminder, commit: false)
            }
            try store.commit()
        } catch { store.reset(); throw error }
    }

    private static func attachment(_ value: [String: Any]) -> ReminderAttachment {
        ReminderAttachment(id: value["id"] as? String ?? "", kind: (value["kind"] as? String).flatMap(ReminderAttachment.Kind.init) ?? .file, uti: value["uti"] as? String, name: value["name"] as? String,
                           path: value["path"] as? String, size: value["size"] as? Int, width: value["width"] as? Int, height: value["height"] as? Int, url: value["url"] as? String)
    }

    func addAttachment(_ reminderID: String, file: String?, url: String?) throws -> ReminderAttachment {
        let source = try file.map(AttachmentFile.init)
        let value = try reminderKit().addAttachment(toReminder: reminderID, file: source?.path, uti: source?.uti, width: source?.width ?? 0, height: source?.height ?? 0, url: url)
        return Self.attachment(value as? [String: Any] ?? [:])
    }

    func removeAttachment(_ reminderID: String, attachment: String) throws {
        try reminderKit().removeAttachment(attachment, fromReminder: reminderID)
    }

    private static func section(_ value: Any) -> ReminderSection {
        let dictionary = value as? [String: Any] ?? [:]
        return ReminderSection(id: dictionary["id"] as? String ?? "", title: dictionary["title"] as? String ?? "", listID: dictionary["listID"] as? String ?? "")
    }

    func sections(listID: String) throws -> [ReminderSection] {
        try reminderKit().sections(inList: listID).map(Self.section)
    }

    func createSection(listID: String, title: String) throws -> ReminderSection {
        Self.section(try reminderKit().createSection(title, inList: listID))
    }

    func renameSection(_ id: String, to title: String) throws -> ReminderSection {
        Self.section(try reminderKit().renameSection(id, to: title))
    }

    func removeSection(_ id: String) throws {
        try reminderKit().removeSection(id)
    }

    private static func status(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "other"
        }
    }

    private static func attendee(_ participant: EKParticipant) -> Attendee {
        let status: String
        switch participant.participantStatus {
        case .accepted: status = "accepted"
        case .declined: status = "declined"
        case .tentative: status = "tentative"
        case .pending: status = "pending"
        case .delegated: status = "delegated"
        case .completed: status = "completed"
        case .inProcess: status = "inProcess"
        case .unknown: status = "unknown"
        @unknown default: status = "unknown"
        }
        let role: String
        switch participant.participantRole {
        case .chair: role = "chair"
        case .required: role = "required"
        case .optional: role = "optional"
        case .nonParticipant: role = "nonParticipant"
        case .unknown: role = "unknown"
        @unknown default: role = "unknown"
        }
        let email = participant.url.absoluteString.hasPrefix("mailto:") ? String(participant.url.absoluteString.dropFirst("mailto:".count)) : nil
        return Attendee(name: participant.name, email: email, status: status, role: role)
    }

    private func describe(_ event: EKEvent) -> EventItem {
        EventItem(id: event.calendarItemIdentifier, title: event.title ?? "", calendarID: event.calendar.calendarIdentifier, calendar: event.calendar.title, start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                  location: event.location, notes: event.notes, url: event.url?.absoluteString, alarms: (event.alarms ?? []).map { Int(-$0.relativeOffset / 60) },
                  recurrence: event.recurrenceRules?.first.map(Self.describe), occurrence: event.hasRecurrenceRules || event.isDetached ? event.occurrenceDate : nil, isDetached: event.isDetached,
                  status: Self.status(event.status), organizer: event.organizer.map { $0.name ?? $0.url.absoluteString }, attendees: (event.attendees ?? []).map(Self.attendee),
                  created: event.creationDate, modified: event.lastModifiedDate)
    }

    func events(from: Date, to: Date, calendarIDs: [String]?) throws -> [EventItem] {
        var calendars: [EKCalendar]?
        if let calendarIDs { calendars = try calendarIDs.map { try calendar($0, kind: .event) } }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.map(describe)
    }

    private func occurrence(_ id: String, at date: Date?) -> EKEvent? {
        guard let date else { return store.calendarItem(withIdentifier: id) as? EKEvent }
        let predicate = store.predicateForEvents(withStart: date, end: date.addingTimeInterval(1), calendars: nil)
        return store.events(matching: predicate).first { $0.calendarItemIdentifier == id && $0.occurrenceDate == date }
    }

    func event(_ id: String, occurrence date: Date?) throws -> EventItem? {
        occurrence(id, at: date).map(describe)
    }

    private func apply(_ item: EventItem, to event: EKEvent) throws {
        event.title = item.title
        event.calendar = try calendar(item.calendarID, kind: .event)
        event.startDate = item.start
        event.endDate = item.end
        event.isAllDay = item.allDay
        event.location = item.location
        event.notes = item.notes
        event.url = item.url.flatMap(URL.init(string:))
        for alarm in event.alarms ?? [] { event.removeAlarm(alarm) }
        for minutes in item.alarms { event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60))) }
        if event.recurrenceRules?.first.map(Self.describe) != item.recurrence {
            for rule in event.recurrenceRules ?? [] { event.removeRecurrenceRule(rule) }
            if let recurrence = item.recurrence { event.addRecurrenceRule(Self.rule(recurrence)) }
        }
    }

    func saveEvents(_ items: [EventItem], span: EditSpan) throws -> [EventItem] {
        var saved: [EKEvent] = []
        do {
            for item in items {
                let event: EKEvent
                if item.id.isEmpty { event = EKEvent(eventStore: store) } else {
                    guard let existing = occurrence(item.id, at: item.occurrence) else { throw NotesError(description: "Event not found: \(item.id)") }
                    event = existing
                }
                try apply(item, to: event)
                try store.save(event, span: span == .future ? .futureEvents : .thisEvent, commit: false)
                saved.append(event)
            }
            try store.commit()
        } catch { store.reset(); throw error }
        return saved.map(describe)
    }

    func removeEvents(_ items: [EventItem], span: EditSpan) throws {
        do {
            for item in items {
                guard let event = occurrence(item.id, at: item.occurrence) else { throw NotesError(description: "Event not found: \(item.id)") }
                try store.remove(event, span: span == .future ? .futureEvents : .thisEvent, commit: false)
            }
            try store.commit()
        } catch { store.reset(); throw error }
    }
}
