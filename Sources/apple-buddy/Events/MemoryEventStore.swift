import Foundation

final class MemoryEventStore: EventStore {
    struct State: Codable {
        var access: [String: String] = [:]
        var sources: [EventSource] = [EventSource(id: "source-local", title: "On My Mac", type: "local"), EventSource(id: "source-sub", title: "Subscribed Calendars", type: "subscribed")]
        var calendars: [EventCalendar] = []
        var reminders: [ReminderItem] = []
        var sections: [ReminderSection] = []
        var events: [EventItem] = []
    }

    private let file: URL
    private var state: State

    init(file: URL) {
        self.file = file
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        state = (try? Data(contentsOf: file)).flatMap { try? decoder.decode(State.self, from: $0) } ?? State()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: file, options: .atomic)
    }

    func accessStatus(_ kind: ItemKind) -> String { state.access[kind.rawValue] ?? "notDetermined" }

    func requestAccess(_ kind: ItemKind) throws -> Bool {
        state.access[kind.rawValue] = "fullAccess"
        try persist()
        return true
    }

    func sources() throws -> [EventSource] { state.sources }

    func calendars(_ kind: ItemKind) throws -> [EventCalendar] { state.calendars.filter { $0.kind == kind } }

    func createCalendar(_ title: String, kind: ItemKind, sourceID: String?) throws -> EventCalendar {
        let source = try state.sources.first { $0.id == (sourceID ?? "source-local") } ?? { throw NotesError(description: "Source not found: \(sourceID ?? "")") }()
        let calendar = EventCalendar(id: UUID().uuidString, title: title, kind: kind, source: source.title, sourceID: source.id, type: source.type == "subscribed" ? "subscription" : "local",
                                     color: nil, readOnly: source.type == "subscribed", isDefault: state.calendars.filter { $0.kind == kind }.isEmpty)
        state.calendars.append(calendar)
        try persist()
        return calendar
    }

    func renameCalendar(_ id: String, to title: String) throws -> EventCalendar {
        guard let index = state.calendars.firstIndex(where: { $0.id == id }) else { throw NotesError(description: "Calendar not found: \(id)") }
        state.calendars[index].title = title
        try persist()
        return state.calendars[index]
    }

    func removeCalendar(_ id: String) throws {
        guard state.calendars.contains(where: { $0.id == id }) else { throw NotesError(description: "Calendar not found: \(id)") }
        state.calendars.removeAll { $0.id == id }
        state.reminders.removeAll { $0.listID == id }
        state.events.removeAll { $0.calendarID == id }
        try persist()
    }

    func reminders(listIDs: [String]?) throws -> [ReminderItem] {
        guard let listIDs else { return state.reminders }
        return state.reminders.filter { listIDs.contains($0.listID) }
    }

    func reminder(_ id: String) throws -> ReminderItem? { state.reminders.first { $0.id == id } }

    func saveReminders(_ items: [ReminderItem]) throws -> [ReminderItem] {
        var next = state
        var saved: [ReminderItem] = []
        for var item in items {
            guard let list = next.calendars.first(where: { $0.id == item.listID && $0.kind == .reminder }) else { throw NotesError(description: "List not found: \(item.listID)") }
            guard !list.readOnly else { throw NotesError(description: "List \(list.title) is read-only") }
            item.list = list.title
            item.modified = Date()
            if let parent = item.parentID, !next.reminders.contains(where: { $0.id == parent }) { throw NotesError(description: "Reminder not found in Reminders: \(parent)") }
            if let sectionID = item.sectionID {
                guard let section = next.sections.first(where: { $0.id == sectionID }) else { throw NotesError(description: "Section not found: \(sectionID)") }
                item.section = section.listID == item.listID ? section.title : nil
                if item.section == nil { item.sectionID = nil }
            } else { item.section = nil }
            if item.id.isEmpty {
                item.id = UUID().uuidString
                item.created = item.modified
                next.reminders.append(item)
            } else {
                guard let index = next.reminders.firstIndex(where: { $0.id == item.id }) else { throw NotesError(description: "Reminder not found: \(item.id)") }
                next.reminders[index] = item
            }
            saved.append(item)
        }
        state = next
        try persist()
        return saved
    }

    func removeReminders(_ ids: [String]) throws {
        var next = state
        for id in ids {
            guard next.reminders.contains(where: { $0.id == id }) else { throw NotesError(description: "Reminder not found: \(id)") }
            next.reminders.removeAll { $0.id == id || $0.parentID == id }
        }
        state = next
        try persist()
    }

    private func reminderIndex(_ id: String) throws -> Int {
        guard let index = state.reminders.firstIndex(where: { $0.id == id }) else { throw NotesError(description: "Reminder not found in Reminders: \(id)") }
        return index
    }

    func addAttachment(_ reminderID: String, file: String?, url: String?) throws -> ReminderAttachment {
        let index = try reminderIndex(reminderID)
        var attachment = ReminderAttachment(id: UUID().uuidString, kind: .url, url: url)
        if let file {
            let source = try AttachmentFile(file)
            let folder = self.file.deletingPathExtension().appendingPathExtension("files")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(attachment.id).appendingPathExtension(URL(fileURLWithPath: source.path).pathExtension)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path), to: copy)
            let size = try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? Int
            attachment = ReminderAttachment(id: attachment.id, kind: source.width > 0 ? .image : .file, uti: source.uti, name: copy.lastPathComponent, path: copy.path, size: size,
                                            width: source.width > 0 ? source.width : nil, height: source.width > 0 ? source.height : nil, url: nil)
        } else {
            guard let url, URL(string: url)?.scheme != nil else { throw NotesError(description: "Not a valid URL: \(url ?? "")") }
        }
        state.reminders[index].attachments.append(attachment)
        try persist()
        return attachment
    }

    func removeAttachment(_ reminderID: String, attachment: String) throws {
        let index = try reminderIndex(reminderID)
        guard state.reminders[index].attachments.contains(where: { $0.id == attachment }) else { throw NotesError(description: "Attachment not found in this reminder: \(attachment)") }
        state.reminders[index].attachments.removeAll { $0.id == attachment }
        try persist()
    }

    func sections(listID: String) throws -> [ReminderSection] {
        guard state.calendars.contains(where: { $0.id == listID && $0.kind == .reminder }) else { throw NotesError(description: "List not found in Reminders: \(listID)") }
        return state.sections.filter { $0.listID == listID }
    }

    func createSection(listID: String, title: String) throws -> ReminderSection {
        _ = try sections(listID: listID)
        let section = ReminderSection(id: UUID().uuidString, title: title, listID: listID)
        state.sections.append(section)
        try persist()
        return section
    }

    private func sectionIndex(_ id: String) throws -> Int {
        guard let index = state.sections.firstIndex(where: { $0.id == id }) else { throw NotesError(description: "Section not found: \(id)") }
        return index
    }

    func renameSection(_ id: String, to title: String) throws -> ReminderSection {
        let index = try sectionIndex(id)
        state.sections[index].title = title
        for reminder in state.reminders.indices where state.reminders[reminder].sectionID == id { state.reminders[reminder].section = title }
        try persist()
        return state.sections[index]
    }

    func removeSection(_ id: String) throws {
        state.sections.remove(at: try sectionIndex(id))
        for reminder in state.reminders.indices where state.reminders[reminder].sectionID == id {
            state.reminders[reminder].sectionID = nil
            state.reminders[reminder].section = nil
        }
        try persist()
    }

    private static func occurrences(of event: EventItem, from: Date, to: Date) -> [EventItem] {
        guard let recurrence = event.recurrence else { return event.end > from && event.start < to ? [event] : [] }
        let component: Calendar.Component
        switch recurrence.frequency {
        case .daily: component = .day
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .yearly: component = .year
        }
        var result: [EventItem] = []
        let length = event.end.timeIntervalSince(event.start)
        for index in 0..<1000 {
            guard let start = Calendar.current.date(byAdding: component, value: index * recurrence.interval, to: event.start) else { break }
            if let count = recurrence.count, index >= count { break }
            if let until = recurrence.until, start > until { break }
            if start >= to { break }
            var instance = event
            instance.start = start
            instance.end = start.addingTimeInterval(length)
            instance.occurrence = start
            if instance.end > from { result.append(instance) }
        }
        return result
    }

    func events(from: Date, to: Date, calendarIDs: [String]?) throws -> [EventItem] {
        state.events.filter { calendarIDs == nil || calendarIDs!.contains($0.calendarID) }
            .filter { !($0.isDetached && $0.status == "canceled") }
            .flatMap { Self.occurrences(of: $0, from: from, to: to) }
            .filter { instance in !state.events.contains { $0.isDetached && $0.id == instance.id && $0.occurrence == instance.occurrence && !instance.isDetached } }
            .sorted { $0.start < $1.start }
    }

    func event(_ id: String, occurrence: Date?) throws -> EventItem? {
        if let occurrence {
            if let detached = state.events.first(where: { $0.id == id && $0.isDetached && $0.occurrence == occurrence }) { return detached }
            guard let master = state.events.first(where: { $0.id == id && !$0.isDetached }) else { return nil }
            return Self.occurrences(of: master, from: occurrence, to: occurrence.addingTimeInterval(1)).first
        }
        return state.events.first { $0.id == id && !$0.isDetached }
    }

    func saveEvents(_ items: [EventItem], span: EditSpan) throws -> [EventItem] {
        var next = state
        var saved: [EventItem] = []
        for var item in items {
            guard let calendar = next.calendars.first(where: { $0.id == item.calendarID && $0.kind == .event }) else { throw NotesError(description: "Calendar not found: \(item.calendarID)") }
            guard !calendar.readOnly else { throw NotesError(description: "Calendar \(calendar.title) is read-only") }
            item.calendar = calendar.title
            item.modified = Date()
            if item.id.isEmpty {
                item.id = UUID().uuidString
                item.created = item.modified
                item.isDetached = false
                next.events.append(item)
            } else if let occurrence = item.occurrence, let master = next.events.firstIndex(where: { $0.id == item.id && !$0.isDetached }), next.events[master].recurrence != nil {
                if span == .future {
                    var remaining = next.events[master]
                    let before = Self.occurrences(of: remaining, from: .distantPast, to: occurrence).count
                    remaining.recurrence?.until = occurrence.addingTimeInterval(-1)
                    remaining.recurrence?.count = nil
                    next.events[master] = remaining
                    if let count = item.recurrence?.count { item.recurrence?.count = max(count - before, 1) }
                    item.id = UUID().uuidString
                    item.occurrence = nil
                    item.isDetached = false
                    next.events.append(item)
                } else {
                    item.isDetached = true
                    item.recurrence = nil
                    next.events.removeAll { $0.id == item.id && $0.isDetached && $0.occurrence == occurrence }
                    next.events.append(item)
                }
            } else {
                guard let index = next.events.firstIndex(where: { $0.id == item.id && $0.isDetached == item.isDetached && $0.occurrence == item.occurrence }) else { throw NotesError(description: "Event not found: \(item.id)") }
                next.events[index] = item
            }
            saved.append(item)
        }
        state = next
        try persist()
        return saved
    }

    func removeEvents(_ items: [EventItem], span: EditSpan) throws {
        var next = state
        for item in items {
            guard let master = next.events.firstIndex(where: { $0.id == item.id && !$0.isDetached }) else { throw NotesError(description: "Event not found: \(item.id)") }
            if let occurrence = item.occurrence, next.events[master].recurrence != nil {
                if span == .future {
                    next.events[master].recurrence?.until = occurrence.addingTimeInterval(-1)
                    next.events[master].recurrence?.count = nil
                } else {
                    var tombstone = next.events[master]
                    tombstone.isDetached = true
                    tombstone.occurrence = occurrence
                    tombstone.title = ""
                    tombstone.status = "canceled"
                    next.events.removeAll { $0.id == item.id && $0.isDetached && $0.occurrence == occurrence }
                    next.events.append(tombstone)
                }
            } else {
                next.events.removeAll { $0.id == item.id }
            }
        }
        state = next
        try persist()
    }
}
