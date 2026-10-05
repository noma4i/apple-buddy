import AppKit
import CoreData
import Darwin
import Foundation
import NotesNative
import XCTest

final class LocalNotesTests: XCTestCase {
    private var directory: URL!
    private var database: URL!
    private var noteID: String!
    private var targetID: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        database = directory.appendingPathComponent("NoteStore.sqlite")
        _ = dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_LAZY)
        let model = try XCTUnwrap(NBNotes.installedModel())
        let stores = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try stores.addPersistentStore(type: .sqlite, at: database, options: [NSPersistentHistoryTrackingKey: true])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = stores
        let accountClass = try XCTUnwrap(NSClassFromString("ICAccount") as? NSObject.Type)
        let account = try XCTUnwrap(accountClass.perform(NSSelectorFromString("newLocalAccountInContext:"), with: context)?.takeUnretainedValue() as? NSManagedObject)
        account.setValue(true, forKey: "didChooseToMigrate")
        account.setValue(true, forKey: "didFinishMigration")
        account.setValue(1, forKey: "accountType")
        let folderClass = try XCTUnwrap(NSClassFromString("ICFolder") as? NSObject.Type)
        let folder = try XCTUnwrap(folderClass.perform(NSSelectorFromString("newFolderWithIdentifier:account:"), with: UUID().uuidString, with: account)?.takeUnretainedValue() as? NSManagedObject)
        folder.setValue("Fixture", forKey: "title")
        XCTAssertTrue(folder.value(forKey: "canMoveAddOrDeleteContents") as? Bool == true, "accountType=\(String(describing: account.value(forKey: "accountType"))), folderType=\(String(describing: folder.value(forKey: "folderType")))")
        let cls = try XCTUnwrap(NSClassFromString("ICNote") as? NSObject.Type)
        let note = try XCTUnwrap(cls.perform(NSSelectorFromString("newEmptyNoteWithIdentifier:folder:"), with: UUID().uuidString, with: folder)?.takeUnretainedValue() as? NSManagedObject)
        let document = try XCTUnwrap(note.value(forKey: "mergeableString") as? NSObject)
        let content = NSMutableAttributedString(string: "Fixture\nAlpha bold omega\nSecond paragraph 😀\n")
        content.addAttribute(NSAttributedString.Key("TTHints"), value: 1, range: (content.string as NSString).range(of: "bold"))
        let attachment = try XCTUnwrap(note.perform(NSSelectorFromString("addAttachmentWithIdentifier:"), with: UUID().uuidString)?.takeUnretainedValue() as? NSManagedObject)
        attachment.setValue("public.data", forKey: "typeUTI")
        attachment.setValue("Zephyr indexed receipt", forKey: "ocrSummary")
        let attachmentType = try XCTUnwrap(NSClassFromString("ICTTAttachment") as? NSObject.Type)
        let marker = attachmentType.init()
        marker.setValue(attachment.value(forKey: "identifier"), forKey: "attachmentIdentifier")
        marker.setValue("public.data", forKey: "attachmentUTI")
        content.append(NSAttributedString(string: "\u{FFFC}\u{FFFC}", attributes: [NSAttributedString.Key("NSAttachment"): marker]))
        let selector = NSSelectorFromString("insertAttributedString:atIndex:")
        typealias Insert = @convention(c) (AnyObject, Selector, NSAttributedString, UInt) -> Void
        unsafeBitCast(document.method(for: selector), to: Insert.self)(document, selector, content, 0)
        _ = note.perform(NSSelectorFromString("didChangeNoteText"))
        _ = note.perform(NSSelectorFromString("saveNoteData"))
        let target = try XCTUnwrap(cls.perform(NSSelectorFromString("newEmptyNoteWithIdentifier:folder:"), with: UUID().uuidString, with: folder)?.takeUnretainedValue() as? NSManagedObject)
        target.setValue("Target", forKey: "title")
        try context.save()
        noteID = note.objectID.uriRepresentation().absoluteString
        targetID = target.objectID.uriRepresentation().absoluteString
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testCLISelectorsPrintOnlyURLsAndPreserveJSONDetails() throws {
        let container = directory.appendingPathComponent("Library/Group Containers/group.com.apple.notes")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        func run(_ arguments: [String], isolated: Bool = true) throws -> (String, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
            process.arguments = arguments
            if isolated {
                var environment = ProcessInfo.processInfo.environment
                environment["CFFIXED_USER_HOME"] = directory.path
                process.environment = environment
            }
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, error)
            return (text, error)
        }
        _ = try run(["snapshot-db", container.appendingPathComponent("NoteStore.sqlite").path, "--database", database.path], isolated: false)
        let publicIDs = try NBNotes(url: database, readOnly: true).publicIdentifiers(forIDs: [noteID, targetID])
        let publicNoteID = try XCTUnwrap(publicIDs[noteID])
        let publicTargetID = try XCTUnwrap(publicIDs[targetID])
        let found = try run(["search", "Fixtur", "--field", "title"])
        XCTAssertEqual(found.0, publicNoteID + "\n")
        XCTAssertEqual(found.1, "1 of 1 notes\n")
        let listed = try run(["ls", "--folder", "Fixture"])
        XCTAssertEqual(Set(listed.0.split(separator: "\n").map(String.init)), Set([publicNoteID, publicTargetID]))
        XCTAssertEqual(listed.1, "2 notes\n")
        let empty = try run(["search", "no-match-unique-xyz", "--field", "title"])
        XCTAssertEqual(empty.0, "")
        XCTAssertEqual(empty.1, "0 of 0 notes\n")
        let json = try run(["search", "Fixtur", "--field", "title", "--json"])
        let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.0.utf8)) as? [String: Any])
        XCTAssertEqual((value["notes"] as? [[String: Any]])?.first?["title"] as? String, "Fixture")
        XCTAssertEqual((value["documentErrors"] as? [Any])?.count, 0)
        XCTAssertTrue(json.1.isEmpty)
        let stats = try run(["stats", "--folder", "Fixture", "--json"])
        let statistics = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stats.0.utf8)) as? [String: Any])
        XCTAssertEqual(statistics["noteCount"] as? Int, 2)
        XCTAssertEqual(statistics["folderCount"] as? Int, 1)
        XCTAssertTrue(stats.1.isEmpty)
        let textStats = try run(["stats", "--folder", "Fixture"])
        XCTAssertTrue(textStats.0.contains("2 notes, 0 deleted notes, 1 folders"))
        XCTAssertTrue(textStats.0.contains("empty=false"))
        let shown = try run(["show", noteID, "--json"])
        let shownNote = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(shown.0.utf8)) as? [String: Any])
        XCTAssertEqual((shownNote["attachments"] as? [Any])?.count, 1)
        XCTAssertNotNil(shownNote["tags"])
        XCTAssertNotNil(shownNote["links"])
        XCTAssertNotNil(shownNote["tables"])
        let shownHTML = try run(["show", noteID, "--html", "--json"])
        let htmlNote = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(shownHTML.0.utf8)) as? [String: Any])
        XCTAssertNotNil(htmlNote["html"])
        XCTAssertEqual((htmlNote["attachments"] as? [Any])?.count, 1)
        let plainNote = try run(["show", noteID])
        XCTAssertTrue(plainNote.0.contains("Attachments:"))
        XCTAssertTrue(plainNote.0.contains("public.data"))
        XCTAssertTrue(plainNote.0.contains("not available locally"))
        let searchAttachment = (value["notes"] as? [[String: Any]])?.first?["attachments"] as? [[String: Any]]
        XCTAssertEqual(searchAttachment?.count, 1)
        XCTAssertEqual(searchAttachment?.first?["note"] as? String, publicNoteID)
        let listedJSON = try run(["ls", "--folder", "Fixture", "--json"])
        let listedNotes = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(listedJSON.0.utf8)) as? [[String: Any]])
        XCTAssertEqual((listedNotes.first { $0["id"] as? String == publicNoteID }?["attachments"] as? [Any])?.count, 1)
        let prefix = String(publicNoteID.prefix(8))
        XCTAssertEqual(try run(["show", prefix, "--json"]).0, shown.0)
        let foundID = try run(["search", prefix, "--field", "id"])
        XCTAssertEqual(foundID.0, publicNoteID + "\n")
        XCTAssertFalse(shown.0.contains("x-coredata"))
        let listedNote = try XCTUnwrap(listedNotes.first { $0["id"] as? String == publicNoteID })
        let searchNote = try XCTUnwrap((value["notes"] as? [[String: Any]])?.first)
        XCTAssertEqual(listedNote["folder"] as? String, shownNote["folder"] as? String)
        XCTAssertEqual(searchNote["folder"] as? String, shownNote["folder"] as? String)
        XCTAssertEqual(listedNote["folderPath"] as? String, "Fixture")
        XCTAssertEqual(searchNote["folderPath"] as? String, "Fixture")
    }

    func testNativeFolderAndNoteLifecyclePreservesRichTextAndTables() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let folder = try store.createFolder("Native destination", parent: nil)
        let child = try store.createFolder("Nested", parent: folder)
        XCTAssertThrowsError(try store.createFolder("Native destination", parent: nil))
        let id = try store.createNote(inFolder: folder, html: "<h1>Native title</h1><p>Alpha <b>bold</b></p><table><tr><td>A</td><td>B</td></tr></table>")
        let state = try store.readNote(id)
        XCTAssertEqual(state["title"] as? String, "Native title")
        XCTAssertTrue((state["text"] as? String)?.contains("Native title") == true)
        XCTAssertTrue((state["runs"] as? [[String: Any]])?.contains { ($0["text"] as? String)?.contains("bold") == true && $0["bold"] as? Bool == true } == true, "\(state["runs"] ?? "missing")")
        XCTAssertEqual(state["tables"] as? [[[String]]], [[["A", "B"]]])
        XCTAssertTrue(try store.html(forNote: id).contains("bold"))
        try store.moveNote(id, toFolder: child)
        XCTAssertEqual(try NBNotes(url: database, readOnly: true).readNote(id)["folderPath"] as? String, "Native destination/Nested")
        XCTAssertEqual(try store.listNotes(inFolder: child).count, 1)
        XCTAssertEqual(try store.listNotes(inFolder: folder).count, 0)
        XCTAssertThrowsError(try store.removeFolder(folder))
        XCTAssertThrowsError(try store.removeFolder(child))
        try store.deleteNote(id)
        XCTAssertEqual(try store.listNotes(inFolder: child).count, 0)
        try store.removeFolder(child)
        try store.removeFolder(folder)
        let folders = try NBNotes(url: database, readOnly: true).listFolders()
        XCTAssertFalse(folders.contains { ($0["id"] as? String) == folder || ($0["id"] as? String) == child })
    }

    func testEmptyActivityEventsDoNotCreateShutdownWritesAndPreserveDocument() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let objectID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
        let note = try context.existingObject(with: objectID)
        let original = try XCTUnwrap((note.value(forKey: "noteData") as? NSManagedObject)?.value(forKey: "data") as? Data)
        let document = try XCTUnwrap(note.value(forKey: "activityEventsDocument") as? NSObject)
        let orderedSet = try XCTUnwrap(document.value(forKey: "orderedSet") as? NSObject)
        _ = orderedSet.perform(NSSelectorFromString("addObject:"), with: "Fixture event")
        _ = orderedSet.perform(NSSelectorFromString("removeAllObjects"))
        let metadata = try XCTUnwrap(document.perform(NSSelectorFromString("serialize"))?.takeUnretainedValue() as? Data)
        note.setValue(metadata, forKey: "activityEventsData")
        try context.save()
        context.reset()
        try store.pruneEmptyActivityEvents()
        let reopened = try context.existingObject(with: objectID)
        XCTAssertNil(reopened.value(forKey: "activityEventsData"))
        XCTAssertEqual((reopened.value(forKey: "noteData") as? NSManagedObject)?.value(forKey: "data") as? Data, original)
        let cloudClass = try XCTUnwrap(NSClassFromString("ICCloudSyncingObject") as? NSObject.Type)
        for _ in 0..<2 {
            _ = cloudClass.perform(NSSelectorFromString("removeAllCloudSyncingObjectActivityEventsForUnsharedObjectsInContext:"), with: context)
            XCTAssertTrue(context.updatedObjects.isEmpty, "Notes shutdown must not write empty activity events again")
            try context.save()
            context.reset()
        }
        XCTAssertThrowsError(try NBNotes(url: database, readOnly: true).pruneEmptyActivityEvents())
    }

    func testMoveAndTrashAdvanceFolderModificationDateWithoutChangingDocument() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let destination = try store.createFolder("Sync destination", parent: nil)
        func state() throws -> (Date?, Data?) {
            let reopened = try NBNotes(url: database, readOnly: true)
            let context = try XCTUnwrap(reopened.value(forKey: "context") as? NSManagedObjectContext)
            let objectID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
            let note = try context.existingObject(with: objectID)
            let data = note.value(forKey: "noteData") as? NSManagedObject
            return (note.value(forKey: "folderModificationDate") as? Date, data?.value(forKey: "data") as? Data)
        }
        let original = try state()
        let moveStarted = Date()
        try store.moveNote(noteID, toFolder: destination)
        let moved = try state()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(moved.0), moveStarted)
        XCTAssertEqual(moved.1, original.1)
        let deleteStarted = Date()
        try store.deleteNote(noteID)
        let deleted = try state()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(deleted.0), deleteStarted)
        XCTAssertEqual(deleted.1, original.1)
    }

    func testActivityPreparationPreservesNonemptyAndProtectedEvents() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let id = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
        let note = try context.existingObject(with: id)
        let document = try XCTUnwrap(note.value(forKey: "activityEventsDocument") as? NSObject)
        let events = try XCTUnwrap(document.value(forKey: "orderedSet") as? NSObject)
        _ = events.perform(NSSelectorFromString("addObject:"), with: "Fixture event")
        let compressed = try XCTUnwrap(document.perform(NSSelectorFromString("serialize"))?.takeUnretainedValue() as? Data)
        note.setValue(compressed, forKey: "activityEventsData")
        try context.save()
        context.reset()
        let decoded = try XCTUnwrap(try context.existingObject(with: id).value(forKey: "activityEventsDocument") as? NSObject)
        XCTAssertEqual((decoded.value(forKey: "orderedSet") as? NSObject)?.value(forKey: "count") as? Int, 1)
        try store.pruneEmptyActivityEvents()
        XCTAssertEqual(try context.existingObject(with: id).value(forKey: "activityEventsData") as? Data, compressed)
        let reopened = try context.existingObject(with: id)
        _ = reopened.perform(NSSelectorFromString("removeAllCloudSyncingObjectActivityEvents"))
        let empty = try XCTUnwrap(reopened.value(forKey: "activityEventsData") as? Data)
        reopened.setValue(true, forKey: "isPasswordProtected")
        try context.save()
        context.reset()
        try context.existingObject(with: id).setValue(empty, forKey: "activityEventsData")
        try context.save()
        context.reset()
        XCTAssertEqual(try context.existingObject(with: id).value(forKey: "isPasswordProtected") as? Bool, true)
        XCTAssertEqual(try context.existingObject(with: id).primitiveValue(forKey: "activityEventsData") as? Data, empty)
        try store.pruneEmptyActivityEvents()
        XCTAssertEqual(try context.existingObject(with: id).primitiveValue(forKey: "activityEventsData") as? Data, empty)
    }

    func testActivityPreparationLeavesAttachmentsOfProtectedNotesUntouched() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let id = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
        let note = try context.existingObject(with: id)
        let attachment = try XCTUnwrap((note.value(forKey: "attachments") as? Set<NSManagedObject>)?.first)
        let attachmentID = attachment.objectID
        let document = try XCTUnwrap(note.value(forKey: "activityEventsDocument") as? NSObject)
        let events = try XCTUnwrap(document.value(forKey: "orderedSet") as? NSObject)
        _ = events.perform(NSSelectorFromString("addObject:"), with: "Fixture event")
        _ = events.perform(NSSelectorFromString("removeAllObjects"))
        let empty = try XCTUnwrap(document.perform(NSSelectorFromString("serialize"))?.takeUnretainedValue() as? Data)
        note.setValue(true, forKey: "isPasswordProtected")
        try context.save()
        context.reset()
        try context.existingObject(with: attachmentID).setValue(empty, forKey: "activityEventsData")
        try context.save()
        context.reset()
        XCTAssertEqual(try context.existingObject(with: attachmentID).primitiveValue(forKey: "activityEventsData") as? Data, empty)
        try store.pruneEmptyActivityEvents()
        XCTAssertEqual(try context.existingObject(with: attachmentID).primitiveValue(forKey: "activityEventsData") as? Data, empty)
    }

    func testImportKeepsAProtectedNoteWithTheSameIdentifier() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let folderID = try XCTUnwrap(try store.listFolders().first { $0["name"] as? String == "Fixture" }?["id"] as? String)
        let folder = try context.existingObject(with: try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: folderID)!)))
        let identifier = UUID().uuidString
        let cls = try XCTUnwrap(NSClassFromString("ICNote") as? NSObject.Type)
        let note = try XCTUnwrap(cls.perform(NSSelectorFromString("newEmptyNoteWithIdentifier:folder:"), with: identifier, with: folder)?.takeUnretainedValue() as? NSManagedObject)
        note.setValue(true, forKey: "isPasswordProtected")
        try context.save()
        let protectedID = note.objectID.uriRepresentation().absoluteString
        let result = try store.importNote(withIdentifier: identifier, folder: "Fixture", html: "<h1>Replacement</h1>", tags: "", files: [])
        XCTAssertEqual(result["imported"] as? Bool, false)
        XCTAssertEqual(result["id"] as? String, protectedID)
        let reopened = try XCTUnwrap(NBNotes(url: database, readOnly: true).value(forKey: "context") as? NSManagedObjectContext)
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICNote")
        request.predicate = NSPredicate(format: "identifier == %@", identifier)
        let found = try reopened.fetch(request)
        XCTAssertEqual(found.map { $0.objectID.uriRepresentation().absoluteString }, [protectedID])
        XCTAssertEqual(found.first?.value(forKey: "isPasswordProtected") as? Bool, true)
        let sharedIdentifier = UUID().uuidString
        let shared = try XCTUnwrap(cls.perform(NSSelectorFromString("newEmptyNoteWithIdentifier:folder:"), with: sharedIdentifier, with: try context.existingObject(with: folder.objectID))?.takeUnretainedValue() as? NSManagedObject)
        shared.setValue("_someone_else", forKey: "zoneOwnerName")
        try context.save()
        XCTAssertEqual(shared.value(forKey: "isSharedViaICloud") as? Bool, true)
        let kept = try store.importNote(withIdentifier: sharedIdentifier, folder: "Fixture", html: "<h1>Replacement</h1>", tags: "", files: [])
        XCTAssertEqual(kept["imported"] as? Bool, false)
        XCTAssertEqual(kept["id"] as? String, shared.objectID.uriRepresentation().absoluteString)
    }

    func testSaveRefusesPendingChangesToProtectedAndSharedNotes() throws {
        for (key, value) in [("isPasswordProtected", true as Any), ("zoneOwnerName", "_someone_else" as Any)] {
            let store = try NBNotes(url: database, readOnly: false)
            let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
            let id = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: targetID)!))
            let note = try context.existingObject(with: id)
            note.setValue(value, forKey: key)
            try context.save()
            note.setValue("Changed behind the check", forKey: "title")
            XCTAssertThrowsError(try store.createFolder("Unrelated \(key)", parent: nil), key)
            let reopened = try XCTUnwrap(NBNotes(url: database, readOnly: true).value(forKey: "context") as? NSManagedObjectContext)
            XCTAssertEqual(try reopened.existingObject(with: id).value(forKey: "title") as? String, "Target", key)
            XCTAssertFalse(try NBNotes(url: database, readOnly: true).listFolders().contains { ($0["name"] as? String)?.hasPrefix("Unrelated") == true }, key)
            note.setValue(key == "zoneOwnerName" ? nil : false, forKey: key)
            try context.save()
        }
    }

    func testHiddenFolderReferenceIsRejectedWithAReadableMessage() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let folderID = try store.createFolder("Hidden", parent: nil)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let folder = try context.existingObject(with: try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: folderID)!)))
        folder.setValue(true, forKey: "markedForDeletion")
        try context.save()
        XCTAssertThrowsError(try store.createNote(inFolder: folderID, html: "<p>Lost</p>")) { error in
            XCTAssertTrue((error as NSError).localizedDescription.hasPrefix("Folder not found: "), "\(error)")
        }
    }

    private func message(_ body: @autoclosure () throws -> Any) -> String {
        do { _ = try body(); return "no error" } catch { return (error as NSError).localizedDescription }
    }

    func testEveryPrintedReferenceIsAcceptedAsInput() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let folder = try store.createFolder("Printed", parent: "Fixture")
        let note = try store.createNote(inFolder: folder, html: "<h1>Printed</h1>")
        let file = directory.appendingPathComponent("printed.txt")
        try Data("printed".utf8).write(to: file)
        _ = try store.editNote(note, operation: "attachment-add", options: ["file": file.path])
        _ = try store.editNote(note, operation: "tag-add", options: ["name": "printed"])
        _ = try store.editNote(note, operation: "link-add", options: ["target": targetID!])
        let state = try store.readNote(note)
        func uuid(_ id: String) throws -> String { try XCTUnwrap(store.publicIdentifiers(forIDs: [id])[id]) }
        for key in ["id", "url"] {
            let printed = try XCTUnwrap(state[key] as? String)
            XCTAssertEqual(try store.readNote(printed)["id"] as? String, note, key)
        }
        XCTAssertEqual(try store.readNote(try uuid(note))["id"] as? String, note)
        let listed = try XCTUnwrap(try store.listFolders().first { $0["id"] as? String == folder })
        for printed in [try XCTUnwrap(state["folder"] as? String), try XCTUnwrap(state["folderPath"] as? String), try XCTUnwrap(listed["path"] as? String), try XCTUnwrap(listed["name"] as? String), try uuid(folder), try uuid(folder).lowercased()] {
            XCTAssertEqual(try store.canonicalID(forReference: printed, entity: "ICFolder"), folder, printed)
        }
        let attachment = try XCTUnwrap((state["attachments"] as? [[String: Any]])?.first)
        let attachmentID = try XCTUnwrap(attachment["id"] as? String)
        for printed in [attachmentID, try XCTUnwrap(attachment["name"] as? String), try uuid(attachmentID)] {
            XCTAssertEqual(try store.attachmentID(forReference: printed, note: note), attachmentID, printed)
        }
        let tag = try XCTUnwrap((state["tags"] as? [[String: Any]])?.first)
        for key in ["name", "contentIdentifier"] {
            XCTAssertEqual(try store.noteIDs(withTag: try XCTUnwrap(tag[key] as? String)), [note], key)
        }
        let link = try XCTUnwrap((state["links"] as? [[String: Any]])?.first)
        XCTAssertEqual(try store.readNote(try XCTUnwrap(link["target"] as? String))["id"] as? String, targetID)
        let removed = try store.editNote(note, operation: "link-remove", options: ["link": try uuid(try XCTUnwrap(link["id"] as? String))])
        XCTAssertEqual((removed["links"] as? [[String: Any]])?.count, 0)
    }

    func testFolderReferencesAcceptPathsNamesAndReportTheInput() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let sub = try store.createFolder("Sub", parent: "Fixture")
        let other = try store.createFolder("Other", parent: nil)
        _ = try store.createFolder("Sub", parent: other)
        XCTAssertEqual(try store.canonicalID(forReference: "Fixture/Sub", entity: "ICFolder"), sub)
        XCTAssertEqual(try store.canonicalID(forReference: "fixture/sub", entity: "ICFolder"), sub)
        XCTAssertEqual(try store.canonicalID(forReference: "other", entity: "ICFolder"), other)
        let note = try store.createNote(inFolder: "Fixture/Sub", html: "<h1>Nested</h1>")
        XCTAssertEqual(try store.readNote(note)["folderPath"] as? String, "Fixture/Sub")
        XCTAssertEqual(message(try store.createNote(inFolder: "Sub", html: "<p>x</p>")), "Folder name is ambiguous: Sub. Use a path: Fixture/Sub, Other/Sub")
        XCTAssertEqual(message(try store.listNotes(inFolder: "Missing/One")), "Folder not found: Missing/One. Use a name, a path such as Work/Project or a UUID from nb folders")
        XCTAssertEqual(message(try store.search("Nested", options: ["folder": "Missing"])), "Folder not found: Missing. Use a name, a path such as Work/Project or a UUID from nb folders")
        let noteUUID = try XCTUnwrap(store.publicIdentifiers(forIDs: [note])[note])
        XCTAssertEqual(message(try store.listNotes(inFolder: noteUUID)), "\(noteUUID) is a note, a folder is required")
    }

    func testNoteReferencesAcceptTheNoteURLAndReportTheInput() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let state = try store.readNote(noteID)
        let url = try XCTUnwrap(state["url"] as? String)
        XCTAssertEqual(try store.readNote(url)["id"] as? String, noteID)
        XCTAssertEqual(message(try store.readNote("00000000")), "Note not found: 00000000. Use a UUID or its prefix of at least 8 characters from nb ls or nb search")
        XCTAssertEqual(message(try store.readNote("Fixture")), "Note not found: Fixture. Use a UUID or its prefix of at least 8 characters from nb ls or nb search")
        let folderID = try XCTUnwrap(try store.listFolders().first { $0["name"] as? String == "Fixture" }?["id"] as? String)
        let folderUUID = try XCTUnwrap(store.publicIdentifiers(forIDs: [folderID])[folderID])
        XCTAssertEqual(message(try store.readNote(folderUUID)), "\(folderUUID) is a folder, a note is required")
    }

    func testAttachmentReferencesAcceptFileNames() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let plain = try store.createNote(inFolder: "Fixture", html: "<h1>Files</h1>")
        for name in ["first.txt", "second.txt"] {
            let file = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            _ = try store.editNote(plain, operation: "attachment-add", options: ["file": file.path])
        }
        let items = try XCTUnwrap(store.readNote(plain)["attachments"] as? [[String: Any]])
        let second = try XCTUnwrap(items.first { $0["name"] as? String == "second.txt" }?["id"] as? String)
        XCTAssertEqual(try store.attachmentID(forReference: "second.txt", note: plain), second)
        XCTAssertEqual(try store.attachmentID(forReference: second, note: plain), second)
        let after = try store.editNote(plain, operation: "attachment-remove", options: ["attachment": "first.txt"])
        XCTAssertEqual((after["attachments"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["second.txt"])
        XCTAssertEqual(message(try store.attachmentID(forReference: "absent.txt", note: plain)), "Attachment not found in this note: absent.txt. Use a file name or a UUID from nb attachments ls")
        XCTAssertEqual(message(try store.attachmentID(forReference: second, note: targetID)), "Attachment not found in this note: \(second). Use a file name or a UUID from nb attachments ls")
    }

    func testTagReferencesAreValidatedTheSameWayForFilterAndEdit() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(targetID, operation: "tag-add", options: ["name": "kept"])
        XCTAssertEqual(try store.noteIDs(withTag: "#kept"), [targetID])
        XCTAssertEqual(try store.noteIDs(withTag: "KEPT"), [targetID])
        XCTAssertEqual(message(try store.noteIDs(withTag: "bad!")), "Invalid tag name: bad!. Use letters, digits, _ and -")
        XCTAssertEqual(message(try store.editNote(targetID, operation: "tag-add", options: ["name": "bad!"])), "Invalid tag name: bad!. Use letters, digits, _ and -")
        XCTAssertEqual(message(try store.editNote(targetID, operation: "tag-remove", options: ["name": "absent"])), "Tag not found in this note: #absent")
        XCTAssertEqual((try store.readNote(targetID)["tags"] as? [[String: Any]])?.count, 1)
    }

    func testNativeHTMLWriteRejectsAttachmentsAndReadOnlyWrites() throws {
        let store = try NBNotes(url: database, readOnly: false)
        XCTAssertThrowsError(try store.setHTML("<p>lost</p>", forNote: noteID))
        let plain = try store.createNote(inFolder: "Fixture", html: "<h1>Plain</h1><p>Before</p>")
        try store.setHTML("<h1>Plain</h1><p>After <i>italic</i></p>", forNote: plain)
        let reopened = try NBNotes(url: database, readOnly: true)
        XCTAssertTrue((try reopened.readNote(plain)["text"] as? String)?.contains("After italic") == true)
        XCTAssertThrowsError(try reopened.createFolder("Refused", parent: nil))
        XCTAssertThrowsError(try reopened.moveNote(plain, toFolder: "Fixture"))
        XCTAssertThrowsError(try reopened.deleteNote(plain))
        XCTAssertThrowsError(try reopened.setHTML("<p>Refused</p>", forNote: plain))
    }

    func testSearchFindsIndexedAttachmentTextAndReportsUnavailableFiles() throws {
        let store = try NBNotes(url: database, readOnly: true)
        let result = try store.search("Zephyr", options: ["field": "document"])
        let found = try XCTUnwrap(result["notes"] as? [[String: Any]])
        XCTAssertEqual(found.first?["id"] as? String, noteID)
        XCTAssertEqual(found.first?["matchedFields"] as? [String], ["document"])
        XCTAssertEqual(result["unavailableDocuments"] as? Int, 0)
        let context = try XCTUnwrap(NBNotes(url: database, readOnly: false).value(forKey: "context") as? NSManagedObjectContext)
        let note = try context.existingObject(with: try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!)))
        try XCTUnwrap((note.value(forKey: "attachments") as? Set<NSManagedObject>)?.first).setValue("com.adobe.pdf", forKey: "typeUTI")
        try context.save()
        XCTAssertEqual(try NBNotes(url: database, readOnly: true).search("Zephyr", options: ["field": "document"])["unavailableDocuments"] as? Int, 1)
    }

    func testImportCommitsAllObjectsOrNoneAndDoesNotDuplicate() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let identifier = UUID().uuidString
        let before = try store.listNotes(inFolder: "Fixture").count
        XCTAssertThrowsError(try store.importNote(withIdentifier: identifier, folder: "Fixture", html: "<h1>Imported</h1>", tags: "first,bad!", files: []))
        XCTAssertThrowsError(try store.importNote(withIdentifier: identifier, folder: "Fixture", html: "<h1>Imported</h1>", tags: "first", files: [directory.appendingPathComponent("missing.pdf").path]))
        XCTAssertEqual(try NBNotes(url: database, readOnly: true).listNotes(inFolder: "Fixture").count, before)
        let imported = try store.importNote(withIdentifier: identifier, folder: "Fixture", html: "<h1>Imported</h1>", tags: "first/second", files: [])
        XCTAssertEqual(imported["imported"] as? Bool, true)
        let id = try XCTUnwrap(imported["id"] as? String)
        XCTAssertEqual((try NBNotes(url: database, readOnly: true).readNote(id)["tags"] as? [[String: Any]])?.count, 2)
        let repeated = try store.importNote(withIdentifier: identifier, folder: "Fixture", html: "<p>Must not overwrite</p>", tags: "other", files: [])
        XCTAssertEqual(repeated["id"] as? String, id)
        XCTAssertEqual(repeated["imported"] as? Bool, false)
        XCTAssertEqual(try store.listNotes(inFolder: "Fixture").count, before + 1)
        XCTAssertTrue((try store.readNote(id)["text"] as? String)?.contains("Imported") == true)
    }

    func testPlainNoteAndFolderAreQueuedForCloudUpload() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let folderID = try store.createFolder("Cloud queue", parent: "Fixture")
        let noteID = try store.createNote(inFolder: folderID, html: "<h1>Plain cloud note</h1><p>No tags or files</p>")
        let state = try NBNotes(url: database, readOnly: true).readNote(noteID)
        XCTAssertEqual(state["needsCloudPush"] as? Bool, true)
        XCTAssertEqual(state["cloudAcknowledged"] as? Bool, false)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let objectID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: folderID)!))
        let folder = try context.existingObject(with: objectID)
        XCTAssertEqual(folder.value(forKey: "needsToBePushedToCloud") as? Bool, true)
    }

    func testIncompleteImportWithOrphanTableIsRecreated() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let folderID = try XCTUnwrap(try store.listFolders().first { $0["name"] as? String == "Fixture" }?["id"] as? String)
        let objectID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: folderID)!))
        let folder = try context.existingObject(with: objectID)
        let identifier = UUID().uuidString
        let cls = try XCTUnwrap(NSClassFromString("ICNote") as? NSObject.Type)
        let note = try XCTUnwrap(cls.perform(NSSelectorFromString("newEmptyNoteWithIdentifier:folder:"), with: identifier, with: folder)?.takeUnretainedValue() as? NSManagedObject)
        _ = note.perform(NSSelectorFromString("addTableAttachment"))
        try context.save()
        let result = try store.importNote(withIdentifier: identifier, folder: "Fixture", html: "<h1>Recovered</h1>", tags: "first/second", files: [])
        XCTAssertEqual(result["imported"] as? Bool, true)
        let id = try XCTUnwrap(result["id"] as? String)
        let state = try NBNotes(url: database, readOnly: true).readNote(id)
        XCTAssertTrue((state["text"] as? String)?.contains("Recovered") == true)
        XCTAssertEqual((state["tags"] as? [[String: Any]])?.count, 2)
    }

    func testImportedReferenceBecomesNativeLinkWithoutLosingAttachments() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "link-replace", options: ["target": targetID!, "find": "Alpha"])
        let state = try NBNotes(url: database, readOnly: true).readNote(noteID)
        XCTAssertFalse((state["text"] as? String)?.contains("Alpha") == true)
        XCTAssertTrue((state["text"] as? String)?.contains("bold omega") == true)
        XCTAssertEqual((state["links"] as? [[String: Any]])?.first?["target"] as? String, targetID)
        XCTAssertEqual((state["attachments"] as? [[String: Any]])?.count, 1)
    }

    func testDateTagComponentsAreNativeTags() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "tag-add", options: ["name": "incident/2026-06,24,2025"])
        let tags = try XCTUnwrap(try NBNotes(url: database, readOnly: true).readNote(noteID)["tags"] as? [[String: Any]])
        XCTAssertEqual(Set(tags.compactMap { $0["name"] as? String }), ["#incident", "#2026-06", "#24", "#2025"])
    }

    func testImportedChecklistKeepsCheckedState() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let identifier = UUID().uuidString
        let token = "NBTODO1_\(identifier.replacingOccurrences(of: "-", with: ""))_0 "
        let result = try store.importNote(withIdentifier: identifier, folder: "Fixture", html: "<h1>Tasks</h1><p>\(token)Finished task</p>", tags: "", files: [])
        let id = try XCTUnwrap(result["id"] as? String)
        let state = try NBNotes(url: database, readOnly: true).readNote(id)
        XCTAssertFalse((state["text"] as? String)?.contains("NBTODO") == true)
        XCTAssertTrue((state["runs"] as? [[String: Any]])?.contains { ($0["text"] as? String)?.contains("Finished task") == true && ($0["checked"] as? Bool) == true } == true)
    }

    func testRepeatedFileReferencesUseOneAttachmentAndMultipleMarkers() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "insert", options: ["text": "\nFILETOKEN\nFILETOKEN\n"])
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let objectID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
        let note = try context.existingObject(with: objectID)
        let document = try XCTUnwrap(note.value(forKey: "mergeableString") as? NSObject)
        let attachmentID = try XCTUnwrap((try store.readNote(noteID)["attachments"] as? [[String: Any]])?.first?["id"] as? String)
        let fileID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: attachmentID)!))
        let attachment = try context.existingObject(with: fileID)
        let selector = NSSelectorFromString("insertAttachment:intoDocument:replacingToken:")
        typealias Insert = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, NSString) -> Void
        unsafeBitCast(store.method(for: selector), to: Insert.self)(store, selector, attachment, document, "FILETOKEN")
        _ = note.perform(NSSelectorFromString("saveNoteData"))
        try context.save()
        let state = try NBNotes(url: database, readOnly: true).readNote(noteID)
        let text = try XCTUnwrap(state["text"] as? String)
        XCTAssertFalse(text.contains("FILETOKEN"))
        XCTAssertEqual(text.filter { $0 == "\u{FFFC}" }.count, 4)
        XCTAssertEqual((state["attachments"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(text.contains("Alpha bold omega"))
    }

    func testTagSurvivesTextEditAndRemoval() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let tagged = try store.editNote(noteID, operation: "tag-add", options: ["name": "project"])
        let tags = try XCTUnwrap(tagged["tags"] as? [[String: Any]])
        XCTAssertEqual(tags.count, 1)
        let edited = try store.editNote(noteID, operation: "replace", options: ["find": "Alpha", "replacement": "Delta"])
        XCTAssertEqual((edited["tags"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((edited["attachments"] as? [[String: Any]])?.count, 1)
        let reopened = try NBNotes(url: database, readOnly: false)
        let removed = try reopened.editNote(noteID, operation: "tag-remove", options: ["name": "project"])
        XCTAssertEqual((removed["tags"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue((removed["text"] as? String)?.contains("Delta bold omega") == true)
    }

    func testTagSeparatorsCreateDistinctNativeTagsAndRemoveThem() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "tag-add", options: ["name": " #invoices/tech, other invoices/TECH ,, / "])
        _ = try store.editNote(noteID, operation: "tag-add", options: ["name": "invoices/tech,other"])
        let result = try NBNotes(url: database, readOnly: true).readNote(noteID)
        let tags = try XCTUnwrap(result["tags"] as? [[String: Any]])
        XCTAssertEqual(Set(tags.compactMap { $0["name"] as? String }), ["#invoices", "#tech", "#other"])
        XCTAssertEqual(tags.count, 3)
        XCTAssertEqual((result["attachments"] as? [[String: Any]])?.count, 1)
        _ = try store.editNote(noteID, operation: "tag-remove", options: ["name": " #invoices/TECH, other "])
        let removed = try NBNotes(url: database, readOnly: true).readNote(noteID)
        XCTAssertEqual((removed["tags"] as? [[String: Any]])?.count, 0)
    }

    func testInvalidTagBatchDoesNotSaveAnyTags() throws {
        let store = try NBNotes(url: database, readOnly: false)
        XCTAssertThrowsError(try store.editNote(noteID, operation: "tag-add", options: ["name": "valid,bad!"]))
        XCTAssertThrowsError(try store.editNote(noteID, operation: "tag-add", options: ["name": " , / "]))
        _ = try store.editNote(noteID, operation: "tag-add", options: ["name": "retained"])
        XCTAssertThrowsError(try store.editNote(noteID, operation: "tag-remove", options: ["name": "retained,bad!"]))
        let result = try NBNotes(url: database, readOnly: true).readNote(noteID)
        XCTAssertEqual((result["tags"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["#retained"])
    }

    func testPinAndUnpinPreserveDocumentAndQueueCloudChanges() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "tag-add", options: ["name": "pinfixture"])
        _ = try store.editNote(noteID, operation: "link-add", options: ["target": targetID!])
        _ = try store.editNote(noteID, operation: "table-new", options: ["rows": 1, "columns": 1, "grid": [["Pinned cell"]]])
        let before = try store.readNote(noteID)
        func object(_ reopened: NBNotes) throws -> NSManagedObject {
            let context = try XCTUnwrap(reopened.value(forKey: "context") as? NSManagedObjectContext)
            let id = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
            return try context.existingObject(with: id)
        }
        let original = try XCTUnwrap((try object(store).value(forKey: "noteData") as? NSManagedObject)?.value(forKey: "data") as? Data)
        XCTAssertEqual(before["pinned"] as? Bool, false)
        var result: [AnyHashable: Any]?
        XCTAssertNoThrow(result = try store.editNote(noteID, operation: "pin", options: [:]))
        XCTAssertEqual(result?["pinned"] as? Bool, true)
        guard result != nil else { return }
        for operation in ["pin", "unpin", "unpin", "pin"] {
            let changed = try store.editNote(noteID, operation: operation, options: [:])
            XCTAssertEqual(changed["pinned"] as? Bool, operation == "pin")
            let reopened = try NBNotes(url: database, readOnly: true)
            let after = try reopened.readNote(noteID)
            for key in ["id", "text", "folder", "runs", "attachments", "links", "tables"] {
                XCTAssertEqual(after[key] as? NSObject, before[key] as? NSObject, key)
            }
            XCTAssertEqual(after["tags"] as? NSObject, before["tags"] as? NSObject)
            let note = try object(reopened)
            XCTAssertEqual((note.value(forKey: "noteData") as? NSManagedObject)?.value(forKey: "data") as? Data, original)
            XCTAssertTrue(note.value(forKey: "needsToBePushedToCloud") as? Bool == true)
        }
        let folder = try store.createFolder("Pinned destination", parent: nil)
        try store.moveNote(noteID, toFolder: folder)
        XCTAssertEqual(try NBNotes(url: database, readOnly: true).readNote(noteID)["pinned"] as? Bool, true)
        try store.deleteNote(noteID)
        XCTAssertThrowsError(try store.editNote(noteID, operation: "pin", options: [:]))
        XCTAssertThrowsError(try store.editNote(noteID, operation: "unpin", options: [:]))
    }

    func testFolderStatisticsDistinguishEmptyFoldersAndFollowMovesAndDeletion() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let empty = try store.createFolder("Empty", parent: nil)
        let child = try store.createFolder("Child", parent: empty)
        func folder(_ id: String) throws -> [String: Any] {
            try XCTUnwrap(store.listFolders().first { $0["id"] as? String == id } as? [String: Any])
        }
        XCTAssertEqual(try folder(empty)["noteCount"] as? Int, 0)
        XCTAssertEqual(try folder(empty)["subfolderCount"] as? Int, 1)
        XCTAssertEqual(try folder(child)["path"] as? String, "Empty/Child")
        XCTAssertEqual(try folder(child)["empty"] as? Bool, true)
        let encoded = try JSONSerialization.data(withJSONObject: folder(child), options: [.sortedKeys])
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"empty\":true"))
        try store.moveNote(noteID, toFolder: child)
        XCTAssertEqual(try folder(child)["noteCount"] as? Int, 1)
        XCTAssertEqual(try folder(child)["empty"] as? Bool, false)
        try store.deleteNote(noteID)
        XCTAssertEqual(try folder(child)["noteCount"] as? Int, 0)
        XCTAssertEqual(try folder(child)["empty"] as? Bool, true)
    }

    func testNativeBooleanFieldsSerializeAsJSONBooleans() throws {
        let store = try NBNotes(url: database, readOnly: true)
        let listed = try XCTUnwrap(store.listNotes(inFolder: "Fixture").first)
        let values = [try store.readNote(noteID), ["hasDocument": try XCTUnwrap(listed["hasDocument"])]]
        for value in values {
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let text = String(decoding: bytes, as: UTF8.self)
            for key in ["bold", "italic", "canRewriteHTML", "hasDocument"] where text.contains("\"\(key)\":") {
                XCTAssertFalse(text.contains("\"\(key)\":0") || text.contains("\"\(key)\":1"), key)
            }
        }
    }

    func testBackupKeepsDatabaseDrawingsButRejectsMissingFileAttachments() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICAttachment")
        let attachment = try XCTUnwrap(context.fetch(request).first)
        attachment.setValue("com.apple.drawing.2", forKey: "typeUTI")
        attachment.setValue(Data("stored drawing document".utf8), forKey: "mergeableData")
        try context.save()
        XCTAssertNoThrow(try store.backupAttachmentPaths())
        attachment.setValue(nil, forKey: "mergeableData")
        try context.save()
        XCTAssertThrowsError(try store.backupAttachmentPaths())
        attachment.setValue("com.adobe.pdf", forKey: "typeUTI")
        try context.save()
        XCTAssertThrowsError(try store.backupAttachmentPaths())
    }

    func testUUIDReferencesResolveUniquePrefixesAndRejectAmbiguityAndWrongEntities() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let ids = try store.publicIdentifiers(forIDs: [noteID])
        let uuid = try XCTUnwrap(ids[noteID])
        XCTAssertNotNil(UUID(uuidString: uuid))
        XCTAssertEqual(try store.canonicalID(forReference: uuid, entity: "ICNote"), noteID)
        XCTAssertEqual(try store.canonicalID(forReference: String(uuid.prefix(8)), entity: "ICNote"), noteID)
        XCTAssertThrowsError(try store.canonicalID(forReference: String(uuid.prefix(7)), entity: "ICNote"))
        XCTAssertThrowsError(try store.canonicalID(forReference: uuid, entity: "ICFolder"))
        let targetObject = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: targetID)!))
        let target = try context.existingObject(with: targetObject)
        target.setValue(String(uuid.prefix(8)) + "-0000-0000-0000-000000000000", forKey: "identifier")
        try context.save()
        XCTAssertThrowsError(try store.canonicalID(forReference: String(uuid.prefix(8)), entity: "ICNote"))
        XCTAssertEqual(try store.canonicalID(forReference: uuid, entity: "ICNote"), noteID)
    }

    func testNoteURLsUseStoredUUIDWithoutLeakingLocalAddresses() throws {
        let store = try NBNotes(url: database, readOnly: true)
        let uuid = try XCTUnwrap(store.publicIdentifiers(forIDs: [noteID])[noteID])
        let expected = "applenotes://showNote?identifier=" + uuid
        XCTAssertEqual(try store.readNote(noteID)["url"] as? String, expected)
        XCTAssertEqual(try store.listNotes(inFolder: "Fixture").first { $0["id"] as? String == noteID }?["url"] as? String, expected)
        let found = try store.search("Fixture", options: ["field": "title"])
        XCTAssertEqual((found["notes"] as? [[String: Any]])?.first?["url"] as? String, expected)
    }

    func testSystemFolderUUIDIsStableAndResolvesAfterNoteDeletion() throws {
        let store = try NBNotes(url: database, readOnly: false)
        try store.deleteNote(noteID)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let objectID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
        let note = try context.existingObject(with: objectID)
        let folder = try XCTUnwrap(note.value(forKey: "folder") as? NSManagedObject)
        let account = try XCTUnwrap(folder.value(forKey: "account") as? NSManagedObject)
        account.setValue("C791CE10-D36A-46E4-AA17-33F0AEB14EDA", forKey: "identifier")
        folder.setValue("TrashFolder-CloudKit", forKey: "identifier")
        try context.save()
        let id = folder.objectID.uriRepresentation().absoluteString
        let uuid = try XCTUnwrap(store.publicIdentifiers(forIDs: [id])[id])
        XCTAssertEqual(uuid, "3ADD7A68-84AA-5937-A1A8-EBE726FAE18E")
        let reopened = try NBNotes(url: database, readOnly: true)
        XCTAssertEqual(try reopened.publicIdentifiers(forIDs: [id])[id], uuid)
        XCTAssertEqual(try reopened.canonicalID(forReference: String(uuid.prefix(8)), entity: "ICFolder"), id)
        let data = try reopened.readNote(noteID)
        XCTAssertEqual(data["folder"] as? String, id)
        XCTAssertNotNil(try reopened.publicIdentifiers(forIDs: [noteID])[noteID])
    }

    func testWebLinksRemainAccessibleAndSearchableWithoutBecomingAttachments() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let id = try store.createNote(inFolder: "Fixture", html: "<h1>Web reference</h1><p><a href=\"https://example.test/invoice.pdf\">Invoice PDF</a></p>")
        let note = try store.readNote(id)
        let urls = note["urls"] as? [[String: Any]]
        XCTAssertEqual(urls?.first?["url"] as? String, "https://example.test/invoice.pdf")
        XCTAssertEqual(urls?.first?["name"] as? String, "Invoice PDF")
        XCTAssertEqual((note["attachments"] as? [Any])?.count, 0)
        let found = try store.search("example.test", options: ["field": "link"])
        XCTAssertEqual((found["notes"] as? [[String: Any]])?.first?["id"] as? String, id)
        let listed = try store.listNotes(inFolder: "Fixture").first { $0["id"] as? String == id }
        XCTAssertEqual((listed?["urls"] as? [[String: Any]])?.first?["url"] as? String, "https://example.test/invoice.pdf")
    }

    func testProtectedNoteListsFilesWithoutOfferingExportOrReadingLinks() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let id = try store.createNote(inFolder: "Fixture", html: "<h1>Protected files</h1>")
        let file = directory.appendingPathComponent("local.txt")
        try Data("Example file".utf8).write(to: file)
        _ = try store.editNote(id, operation: "attachment-add", options: ["file": file.path])
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let objectID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: id)!))
        let note = try context.existingObject(with: objectID)
        note.setValue(true, forKey: "isPasswordProtected")
        try context.save()
        let listed = try XCTUnwrap(store.listNotes(inFolder: "Fixture").first { $0["id"] as? String == id })
        let attachment = try XCTUnwrap((listed["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(attachment["available"] as? Bool, true)
        XCTAssertEqual(attachment["exportable"] as? Bool, false)
        XCTAssertTrue(listed["urls"] is NSNull)
        XCTAssertThrowsError(try store.readNote(id))
    }

    func testPinRejectsReadOnlyProtectedAndForeignNotes() throws {
        let store = try NBNotes(url: database, readOnly: false)
        XCTAssertThrowsError(try NBNotes(url: database, readOnly: true).editNote(noteID, operation: "pin", options: [:]))
        XCTAssertThrowsError(try store.editNote("x-coredata://FOREIGN/ICNote/p1", operation: "pin", options: [:]))
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let id = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
        let note = try context.existingObject(with: id)
        note.setValue(true, forKey: "isPasswordProtected")
        try context.save()
        for operation in ["pin", "unpin"] { XCTAssertThrowsError(try store.editNote(noteID, operation: operation, options: [:])) }
        XCTAssertFalse(note.value(forKey: "isPinned") as? Bool == true)
    }

    func testMetadataChangesLeaveStoredDocumentBytesUntouched() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let folder = try store.createFolder("Metadata destination", parent: "Fixture")
        func bytes(_ store: NBNotes) throws -> Data {
            let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
            let id = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: noteID)!))
            let note = try context.existingObject(with: id)
            let data = try XCTUnwrap(note.value(forKey: "noteData") as? NSManagedObject)
            return try XCTUnwrap(data.value(forKey: "data") as? Data)
        }
        let before = try bytes(store)
        let attachment = try XCTUnwrap((store.readNote(noteID)["attachments"] as? [[String: Any]])?.first?["id"] as? String)
        _ = try store.editNote(noteID, operation: "attachment-view", options: ["attachment": attachment, "size": 2])
        XCTAssertEqual(try bytes(NBNotes(url: database, readOnly: true)), before)
        _ = try store.readNote(noteID)
        try store.moveNote(noteID, toFolder: folder)
        XCTAssertEqual(try bytes(NBNotes(url: database, readOnly: true)), before)
        try store.deleteNote(noteID)
        XCTAssertEqual(try bytes(NBNotes(url: database, readOnly: true)), before)
    }

    func testAttachmentRemovalDeletesEveryMarkerAndPreservesText() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let before = try store.readNote(noteID)
        let attachments = try XCTUnwrap(before["attachments"] as? [[String: Any]])
        let id = try XCTUnwrap(attachments.first?["id"] as? String)
        let after = try store.editNote(noteID, operation: "attachment-remove", options: ["attachment": id])
        XCTAssertEqual(after["text"] as? String, "Fixture\nAlpha bold omega\nSecond paragraph 😀\n")
        XCTAssertEqual((after["attachments"] as? [[String: Any]])?.count, 0)
        let reopened = try NBNotes(url: database, readOnly: true)
        XCTAssertEqual((try reopened.readNote(noteID)["attachments"] as? [[String: Any]])?.count, 0)
    }

    func testAttachmentMovePreservesBothDocumentsAfterReopening() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let target = try store.createNote(inFolder: "Fixture", html: "<h1>Destination</h1><p>Target content</p>")
        let before = try store.readNote(noteID)
        let targetText = try XCTUnwrap(store.readNote(target)["text"] as? String)
        let attachment = try XCTUnwrap((before["attachments"] as? [[String: Any]])?.first?["id"] as? String)
        _ = try store.editNote(noteID, operation: "attachment-view", options: ["attachment": attachment, "size": 2])
        XCTAssertEqual(try NBNotes(url: database, readOnly: true).readNote(noteID)["text"] as? String, "Fixture\nAlpha bold omega\nSecond paragraph 😀\n\u{FFFC}\u{FFFC}")
        _ = try store.editNote(noteID, operation: "attachment-move", options: ["attachment": attachment, "target": target])
        let reopened = try NBNotes(url: database, readOnly: true)
        let source = try reopened.readNote(noteID)
        let destination = try reopened.readNote(target)
        XCTAssertEqual(source["text"] as? String, "Fixture\nAlpha bold omega\nSecond paragraph 😀\n")
        XCTAssertEqual((source["attachments"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue((source["runs"] as? [[String: Any]])?.contains { $0["text"] as? String == "bold" && $0["bold"] as? Bool == true } == true)
        XCTAssertEqual((destination["text"] as? String)?.replacingOccurrences(of: "\u{FFFC}", with: ""), targetText)
        let moved = try XCTUnwrap((destination["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(moved["id"] as? String, attachment)
        XCTAssertEqual(moved["viewSize"] as? Int, 2)
    }

    func testAttachmentMoveWithNativeCreatedSource() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let source = try store.createNote(inFolder: "Fixture", html: "<h1>Source</h1><p>Alpha <b>bold</b> omega</p>")
        let target = try store.createNote(inFolder: "Fixture", html: "<h1>Destination</h1><p>Target content</p>")
        let file = directory.appendingPathComponent("receipt.txt")
        try Data("Attachment content".utf8).write(to: file)
        let added = try store.editNote(source, operation: "attachment-add", options: ["file": file.path])
        let attachment = try XCTUnwrap((added["attachments"] as? [[String: Any]])?.first?["id"] as? String)
        _ = try store.editNote(source, operation: "attachment-view", options: ["attachment": attachment, "size": 2])
        _ = try store.editNote(source, operation: "attachment-move", options: ["attachment": attachment, "target": target])
        let reopened = try NBNotes(url: database, readOnly: true)
        XCTAssertEqual(try reopened.readNote(source)["text"] as? String, "Source\nAlpha bold omega\n")
        XCTAssertEqual((try reopened.readNote(target)["attachments"] as? [[String: Any]])?.first?["id"] as? String, attachment)
    }

    func testCLIExportsAllAttachmentsWithoutChangingNotesOrOverwritingFiles() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let id = try store.createNote(inFolder: "Fixture", html: "<h1>Download fixture</h1><p>Keep this text</p>")
        for name in ["receipt.txt", "image.txt"] {
            let file = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            _ = try store.editNote(id, operation: "attachment-add", options: ["file": file.path])
        }
        _ = try store.editNote(id, operation: "tag-add", options: ["name": "export-test"])
        _ = try store.editNote(id, operation: "link-add", options: ["target": targetID!])
        _ = try store.editNote(id, operation: "table-new", options: ["rows": 2, "columns": 2])
        let before = try store.readNote(id)
        let container = directory.appendingPathComponent("Library/Group Containers/group.com.apple.notes")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        func run(_ arguments: [String], isolated: Bool = true) throws -> (Int32, String, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
            process.arguments = arguments
            if isolated {
                var environment = ProcessInfo.processInfo.environment
                environment["CFFIXED_USER_HOME"] = directory.path
                process.environment = environment
            }
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text, error)
        }
        XCTAssertEqual(try run(["snapshot-db", container.appendingPathComponent("NoteStore.sqlite").path, "--database", database.path], isolated: false).0, 0)
        let destination = directory.appendingPathComponent("exported")
        let result = try run(["attachments", "export", id, "--directory", destination.path])
        XCTAssertEqual(result.0, 0, result.2)
        guard result.0 == 0 else { return }
        let paths = result.1.split(separator: "\n").map(String.init)
        XCTAssertEqual(paths.count, 2)
        for path in paths {
            let file = URL(fileURLWithPath: path)
            XCTAssertEqual(try Data(contentsOf: file), Data(file.lastPathComponent.utf8))
        }
        let again = try run(["attachments", "export", id, "--directory", destination.path])
        XCTAssertEqual(again.0, 1, again.2)
        XCTAssertFalse(again.2.contains("Usage:"), again.2)
        XCTAssertTrue(again.1.isEmpty)
        let empty = try run(["attachments", "export", targetID, "--directory", directory.appendingPathComponent("empty-export").path])
        XCTAssertEqual(empty.0, 1, empty.2)
        XCTAssertTrue(empty.2.contains("note has no files to export"), empty.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("empty-export").path))
        let jsonResult = try run(["attachments", "export", id, "--directory", directory.appendingPathComponent("json-export").path, "--json"])
        XCTAssertEqual(jsonResult.0, 0, jsonResult.2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonResult.1.utf8)) as? [String: Any])
        XCTAssertEqual((json["files"] as? [[String: Any]])?.count, 2)
        let after = try NBNotes(url: container.appendingPathComponent("NoteStore.sqlite"), readOnly: true).readNote(id)
        XCTAssertEqual(after["text"] as? String, before["text"] as? String)
        XCTAssertEqual(after["attachments"] as? NSArray, before["attachments"] as? NSArray)
        XCTAssertEqual(after["tags"] as? NSArray, before["tags"] as? NSArray)
        XCTAssertEqual(after["links"] as? NSArray, before["links"] as? NSArray)
        XCTAssertEqual(after["tables"] as? NSArray, before["tables"] as? NSArray)
        let session = try MCPTestSession(home: directory)
        _ = try session.initialize()
        let uuid = try XCTUnwrap(store.publicIdentifiers(forIDs: [id])[id])
        let prefix = String(uuid.prefix(8))
        let shown = try session.request("tools/call", ["name": "show", "arguments": ["id": prefix]])
        let data = try XCTUnwrap((shown["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        XCTAssertEqual(data["id"] as? String, uuid)
        XCTAssertEqual(data["text"] as? String, before["text"] as? String)
        XCTAssertEqual((data["attachments"] as? [[String: Any]])?.count, 3)
        let search = try session.request("tools/call", ["name": "search", "arguments": ["query": "receipt.txt", "field": "attachment"]])
        let searchData = try XCTUnwrap((search["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        XCTAssertEqual((searchData["notes"] as? [[String: Any]])?.first?["id"] as? String, uuid)
        let attachment = try XCTUnwrap((data["attachments"] as? [[String: Any]])?.first { $0["name"] as? String == "receipt.txt" }?["id"] as? String)
        let exported = directory.appendingPathComponent("mcp-receipt.txt")
        let mcpExport = try session.request("tools/call", ["name": "attachments_export", "arguments": ["id": prefix, "attachment": String(attachment.prefix(8)), "file": exported.path]])
        XCTAssertEqual((mcpExport["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: exported), Data("receipt.txt".utf8))
        try session.finish()
    }

    func testFormatAndChecklistKeepAttachment() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let formatted = try store.editNote(noteID, operation: "format", options: ["find": "Alpha", "style": "italic"])
        let runs = try XCTUnwrap(formatted["runs"] as? [[String: Any]])
        XCTAssertTrue(runs.contains { ($0["text"] as? String)?.contains("Alpha") == true && $0["italic"] as? Bool == true })
        let checked = try store.editNote(noteID, operation: "format", options: ["find": "Second paragraph", "style": "checklist", "checked": true])
        let checkedRuns = try XCTUnwrap(checked["runs"] as? [[String: Any]])
        XCTAssertTrue(checkedRuns.contains { ($0["text"] as? String)?.contains("Second paragraph") == true && $0["checked"] as? Bool == true })
        XCTAssertEqual((checked["attachments"] as? [[String: Any]])?.count, 1)
    }

    func testTableEditsKeepOtherAttachments() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "table-new", options: ["rows": 2, "columns": 2])
        _ = try store.editNote(noteID, operation: "table-set", options: ["table": 1, "row": 2, "column": 2, "value": "Cell"])
        let result = try NBNotes(url: database, readOnly: true).readNote(noteID)
        let tables = try XCTUnwrap(result["tables"] as? [[[String]]])
        XCTAssertEqual(tables, [[["", ""], ["", "Cell"]]])
        XCTAssertEqual((result["attachments"] as? [[String: Any]])?.count, 2)
    }

    func testNativeTagSearchReturnsNoteIDs() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "tag-add", options: ["name": "project"])
        XCTAssertEqual(try store.noteIDs(withTag: "#PROJECT"), [noteID])
        _ = try store.editNote(noteID, operation: "tag-remove", options: ["name": "project"])
        XCTAssertEqual(try store.noteIDs(withTag: "project"), [])
    }

    func testUnknownOperationsCannotModifyTablesOrTags() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "table-new", options: ["rows": 2, "columns": 2])
        XCTAssertThrowsError(try store.editNote(noteID, operation: "table-typo", options: ["table": 1, "at": 1]))
        XCTAssertThrowsError(try store.editNote(noteID, operation: "tag-typo", options: ["name": "project"]))
        let after = try NBNotes(url: database, readOnly: true).readNote(noteID)
        XCTAssertEqual(after["tables"] as? [[[String]]], [[["", ""], ["", ""]]])
    }

    func testChecklistCreatesOneTodoPerParagraph() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "format", options: ["find": "Alpha bold omega\nSecond paragraph", "style": "checklist"])
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: URL(fileURLWithPath: "/System/Library/PrivateFrameworks/NotesShared.framework/Resources/NoteData.mom")))
        let stores = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try stores.addPersistentStore(type: .sqlite, at: database, options: [NSReadOnlyPersistentStoreOption: true, NSPersistentHistoryTrackingKey: true])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = stores
        let objectID = try XCTUnwrap(stores.managedObjectID(forURIRepresentation: URL(string: noteID)!))
        let note = try context.existingObject(with: objectID)
        let text = try XCTUnwrap((note.value(forKey: "mergeableString") as? NSObject)?.value(forKey: "attributedString") as? NSAttributedString)
        func todo(_ word: String) throws -> UUID {
            let index = (text.string as NSString).range(of: word).location
            let style = try XCTUnwrap(text.attribute(NSAttributedString.Key("TTStyle"), at: index, effectiveRange: nil) as? NSObject)
            let value = try XCTUnwrap(style.value(forKey: "todo") as? NSObject)
            return try XCTUnwrap(value.value(forKey: "uuid") as? UUID)
        }
        XCTAssertEqual(try todo("Alpha"), try todo("bold"))
        XCTAssertEqual(try todo("Alpha"), try todo("omega"))
        XCTAssertNotEqual(try todo("Alpha"), try todo("Second"))
    }

    func testTablesFollowTheirOrderInTheNote() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "table-new", options: ["rows": 1, "columns": 1, "grid": [["Last"]]])
        _ = try store.editNote(noteID, operation: "table-new", options: ["rows": 1, "columns": 1, "grid": [["First"]], "before": "Alpha"])
        let before = try NBNotes(url: database, readOnly: true).readNote(noteID)
        XCTAssertEqual(before["tables"] as? [[[String]]], [[["First"]], [["Last"]]])
        _ = try store.editNote(noteID, operation: "table-set", options: ["table": 1, "row": 1, "column": 1, "value": "Edited"])
        let after = try NBNotes(url: database, readOnly: true).readNote(noteID)
        XCTAssertEqual(after["tables"] as? [[[String]]], [[["Edited"]], [["Last"]]])
    }

    func testHTMLRewriteIsRefusedForObjectsAndChecklists() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let initial = try store.readNote(noteID)
        XCTAssertEqual(initial["canRewriteHTML"] as? Bool, false)
        let attachments = try XCTUnwrap(initial["attachments"] as? [[String: Any]])
        let plain = try store.editNote(noteID, operation: "attachment-remove", options: ["attachment": attachments[0]["id"]!])
        XCTAssertEqual(plain["canRewriteHTML"] as? Bool, true)
        let checked = try store.editNote(noteID, operation: "format", options: ["find": "Alpha", "style": "checklist"])
        XCTAssertEqual(checked["canRewriteHTML"] as? Bool, false)
    }

    func testNoteLinkSurvivesEditingAndCanBeRemoved() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "link-add", options: ["target": targetID!, "after": "Alpha"])
        _ = try store.editNote(noteID, operation: "replace", options: ["find": "omega", "replacement": "end"])
        let reopened = try NBNotes(url: database, readOnly: false)
        let result = try reopened.readNote(noteID)
        let links = try XCTUnwrap(result["links"] as? [[String: Any]])
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0]["target"] as? String, targetID)
        XCTAssertEqual((result["attachments"] as? [[String: Any]])?.count, 1)
        _ = try reopened.editNote(noteID, operation: "link-remove", options: ["link": links[0]["id"]!])
        let after = try NBNotes(url: database, readOnly: true).readNote(noteID)
        XCTAssertEqual((after["links"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue((after["text"] as? String)?.contains("Alpha bold end") == true)
    }

    func testSummaryReflectsTheEditedText() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "replace", options: ["find": "Fixture", "replacement": "New title"])
        let attachments = try XCTUnwrap(store.readNote(noteID)["attachments"] as? [[String: Any]])
        _ = try store.editNote(noteID, operation: "attachment-remove", options: ["attachment": attachments[0]["id"]!])
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: URL(fileURLWithPath: "/System/Library/PrivateFrameworks/NotesShared.framework/Resources/NoteData.mom")))
        let stores = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try stores.addPersistentStore(type: .sqlite, at: database, options: [NSReadOnlyPersistentStoreOption: true, NSPersistentHistoryTrackingKey: true])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = stores
        let objectID = try XCTUnwrap(stores.managedObjectID(forURIRepresentation: URL(string: noteID)!))
        let note = try context.existingObject(with: objectID)
        XCTAssertEqual(note.value(forKey: "title") as? String, "New title")
        XCTAssertEqual((note.value(forKey: "attachmentContentInfoCount") as? NSNumber)?.intValue, 0)
    }

    func testSearchMatchesPartialPhrasesAcrossWhitespace() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let id = try store.createNote(inFolder: "Fixture", html: "<h1>Phrase receipt</h1><p>Total\t  amount</p><p>fields were</p><p>failing</p>")
        for query in ["total amount", "fields were failing", "  fields\twere  failing \n", "elds were fail"] {
            let result = try store.search(query, options: ["field": "text"])
            let notes = try XCTUnwrap(result["notes"] as? [[String: Any]])
            XCTAssertEqual(notes.map { $0["id"] as? String }, [id], query)
        }
    }

    func testFuzzySearchMatchesTyposAndRanksExactResultsFirst() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let exact = try store.createNote(inFolder: "Fixture", html: "<h1>Invoice Report</h1><p>System functionality</p>")
        let approximate = try store.createNote(inFolder: "Fixture", html: "<h1>Invocie Report</h1>")
        for query in ["Invocie Reprot", "Invoce Reprt", "Invoixe Repport"] {
            let result = try store.search(query, options: ["field": "title"])
            let notes = try XCTUnwrap(result["notes"] as? [[String: Any]])
            XCTAssertTrue(notes.contains { $0["id"] as? String == exact }, query)
        }
        let result = try store.search("Invoice Report", options: ["field": "title", "limit": 1])
        let notes = try XCTUnwrap(result["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.first?["id"] as? String, exact)
        XCTAssertEqual(notes.first?["matchType"] as? String, "exact")
        XCTAssertEqual(result["total"] as? Int, 2)
        let second = try store.search("Invoice Report", options: ["field": "title", "limit": 1, "offset": 1])
        let secondNotes = try XCTUnwrap(second["notes"] as? [[String: Any]])
        XCTAssertEqual(secondNotes.first?["id"] as? String, approximate)
        XCTAssertEqual(secondNotes.first?["matchType"] as? String, "fuzzy")
        let unrelated = try store.search("Another Document", options: ["field": "title"])
        XCTAssertEqual(unrelated["total"] as? Int, 0)
    }

    func testFuzzySearchKeepsIDsAndPunctuationLiteral() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.createNote(inFolder: "Fixture", html: "<h1>aaab 92847</h1>")
        for (query, field) in [("a+b", "title"), ("92848", "title"), (noteID + "x", "id")] {
            let result = try store.search(query, options: ["field": field])
            XCTAssertEqual(result["total"] as? Int, 0, query)
        }
    }

    func testFuzzySearchKeepsLettersNextToDigitsLiteral() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.createNote(inFolder: "Fixture", html: "<h1>Order abxd1234 and 77wxyz</h1>")
        for query in ["abcd1234", "77wxzz"] {
            XCTAssertEqual(try store.search(query, options: ["field": "title"])["total"] as? Int, 0, query)
        }
        XCTAssertEqual(try store.search("abxd1234", options: ["field": "title"])["total"] as? Int, 1)
        XCTAssertEqual(try store.search("Ordr", options: ["field": "title"])["total"] as? Int, 1)
    }

    func testDocumentIndexRestoresPrivatePermissionsOfAnExistingDirectory() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let index = directory.appendingPathComponent("documents-v1")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let image = directory.appendingPathComponent("pixel.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
        _ = try store.editNote(noteID, operation: "attachment-add", options: ["file": image.path])
        _ = try store.search("anything", options: ["field": "document"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.posixPermissions] as? Int, 0o700)
    }

    func testSearchFindsPDFOnlyTextWithWrappedPhrasesAndTypos() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let id = try store.createNote(inFolder: "Fixture", html: "<h1>Unrelated note</h1>")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        for (index, text) in ["System Functionality", "Mandatory fields were", "failing"].enumerated() {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 30)
            label.frame = NSRect(x: 50, y: 300 - index * 70, width: 900, height: 50)
            view.addSubview(label)
        }
        let pdf = directory.appendingPathComponent("receipt.pdf")
        try view.dataWithPDF(inside: view.bounds).write(to: pdf)
        _ = try store.editNote(id, operation: "attachment-add", options: ["file": pdf.path])
        let noBodyMatch = try store.search("Functionality", options: ["field": "text"])
        XCTAssertEqual(noBodyMatch["total"] as? Int, 0)
        for query in ["fields were failing", "functonality", "unctonality"] {
            for field in ["document", "all"] {
                let result = try store.search(query, options: ["field": field])
                let notes = try XCTUnwrap(result["notes"] as? [[String: Any]])
                XCTAssertEqual(notes.map { $0["id"] as? String }, [id], query)
                XCTAssertTrue((notes.first?["matchedFields"] as? [String])?.contains("document") == true)
                if field == "document" { XCTAssertEqual((result["scannedDocuments"] as? Int ?? 0) + (result["cachedDocuments"] as? Int ?? 0), 1) }
                XCTAssertEqual((result["documentErrors"] as? [[String: Any]])?.count, 0)
            }
        }
    }

    func testDefaultSearchUsesAnExactPDFIndexWithoutRepeatedExtraction() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let id = try store.createNote(inFolder: "Fixture", html: "<h1>Indexed note</h1>")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 200))
        let label = NSTextField(labelWithString: "QUARTZ RECEIPT")
        label.frame = NSRect(x: 30, y: 100, width: 900, height: 50)
        view.addSubview(label)
        let pdf = directory.appendingPathComponent("indexed.pdf")
        try view.dataWithPDF(inside: view.bounds).write(to: pdf)
        let result = try store.editNote(id, operation: "attachment-add", options: ["file": pdf.path])
        let attachments = try XCTUnwrap(result["attachments"] as? [[String: Any]])
        let attachmentID = try XCTUnwrap(attachments.first?["id"] as? String)
        let context = try XCTUnwrap(store.value(forKey: "context") as? NSManagedObjectContext)
        let objectID = try XCTUnwrap(context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: URL(string: attachmentID)!))
        let attachment = try context.existingObject(with: objectID)
        attachment.setValue("QUARTZ RECEIPT", forKey: "ocrSummary")
        try context.save()
        let found = try NBNotes(url: database, readOnly: true).search("quartz receipt", options: [:])
        XCTAssertEqual((found["notes"] as? [[String: Any]])?.first?["id"] as? String, id)
        XCTAssertEqual(found["scannedDocuments"] as? Int, 0)
    }

    func testDocumentIndexReusesTextAcrossQueriesAndInvalidatesChangedFiles() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let pdf = directory.appendingPathComponent("changing.pdf")
        func writePDF(_ text: String, to url: URL) throws {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 30, y: 100, width: 700, height: 50)
            view.addSubview(label)
            try view.dataWithPDF(inside: view.bounds).write(to: url)
        }
        try writePDF("QUARTZ RECEIPT 81926", to: pdf)
        let added = try store.editNote(noteID, operation: "attachment-add", options: ["file": pdf.path])
        let files = try XCTUnwrap(added["attachments"] as? [[String: Any]])
        let attachedPath = try XCTUnwrap(files.first { $0["type"] as? String == "com.adobe.pdf" }?["path"] as? String)
        let first = try store.search("81926", options: ["field": "document"])
        XCTAssertEqual(first["total"] as? Int, 1)
        XCTAssertEqual(first["scannedDocuments"] as? Int, 1)
        let warm = try NBNotes(url: database, readOnly: true).search("quartz", options: ["field": "document"])
        XCTAssertEqual(warm["total"] as? Int, 1)
        XCTAssertEqual(warm["scannedDocuments"] as? Int, 0)
        XCTAssertEqual(warm["cachedDocuments"] as? Int, 1)
        let index = directory.appendingPathComponent("documents-v1")
        let entries = try FileManager.default.contentsOfDirectory(at: index, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: entries[0].path)[.posixPermissions] as? Int, 0o600)
        try writePDF("UPDATED RECEIPT 71635", to: URL(fileURLWithPath: attachedPath))
        let changed = try store.search("71635", options: ["field": "document"])
        XCTAssertEqual(changed["total"] as? Int, 1)
        XCTAssertEqual(changed["scannedDocuments"] as? Int, 1)
        XCTAssertEqual(try store.search("81926", options: ["field": "document"])["total"] as? Int, 0)
        try Data("invalid cached JSON".utf8).write(to: entries[0])
        let recovered = try store.search("71635", options: ["field": "document"])
        XCTAssertEqual(recovered["total"] as? Int, 1)
        XCTAssertEqual(recovered["scannedDocuments"] as? Int, 1)
    }

    func testFuzzySearchMatchesFilenameWordsWithoutChangingPunctuation() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let file = directory.appendingPathComponent("receipt.pdf")
        try Data("fixture".utf8).write(to: file)
        _ = try store.editNote(noteID, operation: "attachment-add", options: ["file": file.path])
        let found = try store.search("recepit.pdf", options: ["field": "attachment"])
        XCTAssertEqual((found["notes"] as? [[String: Any]])?.first?["id"] as? String, noteID)
        let differentPunctuation = try store.search("recepit+pdf", options: ["field": "attachment"])
        XCTAssertEqual(differentPunctuation["total"] as? Int, 0)
    }

    func testSearchFindsTextTablesTagsAndIDs() throws {
        let store = try NBNotes(url: database, readOnly: false)
        _ = try store.editNote(noteID, operation: "tag-add", options: ["name": "project"])
        _ = try store.editNote(noteID, operation: "table-new", options: ["rows": 1, "columns": 1, "grid": [["Invoice 12345"]]])
        for (query, field) in [("ALPHA", "text"), ("Invoice 12345", "text"), ("project", "tag"), (noteID!, "id")] {
            let result = try store.search(query, options: ["field": field, "limit": 10])
            let matches = try XCTUnwrap(result["notes"] as? [[String: Any]])
            XCTAssertEqual(matches.map { $0["id"] as? String }, [noteID], query)
        }
        let missing = try store.search("absent", options: ["field": "all", "limit": 10])
        XCTAssertEqual((missing["notes"] as? [[String: Any]])?.count, 0)
        XCTAssertThrowsError(try store.search("", options: ["field": "all", "limit": 10]))
    }
}
