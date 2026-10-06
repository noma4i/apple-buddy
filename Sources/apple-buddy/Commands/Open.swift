import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

struct OpenNote: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @OptionGroup var note: LocalNoteOptions
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a note in Apple Notes",
        discussion: """
        Opens the selected note in the foreground and leaves Notes running. Does not change the note.
        --window opens the note in its own window and closes the main Notes window that the command opened.
        A main window that was open before the command stays. --window needs Accessibility access for the terminal application,
        macOS asks for it once, or enable it in System Settings, Privacy and Security, Accessibility.

        EXAMPLES
          abdy notes open <id>
          abdy notes open <id> --window
        """
    )
    @Flag(help: "Open the note in its own window instead of the main Notes window") var window = false

    func run() throws {
        let store = try note.open(readOnly: true)
        guard var data = try store.noteOpenDetails(note.id) as? [String: Any],
              let address = data["url"] as? String, let url = URL(string: address),
              let id = data["id"] as? String else { throw NotesError(description: "Notes returned no note URL") }
        if window {
            try NotesWindow.requireAccessibility()
            let mainWindowsBefore = NotesWindow.mainWindows()
            let application = try NotesWindow.open(url)
            let title = data["title"] as? String ?? ""
            if let item = NotesWindow.enabledMenuItem("Open Note in New Window", in: application, within: 3) {
                let windowsBefore = NotesWindow.windows(of: application).count
                guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { throw NotesError(description: "Notes refused to open the note in a new window") }
                try NotesWindow.wait("the note window") { NotesWindow.windows(of: application).count > windowsBefore }
            } else {
                guard NotesWindow.singleNoteWindows(of: application).contains(where: { (NotesWindow.attribute($0, kAXTitleAttribute) as? String) == title }) else {
                    throw NotesError(description: "Notes did not enable Open Note in New Window within 3 seconds")
                }
            }
            for main in NotesWindow.mainWindows() where !mainWindowsBefore.contains(where: { CFEqual($0, main) }) { NotesWindow.close(main) }
            data["window"] = true
        } else {
            guard NSWorkspace.shared.open(url) else { throw NotesError(description: "macOS refused to open the note URL") }
        }
        data["action"] = "open"
        data["requested"] = true
        try output.write(data, text: id)
        output.summary("open: \(data["title"] ?? "")" + (window ? " in its own window" : ""))
    }
}

enum NotesWindow {
    static let singleNoteIdentifier = "IMCSingleNoteWindowIdentifier"

    static func requireAccessibility() throws {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw NotesError(description: "--window needs Accessibility access for this terminal application. Allow it in the system dialog or in System Settings, Privacy and Security, Accessibility, then retry")
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    static func open(_ url: URL) throws -> AXUIElement {
        var opened: NSRunningApplication?
        var failure: Error?
        let group = DispatchGroup()
        group.enter()
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { app, error in opened = app; failure = error; group.leave() }
        while group.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if let failure { throw NotesError(description: "macOS refused to open the note URL: \(failure.localizedDescription)") }
        guard let opened else { throw NotesError(description: "macOS refused to open the note URL") }
        return AXUIElementCreateApplication(opened.processIdentifier)
    }

    static func wait(_ what: String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw NotesError(description: "Notes did not show \(what) within 10 seconds") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func enabledMenuItem(_ title: String, in application: AXUIElement, within seconds: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let item = menuItem(title, in: application), (attribute(item, kAXEnabledAttribute) as? Bool) == true { return item }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    static func singleNoteWindows(of application: AXUIElement) -> [AXUIElement] {
        windows(of: application).filter { (attribute($0, kAXIdentifierAttribute) as? String) == singleNoteIdentifier }
    }

    static func menuItem(_ title: String, in application: AXUIElement) -> AXUIElement? {
        guard let bar = attribute(application, kAXMenuBarAttribute) else { return nil }
        for menu in (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for list in (attribute(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for item in (attribute(list, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where (attribute(item, kAXTitleAttribute) as? String) == title { return item }
            }
        }
        return nil
    }

    static func windows(of application: AXUIElement) -> [AXUIElement] {
        (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func mainWindows() -> [AXUIElement] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").flatMap { app in
            windows(of: AXUIElementCreateApplication(app.processIdentifier)).filter {
                (attribute($0, kAXIdentifierAttribute) as? String) != singleNoteIdentifier && (attribute($0, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole
            }
        }
    }

    static func close(_ window: AXUIElement) {
        guard let button = attribute(window, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }
}
