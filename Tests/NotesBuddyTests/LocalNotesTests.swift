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

    func testNativeFolderAndNoteLifecyclePreservesRichTextAndTables() throws {
        let store = try NBNotes(url: database, readOnly: false)
        let folder = try store.createFolder("Native destination", parent: nil)
        let child = try store.createFolder("Nested", parent: folder)
        XCTAssertThrowsError(try store.createFolder("Native destination", parent: nil))
        let id = try store.createNote(inFolder: folder, html: "<h1>Native title</h1><p>Alpha <b>bold</b></p><table><tr><td>A</td><td>B</td></tr></table>")
        let state = try store.readNote(id)
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
        XCTAssertEqual(result["unavailableDocuments"] as? Int, 1)
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
                if field == "document" { XCTAssertEqual(result["scannedDocuments"] as? Int, 1) }
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
