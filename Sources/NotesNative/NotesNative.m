#import "NotesNative.h"
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import <dlfcn.h>
#import <PDFKit/PDFKit.h>
#import <Vision/Vision.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <signal.h>
#import <errno.h>

static NSUInteger NBWriteCount;
static const int NBSyncSignals[] = {SIGINT, SIGTERM, SIGHUP};
static struct sigaction NBPreviousSyncSignals[3];
static volatile sig_atomic_t NBSyncInterruption;
NSUInteger NBCommittedCommandWrites(void) { return NBWriteCount; }

static NSString *NBSearchText(NSString *text) {
    NSString *spaces = [text stringByReplacingOccurrencesOfString:@"\\s+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
    return [[spaces stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
}

static NSString *NBSearchPattern(NSString *query) {
    NSMutableArray *patterns = [NSMutableArray array];
    NSRegularExpression *parts = [NSRegularExpression regularExpressionWithPattern:@"\\p{L}+|[^\\p{L}]+" options:0 error:nil];
    for (NSTextCheckingResult *part in [parts matchesInString:query options:0 range:NSMakeRange(0, query.length)]) {
        NSString *word = [query substringWithRange:part.range];
        NSMutableArray<NSString *> *characters = [NSMutableArray array];
        [word enumerateSubstringsInRange:NSMakeRange(0, word.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *part, NSRange range, NSRange enclosingRange, BOOL *stop) { [characters addObject:part]; }];
        NSMutableOrderedSet *variants = [NSMutableOrderedSet orderedSetWithObject:[NSRegularExpression escapedPatternForString:word]];
        if (characters.count >= 3 && [word rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet.invertedSet].location == NSNotFound) {
            for (NSUInteger index = 0; index < characters.count; index++) {
                NSString *left = [NSRegularExpression escapedPatternForString:[[characters subarrayWithRange:NSMakeRange(0, index)] componentsJoinedByString:@""]];
                NSString *right = [NSRegularExpression escapedPatternForString:[[characters subarrayWithRange:NSMakeRange(index + 1, characters.count - index - 1)] componentsJoinedByString:@""]];
                if (characters.count >= 4) {
                    [variants addObject:[left stringByAppendingString:right]];
                    [variants addObject:[NSString stringWithFormat:@"%@\\p{L}%@", left, right]];
                    [variants addObject:[NSString stringWithFormat:@"%@\\p{L}%@%@", left, [NSRegularExpression escapedPatternForString:characters[index]], right]];
                }
                if (index + 1 < characters.count) {
                    NSString *tail = [NSRegularExpression escapedPatternForString:[[characters subarrayWithRange:NSMakeRange(index + 2, characters.count - index - 2)] componentsJoinedByString:@""]];
                    [variants addObject:[NSString stringWithFormat:@"%@%@%@%@", left, [NSRegularExpression escapedPatternForString:characters[index + 1]], [NSRegularExpression escapedPatternForString:characters[index]], tail]];
                }
            }
            if (characters.count >= 4) [variants addObject:[[NSRegularExpression escapedPatternForString:word] stringByAppendingString:@"\\p{L}"]];
        }
        [patterns addObject:[NSString stringWithFormat:@"(?:%@)", [[variants array] componentsJoinedByString:@"|"]]];
    }
    return [patterns componentsJoinedByString:@""];
}

static void NBInterruptNotesSync(int signalNumber) { NBSyncInterruption = signalNumber; }
NSInteger NBNotesSyncInterruption(void) { return NBSyncInterruption; }

BOOL NBStartNotesSyncSignals(NSError **error) {
    NBSyncInterruption = 0;
    struct sigaction action = {0};
    action.sa_handler = NBInterruptNotesSync;
    sigemptyset(&action.sa_mask);
    for (NSUInteger index = 0; index < 3; index++) {
        if (sigaction(NBSyncSignals[index], &action, &NBPreviousSyncSignals[index]) == 0) continue;
        int failure = errno;
        for (NSUInteger previous = 0; previous < index; previous++) sigaction(NBSyncSignals[previous], &NBPreviousSyncSignals[previous], NULL);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
        return NO;
    }
    return YES;
}

void NBStopNotesSyncSignals(void) {
    for (NSUInteger index = 0; index < 3; index++) sigaction(NBSyncSignals[index], &NBPreviousSyncSignals[index], NULL);
}

@interface NSWorkspaceOpenConfiguration (NotesBackgroundLaunch)
- (void)_setAdditionalLSOpenOptions:(NSDictionary *)options;
@end

NSWorkspaceOpenConfiguration *NBNotesBackgroundConfiguration(NSError **error) {
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    CFStringRef *background = dlsym(RTLD_DEFAULT, "_kLSOpenOptionBackgroundLaunchKey");
    CFStringRef *withoutRestore = dlsym(RTLD_DEFAULT, "_kLSOpenOptionLaunchWithoutRestoringStateKey");
    if (!background || !withoutRestore || ![configuration respondsToSelector:@selector(_setAdditionalLSOpenOptions:)]) {
        if (error) *error = [NSError errorWithDomain:@"notes-buddy" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Background Notes launch is unavailable on this macOS version"}];
        return nil;
    }
    configuration.activates = NO;
    configuration.hides = YES;
    configuration.promptsUserIfNeeded = NO;
    [configuration _setAdditionalLSOpenOptions:@{(__bridge NSString *)*background:@YES, (__bridge NSString *)*withoutRestore:@YES}];
    return configuration;
}

static NSString *NBRecognizeImage(NSImage *image, NSError **error) {
    CGImageRef pixels = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!pixels) {
        if (error) *error = [NSError errorWithDomain:@"notes-buddy" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot decode document image"}];
        return nil;
    }
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.automaticallyDetectsLanguage = YES;
    VNImageRequestHandler *input = [[VNImageRequestHandler alloc] initWithCGImage:pixels options:@{}];
    if (![input performRequests:@[request] error:error]) return nil;
    NSMutableArray *lines = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        NSString *line = [observation topCandidates:1].firstObject.string;
        if (line) [lines addObject:line];
    }
    return [lines componentsJoinedByString:@"\n"];
}

NSString *NBReadDocumentText(NSURL *url, NSError **error) {
    if (![url checkResourceIsReachableAndReturnError:error]) return nil;
    if ([url.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        PDFDocument *document = [[PDFDocument alloc] initWithURL:url];
        if (!document || document.isLocked) {
            if (error) *error = [NSError errorWithDomain:@"notes-buddy" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot read PDF or PDF is locked"}];
            return nil;
        }
        NSMutableArray *pages = [NSMutableArray array];
        for (NSUInteger index = 0; index < document.pageCount; index++) {
            @autoreleasepool {
                PDFPage *page = [document pageAtIndex:index];
                NSString *text = page.string;
                if (![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
                    NSRect bounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
                    CGFloat scale = MIN(3.0, 3000.0 / MAX(bounds.size.width, bounds.size.height));
                    text = NBRecognizeImage([page thumbnailOfSize:NSMakeSize(bounds.size.width * scale, bounds.size.height * scale) forBox:kPDFDisplayBoxMediaBox], error);
                    if (!text) return nil;
                }
                [pages addObject:text ?: @""];
            }
        }
        return [pages componentsJoinedByString:@"\n"];
    }
    return NBRecognizeImage([[NSImage alloc] initWithContentsOfURL:url], error);
}

@interface NSObject (NotesCalls)
- (id)mergeableString;
- (NSAttributedString *)attributedString;
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string;
- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)string;
- (void)insertAttributedString:(NSAttributedString *)string atIndex:(NSUInteger)index;
- (void)deleteCharactersInRange:(NSRange)range;
- (void)didChangeNoteText;
- (void)saveNoteData;
- (void)updateDerivedAttributesIfNeeded;
- (void)updateChangeCountWithReason:(NSString *)reason;
- (NSArray *)visibleTopLevelAttachments;
- (NSArray *)visibleInlineAttachments;
- (NSURL *)fileURL;
- (NSManagedObject *)addAttachmentWithFileURL:(NSURL *)url;
- (NSManagedObject *)addTableAttachment;
- (id)tableModel;
- (id)table;
- (id)tableDocument;
- (id)innerTableDocument;
- (void)realizeLocalChanges;
- (NSData *)serialize;
- (void)markForDeletion;
- (NSUInteger)rowCount;
- (NSUInteger)columnCount;
- (id)insertRowAtIndex:(NSUInteger)index;
- (id)insertColumnAtIndex:(NSUInteger)index;
- (void)removeRowAtIndex:(NSUInteger)index;
- (void)removeColumnAtIndex:(NSUInteger)index;
- (id)stringForColumnIndex:(NSUInteger)column rowIndex:(NSUInteger)row;
- (void)setAttributedString:(NSAttributedString *)string columnIndex:(NSUInteger)column rowIndex:(NSUInteger)row;
- (void)updateMarkedForDeletionStateInlineAttachmentIsInUse:(BOOL)inUse;
+ (id)newHashtagAttachmentWithIdentifier:(NSString *)identifier hashtagText:(NSString *)text creatingHashtagIfNecessary:(BOOL)create note:(id)note parentAttachment:(id)parent;
+ (id)newLinkAttachmentWithIdentifier:(NSString *)identifier toNote:(id)target fromNote:(id)source parentAttachment:(id)parent;
+ (NSString *)standardizedHashtagRepresentationForDisplayText:(NSString *)text;
+ (void)registerWithICCRCoder;
+ (id)notesContainingHashtagWithStandarizedContent:(NSString *)tag context:(NSManagedObjectContext *)context;
+ (NSArray *)visibleFoldersInContext:(NSManagedObjectContext *)context;
+ (NSManagedObject *)newFolderWithIdentifier:(NSString *)identifier account:(NSManagedObject *)account;
+ (NSManagedObject *)newFolderWithIdentifier:(NSString *)identifier parentFolder:(NSManagedObject *)parent;
+ (NSManagedObject *)newEmptyNoteWithIdentifier:(NSString *)identifier folder:(NSManagedObject *)folder;
+ (void)deleteFolder:(NSManagedObject *)folder;
+ (NSAttributedString *)attributedStringFromHTMLString:(NSString *)html;
- (NSString *)htmlString;
- (NSManagedObject *)parentFolder;
- (NSManagedObject *)trashFolder;
- (void)createTrashFolder;
- (BOOL)isPinnable;
- (BOOL)isImage;
- (BOOL)isDrawing;
- (BOOL)isAudio;
- (BOOL)isScannedDocument;
- (void)changePinStatusIfPossible;
- (id)initWithAttributedString:(NSAttributedString *)text replicaID:(NSUUID *)replica;
- (id)document;
- (void)replaceWithDocument:(id)document;
- (NSString *)searchableTextContentWithoutTitle;
- (void)setNote:(NSManagedObject *)note;
- (void)convertNSTablesToICTables:(NSMutableAttributedString *)text pasteboardTypes:(NSArray *)types filterPastedAttributes:(BOOL)filter isReadingSelectionFromPasteboard:(BOOL)reading;
@end

@implementation NBNotes {
    NSManagedObjectContext *_context;
    BOOL _readOnly;
    BOOL _liveStore;
}

static NSError *NBError(NSString *message) {
    return [NSError errorWithDomain:@"notes-buddy" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static void NBRequire(BOOL valid, NSString *message) {
    if (!valid) [NSException raise:@"NotesEdit" format:@"%@", message];
}

+ (NSManagedObjectModel *)installedModel {
    static NSManagedObjectModel *model;
    static dispatch_once_t loading;
    dispatch_once(&loading, ^{
        NSURL *url = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/NotesShared.framework/Resources/NoteData.mom"];
        model = [[NSManagedObjectModel alloc] initWithContentsOfURL:url];
    });
    return model;
}

- (instancetype)initWithURL:(NSURL *)url readOnly:(BOOL)readOnly error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    @try {
        NSURL *liveURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"]];
        _liveStore = [url.URLByResolvingSymlinksInPath isEqual:liveURL.URLByResolvingSymlinksInPath];
        NBRequire(readOnly || !_liveStore || ![NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Notes"].count, @"Notes is still running, no changes made");
        if (!dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_LAZY)) {
            if (error) *error = NBError(@"The installed Notes framework is unavailable");
            return nil;
        }
        NBRequire(dlopen("/System/Library/PrivateFrameworks/NotesEditor.framework/NotesEditor", RTLD_LAZY) != NULL, @"The installed Notes editor framework is unavailable");
        static dispatch_once_t registration;
        dispatch_once(&registration, ^{
            [NSClassFromString(@"ICTable") registerWithICCRCoder];
        });
        NSManagedObjectModel *model = [NBNotes installedModel];
        if (!model || ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            if (error) *error = NBError(@"Notes model or database not found");
            return nil;
        }
        NSPersistentStoreCoordinator *stores = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        NSDictionary *options = @{
            NSReadOnlyPersistentStoreOption:@(readOnly),
            NSMigratePersistentStoresAutomaticallyOption:@NO,
            NSInferMappingModelAutomaticallyOption:@NO,
            NSPersistentHistoryTrackingKey:@YES,
            NSPersistentStoreRemoteChangeNotificationPostOptionKey:@YES
        };
        if (![stores addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:options error:error]) return nil;
        _context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        _context.persistentStoreCoordinator = stores;
        _context.transactionAuthor = @"notes-buddy";
        _context.mergePolicy = NSErrorMergePolicy;
        _readOnly = readOnly;
        return self;
    } @catch (NSException *exception) {
        if (error) *error = NBError(exception.reason);
        return nil;
    }
}

- (void)requireWritable {
    NBRequire(!_readOnly, @"Database opened read-only");
    NBRequire(!_liveStore || ![NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Notes"].count, @"Notes is running, changes were not saved");
}

- (NSDictionary *)importNoteWithIdentifier:(NSString *)identifier folder:(NSString *)folder html:(NSString *)html tags:(NSString *)tags files:(NSArray<NSString *> *)files error:(NSError **)error {
    @try {
        [self requireWritable];
        NBRequire([[NSUUID alloc] initWithUUIDString:identifier] != nil, @"Import identifier must be a UUID");
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        request.predicate = [NSPredicate predicateWithFormat:@"identifier == %@", identifier];
        NSArray *existing = [_context executeFetchRequest:request error:error];
        if (!existing) return nil;
        NBRequire(existing.count <= 1, @"Duplicate import identifier in Notes");
        if (existing.count) {
            NSManagedObject *note = existing.firstObject;
            NBRequire(![[note valueForKey:@"isDeletedOrInTrash"] boolValue], @"Imported note was deleted, refusing to recreate it");
            BOOL onlyTables = YES;
            for (NSManagedObject *attachment in [note visibleTopLevelAttachments]) {
                if (![[attachment valueForKey:@"typeUTI"] isEqualToString:@"com.apple.notes.table"]) onlyTables = NO;
            }
            BOOL reserved = ![[note valueForKey:@"noteData"] valueForKey:@"data"] && ![[[[note mergeableString] attributedString] string] length] && onlyTables && ![note visibleInlineAttachments].count && ![[note valueForKey:@"isInCloud"] boolValue];
            if (!reserved) return @{@"id":note.objectID.URIRepresentation.absoluteString, @"imported":@NO};
            NBRequire([[note valueForKey:@"folder"] isEqual:[self folder:folder]], @"Incomplete import belongs to another folder");
            [_context deleteObject:note];
        }
        for (NSString *file in files) NBRequire([[NSFileManager defaultManager] isReadableFileAtPath:file], @"Import attachment is unavailable");
        NSManagedObject *note = [self newNoteInFolder:folder html:html identifier:identifier];
        id document = [note mergeableString];
        NSString *text = [[document attributedString] string];
        NSRegularExpression *tasks = [NSRegularExpression regularExpressionWithPattern:@"NBTODO([01])_[0-9A-F]{32}_[0-9]+ " options:0 error:error];
        for (NSTextCheckingResult *task in [[tasks matchesInString:text options:0 range:NSMakeRange(0, text.length)] reverseObjectEnumerator]) {
            NSString *token = [text substringWithRange:task.range];
            [self formatDocument:document options:@{@"find":token, @"style":@"checklist", @"checked":@([[text substringWithRange:[task rangeAtIndex:1]] isEqualToString:@"1"])}];
            [document replaceCharactersInRange:task.range withString:@""];
        }
        [self saveNote:note];
        if (tags.length && ![self changeNote:note operation:@"tag-add" options:@{@"name":tags} error:error]) { [_context rollback]; return nil; }
        for (NSUInteger index = 0; index < files.count; index++) {
            NSString *token = [NSString stringWithFormat:@"NBATTACHMENT%lu_%@", (unsigned long)index, [identifier stringByReplacingOccurrencesOfString:@"-" withString:@""]];
            NSManagedObject *created = [self copyAttachmentFromURL:[NSURL fileURLWithPath:files[index]] toNote:note error:error];
            [self insertAttachment:created intoDocument:document replacingToken:token];
        }
        [self saveNote:note];
        if (![self commitChanges:error]) return nil;
        return @{@"id":note.objectID.URIRepresentation.absoluteString, @"imported":@YES};
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return nil; }
}

- (BOOL)commitChanges:(NSError **)error {
    if (![self saveChanges:error]) return NO;
    if (_liveStore) NBWriteCount++;
    return YES;
}

- (BOOL)saveChanges:(NSError **)error {
    [self requireWritable];
    NSMutableSet *changed = [_context.insertedObjects mutableCopy];
    [changed unionSet:_context.updatedObjects];
    for (NSManagedObject *object in changed) {
        if ([object isKindOfClass:NSClassFromString(@"ICCloudSyncingObject")] && !object.isDeleted) [object updateChangeCountWithReason:@"notes-buddy"];
    }
    if ([_context save:error]) { [_context reset]; return YES; }
    [_context rollback];
    return NO;
}

- (BOOL)pruneEmptyActivityEvents:(NSError **)error {
    @try {
        [self requireWritable];
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICCloudSyncingObject"];
        request.predicate = [NSPredicate predicateWithFormat:@"activityEventsData != nil"];
        NSArray *objects = [_context executeFetchRequest:request error:error];
        if (!objects) return NO;
        for (NSManagedObject *object in objects) {
            if ([[object valueForKey:@"isSharedViaICloud"] boolValue] || [[object valueForKey:@"markedForDeletion"] boolValue]) continue;
            if ([object isKindOfClass:NSClassFromString(@"ICNote")] && ([[object valueForKey:@"isPasswordProtected"] boolValue] || [[object valueForKey:@"isDeletedOrInTrash"] boolValue])) continue;
            NSObject *document = [object valueForKey:@"activityEventsDocument"];
            if ([[document valueForKey:@"futureVersionCount"] unsignedIntegerValue] != 0) continue;
            NSObject *events = [document valueForKey:@"orderedSet"];
            NBRequire(events != nil, @"Cannot decode Notes activity events, metadata remains unchanged");
            if ([[events valueForKey:@"count"] unsignedIntegerValue] != 0) continue;
            [object setValue:nil forKey:@"activityEventsData"];
        }
        return !_context.hasChanges || [self saveChanges:error];
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return NO; }
}

- (NSDictionary *)cloudStatus:(NSError **)error {
    @try {
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICCloudSyncingObject"];
        NSArray *objects = [_context executeFetchRequest:request error:error];
        if (!objects) return nil;
        NSUInteger pending = 0, pendingNotes = 0, acknowledgedNotes = 0, notes = 0;
        for (NSManagedObject *object in objects) {
            if (![[object valueForKey:@"isInICloudAccount"] boolValue]) continue;
            BOOL needsPush = [[object valueForKey:@"needsToBePushedToCloud"] boolValue] || [[object valueForKey:@"needsToBeDeletedFromCloud"] boolValue];
            if (needsPush) pending++;
            if ([object.entity.name isEqualToString:@"ICNote"]) {
                notes++;
                if (needsPush) pendingNotes++;
                if ([[object valueForKey:@"isInCloud"] boolValue] && [[object valueForKey:@"hasSuccessfullyPushedLatestVersionToCloud"] boolValue]) acknowledgedNotes++;
            }
        }
        return @{@"pendingObjects":@(pending), @"pendingNotes":@(pendingNotes), @"acknowledgedNotes":@(acknowledgedNotes), @"icloudNotes":@(notes)};
    } @catch (NSException *exception) { if (error) *error = NBError(exception.reason); return nil; }
}

- (BOOL)queueUnsyncedObjects:(NSArray<NSString *> *)identifiers error:(NSError **)error {
    @try {
        [self requireWritable];
        NSMutableSet *objects = [NSMutableSet set];
        for (NSString *identifier in identifiers) {
            NSManagedObjectID *objectID = [_context.persistentStoreCoordinator managedObjectIDForURIRepresentation:[NSURL URLWithString:identifier]];
            NBRequire(objectID != nil, @"Cloud queue object not found");
            NSManagedObject *object = [_context existingObjectWithID:objectID error:error];
            if (!object) return NO;
            NBRequire([@[@"ICNote", @"ICFolder"] containsObject:object.entity.name], @"Cloud queue accepts notes and folders only");
            NBRequire(![[object valueForKey:@"isSharedViaICloud"] boolValue] && ![[object valueForKey:@"markedForDeletion"] boolValue], @"Shared and deleted objects cannot be queued");
            if ([object.entity.name isEqualToString:@"ICNote"]) NBRequire(![[object valueForKey:@"isPasswordProtected"] boolValue] && ![[object valueForKey:@"isDeletedOrInTrash"] boolValue], @"Protected and deleted notes cannot be queued");
            [objects addObject:object];
        }
        NSMutableArray *remaining = [[objects allObjects] mutableCopy];
        while (remaining.count) {
            NSManagedObject *object = remaining.lastObject;
            [remaining removeLastObject];
            for (NSString *key in @[@"folder", @"parentFolder", @"attachments", @"inlineAttachments", @"media", @"previewImages", @"hashtag"]) {
                if (!object.entity.relationshipsByName[key]) continue;
                id value = [object valueForKey:key];
                NSArray *related = [value isKindOfClass:NSSet.class] ? [value allObjects] : [value isKindOfClass:NSManagedObject.class] ? @[value] : @[];
                for (NSManagedObject *child in related) {
                    if (![objects containsObject:child]) { [objects addObject:child]; [remaining addObject:child]; }
                }
            }
        }
        BOOL changed = NO;
        for (NSManagedObject *object in objects) {
            if ([object isKindOfClass:NSClassFromString(@"ICCloudSyncingObject")] && [[object valueForKey:@"isInICloudAccount"] boolValue] && ![[object valueForKey:@"markedForDeletion"] boolValue] && ![[object valueForKey:@"isInCloud"] boolValue] && ![[object valueForKey:@"needsToBePushedToCloud"] boolValue]) {
                [object updateChangeCountWithReason:@"notes-buddy import"];
                changed = YES;
            }
        }
        return !changed || [self commitChanges:error];
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return NO; }
}

- (NSManagedObject *)folder:(NSString *)reference {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSManagedObject *folder in [NSClassFromString(@"ICFolder") visibleFoldersInContext:_context]) {
        if ([folder.objectID.URIRepresentation.absoluteString isEqualToString:reference] || [[folder valueForKey:@"title"] isEqualToString:reference]) [matches addObject:folder];
    }
    NBRequire(matches.count == 1, matches.count ? @"Folder name is ambiguous, use its id" : @"Folder not found");
    return matches.firstObject;
}

- (NSArray<NSDictionary *> *)listFolders:(NSError **)error {
    @try {
        NSArray *folders = [NSClassFromString(@"ICFolder") visibleFoldersInContext:_context];
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        request.predicate = [NSPredicate predicateWithFormat:@"markedForDeletion == NO"];
        NSArray *notes = [_context executeFetchRequest:request error:error];
        if (!notes) return nil;
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        NSMutableDictionary *deletedCounts = [NSMutableDictionary dictionary];
        NSMutableDictionary *children = [NSMutableDictionary dictionary];
        for (NSManagedObject *note in notes) {
            NSManagedObject *folder = [note valueForKey:@"folder"];
            if (!folder) continue;
            NSString *key = folder.objectID.URIRepresentation.absoluteString;
            NSMutableDictionary *values = [[note valueForKey:@"isDeletedOrInTrash"] boolValue] ? deletedCounts : counts;
            values[key] = @([values[key] unsignedIntegerValue] + 1);
        }
        for (NSManagedObject *folder in folders) {
            NSManagedObject *parent = [folder parentFolder];
            if (parent) {
                NSString *key = parent.objectID.URIRepresentation.absoluteString;
                children[key] = @([children[key] unsignedIntegerValue] + 1);
            }
        }
        NSMutableArray *result = [NSMutableArray array];
        for (NSManagedObject *folder in folders) {
            NSString *key = folder.objectID.URIRepresentation.absoluteString;
            NSUInteger noteCount = [counts[key] unsignedIntegerValue];
            NSUInteger deletedCount = [deletedCounts[key] unsignedIntegerValue];
            NSUInteger subfolderCount = [children[key] unsignedIntegerValue];
            NSMutableArray *names = [NSMutableArray array];
            NSMutableSet *visited = [NSMutableSet set];
            for (NSManagedObject *current = folder; current; current = [current parentFolder]) {
                NBRequire(![visited containsObject:current.objectID], @"Folder hierarchy contains a cycle");
                [visited addObject:current.objectID];
                [names insertObject:[current valueForKey:@"title"] ?: @"" atIndex:0];
            }
            NSMutableDictionary *value = [@{@"id":key, @"name":[folder valueForKey:@"title"] ?: @"", @"path":[names componentsJoinedByString:@"/"], @"noteCount":@(noteCount), @"deletedNoteCount":@(deletedCount), @"subfolderCount":@(subfolderCount), @"empty":@((BOOL)(noteCount + deletedCount + subfolderCount == 0))} mutableCopy];
            NSManagedObject *parent = [folder parentFolder];
            if (parent) value[@"parent"] = parent.objectID.URIRepresentation.absoluteString;
            [result addObject:value];
        }
        return result;
    } @catch (NSException *exception) { if (error) *error = NBError(exception.reason); return nil; }
}

- (NSArray<NSDictionary *> *)listNotesInFolder:(NSString *)reference error:(NSError **)error {
    @try {
        NSManagedObject *folder = [self folder:reference];
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        request.predicate = [NSPredicate predicateWithFormat:@"folder == %@", folder];
        NSArray *notes = [_context executeFetchRequest:request error:error];
        if (!notes) return nil;
        NSMutableArray *result = [NSMutableArray array];
        for (NSManagedObject *note in notes) {
            if ([[note valueForKey:@"isDeletedOrInTrash"] boolValue]) continue;
            [result addObject:@{@"id":note.objectID.URIRepresentation.absoluteString, @"identifier":[note valueForKey:@"identifier"], @"hasDocument":@((BOOL)([[note valueForKey:@"noteData"] valueForKey:@"data"] != nil)), @"title":[note valueForKey:@"title"] ?: @"", @"folder":[folder valueForKey:@"title"] ?: @"", @"modified":[note valueForKey:@"modificationDate"] ?: [NSDate distantPast]}];
        }
        return result;
    } @catch (NSException *exception) { if (error) *error = NBError(exception.reason); return nil; }
}

- (NSString *)createFolder:(NSString *)name parent:(NSString *)reference error:(NSError **)error {
    @try {
        [self requireWritable];
        NBRequire([name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length, @"Folder name must not be empty");
        NSManagedObject *parent = reference ? [self folder:reference] : nil;
        NSManagedObject *account = parent ? [parent valueForKey:@"account"] : nil;
        if (!parent) {
            NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICAccount"];
            request.predicate = [NSPredicate predicateWithFormat:@"markedForDeletion == NO"];
            NSArray *accounts = [_context executeFetchRequest:request error:error];
            if (!accounts) return nil;
            NBRequire(accounts.count == 1, @"Root folder creation requires one Notes account, otherwise specify --parent");
            account = accounts.firstObject;
        }
        if (parent) NBRequire(![[parent valueForKey:@"isSharedViaICloud"] boolValue] && ![[parent valueForKey:@"isSmartFolder"] boolValue] && ![[parent valueForKey:@"isTrashFolder"] boolValue], @"Parent folder cannot be shared, smart or deleted");
        for (NSManagedObject *folder in [NSClassFromString(@"ICFolder") visibleFoldersInContext:_context]) {
            BOOL sameParent = parent ? [[folder parentFolder] isEqual:parent] : [folder parentFolder] == nil;
            NBRequire(!(sameParent && [[folder valueForKey:@"account"] isEqual:account] && [[folder valueForKey:@"title"] isEqualToString:name]), @"Folder already exists");
        }
        NSManagedObject *created = parent ? [NSClassFromString(@"ICFolder") newFolderWithIdentifier:NSUUID.UUID.UUIDString parentFolder:parent] : [NSClassFromString(@"ICFolder") newFolderWithIdentifier:NSUUID.UUID.UUIDString account:account];
        NBRequire(created != nil, @"Notes could not create the folder");
        [created setValue:name forKey:@"title"];
        if (![self commitChanges:error]) return nil;
        return created.objectID.URIRepresentation.absoluteString;
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return nil; }
}

- (BOOL)removeFolder:(NSString *)reference error:(NSError **)error {
    @try {
        [self requireWritable];
        NSManagedObject *folder = [self folder:reference];
        NBRequire(![[folder valueForKey:@"isSystemFolder"] boolValue] && ![[folder valueForKey:@"isSharedViaICloud"] boolValue], @"System and shared folders cannot be removed");
        NSArray *notes = [self listNotesInFolder:reference error:error];
        if (!notes) return NO;
        NBRequire(notes.count == 0, @"Folder has notes, move or remove them first");
        for (NSManagedObject *other in [NSClassFromString(@"ICFolder") visibleFoldersInContext:_context]) NBRequire(![[other parentFolder] isEqual:folder], @"Folder has subfolders, remove them first");
        [NSClassFromString(@"ICFolder") deleteFolder:folder];
        return [self commitChanges:error];
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return NO; }
}

- (void)writeHTML:(NSString *)html toNote:(NSManagedObject *)note {
    NSMutableAttributedString *text = [[NSClassFromString(@"ICNote") attributedStringFromHTMLString:html] mutableCopy];
    NBRequire(text != nil, @"Notes could not read the HTML");
    id controller = [[NSClassFromString(@"ICTextController") alloc] init];
    [controller setNote:note];
    [controller convertNSTablesToICTables:text pasteboardTypes:@[] filterPastedAttributes:NO isReadingSelectionFromPasteboard:NO];
    id storage = [[NSClassFromString(@"ICTTTextStorage") alloc] initWithAttributedString:text replicaID:NSUUID.UUID];
    NBRequire(storage != nil, @"Notes text storage is unavailable");
    [note replaceWithDocument:[storage document]];
    [self saveNote:note];
}

- (NSManagedObject *)newNoteInFolder:(NSString *)reference html:(NSString *)html identifier:(NSString *)identifier {
    NSManagedObject *folder = [self folder:reference];
    NBRequire(![[folder valueForKey:@"isTrashFolder"] boolValue] && ![[folder valueForKey:@"isSmartFolder"] boolValue] && ![[folder valueForKey:@"isSharedViaICloud"] boolValue], @"Cannot create notes in a deleted, smart or shared folder");
    NSManagedObject *note = [NSClassFromString(@"ICNote") newEmptyNoteWithIdentifier:identifier folder:folder];
    NBRequire(note != nil, @"Notes could not create the note");
    [self writeHTML:html toNote:note];
    return note;
}

- (NSString *)createNoteInFolder:(NSString *)reference html:(NSString *)html error:(NSError **)error {
    @try {
        [self requireWritable];
        NSManagedObject *note = [self newNoteInFolder:reference html:html identifier:NSUUID.UUID.UUIDString];
        if (![self commitChanges:error]) return nil;
        return note.objectID.URIRepresentation.absoluteString;
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return nil; }
}

- (BOOL)moveNote:(NSString *)identifier toFolder:(NSString *)reference error:(NSError **)error {
    @try {
        [self requireWritable];
        NSManagedObject *note = [self note:identifier error:error];
        if (!note) return NO;
        NSManagedObject *folder = [self folder:reference];
        NBRequire(![[note valueForKey:@"isSharedViaICloud"] boolValue] && ![[note valueForKey:@"isDeletedOrInTrash"] boolValue], @"Shared and deleted notes cannot be moved");
        NBRequire(![[folder valueForKey:@"isSharedViaICloud"] boolValue] && ![[folder valueForKey:@"isTrashFolder"] boolValue] && ![[folder valueForKey:@"isSmartFolder"] boolValue], @"Target folder cannot be shared, smart or deleted");
        NBRequire([[note valueForKey:@"account"] isEqual:[folder valueForKey:@"account"]], @"Moving notes between accounts is not supported");
        [self changeFolder:folder forNote:note];
        return [self commitChanges:error];
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return NO; }
}

- (BOOL)deleteNote:(NSString *)identifier error:(NSError **)error {
    @try {
        [self requireWritable];
        NSManagedObject *note = [self note:identifier error:error];
        if (!note) return NO;
        NBRequire(![[note valueForKey:@"isSharedViaICloud"] boolValue] && ![[note valueForKey:@"isDeletedOrInTrash"] boolValue], @"Shared and deleted notes cannot be removed");
        NSManagedObject *account = [note valueForKey:@"account"];
        if (![account trashFolder]) [account createTrashFolder];
        NBRequire([account trashFolder] != nil, @"Notes has no Recently Deleted folder");
        [self changeFolder:[account trashFolder] forNote:note];
        return [self commitChanges:error];
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return NO; }
}

- (void)changeFolder:(NSManagedObject *)folder forNote:(NSManagedObject *)note {
    [note setValue:folder forKey:@"folder"];
    [note setValue:NSDate.date forKey:@"folderModificationDate"];
    [note updateDerivedAttributesIfNeeded];
}

- (NSString *)htmlForNote:(NSString *)identifier error:(NSError **)error {
    @try { NSManagedObject *note = [self note:identifier error:error]; return note ? [note htmlString] : nil; }
    @catch (NSException *exception) { if (error) *error = NBError(exception.reason); return nil; }
}

- (BOOL)setHTML:(NSString *)html forNote:(NSString *)identifier error:(NSError **)error {
    @try {
        [self requireWritable];
        NSManagedObject *note = [self note:identifier error:error];
        if (!note) return NO;
        NBRequire([[self describeNote:note][@"canRewriteHTML"] boolValue], @"HTML rewrite would lose objects or checklist state, use edit, insert, format or table");
        [self writeHTML:html toNote:note];
        return [self commitChanges:error];
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return NO; }
}

- (NSManagedObject *)note:(NSString *)identifier error:(NSError **)error {
    NSURL *url = [NSURL URLWithString:identifier];
    NSManagedObjectID *objectID = url ? [_context.persistentStoreCoordinator managedObjectIDForURIRepresentation:url] : nil;
    if (!objectID || ![objectID.entity.name isEqualToString:@"ICNote"]) {
        if (error) *error = NBError(@"Note id does not belong to this Notes database");
        return nil;
    }
    NSManagedObject *note = [_context existingObjectWithID:objectID error:error];
    if (!note) return nil;
    if ([[note valueForKey:@"isPasswordProtected"] boolValue]) {
        if (error) *error = NBError(@"Password-protected notes are not supported");
        return nil;
    }
    return note;
}

- (NSArray<NSManagedObject *> *)attachmentsInNote:(NSManagedObject *)note {
    NSMutableDictionary *byIdentifier = [NSMutableDictionary dictionary];
    for (NSManagedObject *attachment in [note visibleTopLevelAttachments]) {
        byIdentifier[[attachment valueForKey:@"identifier"]] = attachment;
    }
    NSMutableArray *ordered = [NSMutableArray array];
    NSAttributedString *text = [[note mergeableString] attributedString];
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        NSString *identifier = [value valueForKey:@"attachmentIdentifier"];
        NSManagedObject *attachment = identifier ? byIdentifier[identifier] : nil;
        if (attachment) {
            [ordered addObject:attachment];
            [byIdentifier removeObjectForKey:identifier];
        }
    }];
    return ordered;
}

- (NSArray<NSString *> *)backupAttachmentPaths:(NSError **)error {
    @try {
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        request.predicate = [NSPredicate predicateWithFormat:@"markedForDeletion == NO"];
        NSArray *notes = [_context executeFetchRequest:request error:error];
        if (!notes) return nil;
        NSMutableOrderedSet *paths = [NSMutableOrderedSet orderedSet];
        for (NSManagedObject *note in notes) {
            NSMutableSet *attachments = [NSMutableSet set];
            for (id collection in @[[note visibleTopLevelAttachments], [note visibleInlineAttachments]]) {
                for (NSManagedObject *attachment in collection) [attachments addObject:attachment];
            }
            for (NSManagedObject *attachment in attachments) {
                NSURL *file = [attachment fileURL];
                NSString *type = [attachment valueForKey:@"typeUTI"];
                BOOL storedDrawing = [attachment isDrawing] && [[attachment valueForKey:@"mergeableData"] length] > 0;
                BOOL needsFile = !storedDrawing && ([attachment isImage] || [attachment isDrawing] || [attachment isAudio] || [attachment isScannedDocument] || [type isEqualToString:@"com.adobe.pdf"] || [type hasPrefix:@"public."]);
                NBRequire(!needsFile || file != nil, [NSString stringWithFormat:@"Attachment %@ (%@) has no local file, no complete backup created", attachment.objectID.URIRepresentation.absoluteString, type]);
                if (file) {
                    NBRequire([file checkResourceIsReachableAndReturnError:nil], @"A note attachment is unavailable locally, a complete backup is unavailable");
                    [paths addObject:file.path];
                }
            }
        }
        return paths.array;
    } @catch (NSException *exception) {
        if (error) *error = NBError(exception.reason);
        return nil;
    }
}

- (NSDictionary *)describeNote:(NSManagedObject *)note {
    NSMutableArray *folderNames = [NSMutableArray array];
    NSMutableSet *visitedFolders = [NSMutableSet set];
    NSManagedObject *noteFolder = [note valueForKey:@"folder"];
    for (NSManagedObject *folder = noteFolder; folder; folder = [folder parentFolder]) {
        NBRequire(![visitedFolders containsObject:folder.objectID], @"Folder hierarchy contains a cycle");
        [visitedFolders addObject:folder.objectID];
        [folderNames insertObject:[folder valueForKey:@"title"] ?: @"" atIndex:0];
    }
    NSMutableArray *attachments = [NSMutableArray array];
    NSMutableArray *tables = [NSMutableArray array];
    BOOL hasNonTableAttachment = NO;
    for (NSManagedObject *attachment in [self attachmentsInNote:note]) {
        NSURL *file = [attachment fileURL];
        NSMutableDictionary *item = [@{
            @"id":attachment.objectID.URIRepresentation.absoluteString,
            @"identifier":[attachment valueForKey:@"identifier"],
            @"type":[attachment valueForKey:@"typeUTI"] ?: @"",
            @"name":file.lastPathComponent ?: @"",
            @"available":@([file checkResourceIsReachableAndReturnError:nil]),
            @"viewSize":[attachment valueForKey:@"preferredViewSize"]
        } mutableCopy];
        if (file) item[@"path"] = file.path;
        [attachments addObject:item];
        if ([[attachment valueForKey:@"isTable"] boolValue]) {
            id table = [[attachment tableModel] table];
            NSMutableArray *rows = [NSMutableArray array];
            for (NSUInteger r = 0; r < [table rowCount]; r++) {
                NSMutableArray *cells = [NSMutableArray array];
                for (NSUInteger c = 0; c < [table columnCount]; c++) {
                    id value = [table stringForColumnIndex:c rowIndex:r];
                    [cells addObject:value == nil ? @"" : ([value isKindOfClass:NSString.class] ? value : [value string])];
                }
                [rows addObject:cells];
            }
            [tables addObject:rows];
        } else {
            hasNonTableAttachment = YES;
        }
    }
    NSMutableArray *tags = [NSMutableArray array];
    NSMutableArray *links = [NSMutableArray array];
    for (NSManagedObject *attachment in [note visibleInlineAttachments]) {
        if ([[attachment valueForKey:@"isHashtagAttachment"] boolValue]) {
            [tags addObject:@{
                @"id":attachment.objectID.URIRepresentation.absoluteString,
                @"name":[attachment valueForKey:@"displayText"] ?: @"",
                @"contentIdentifier":[attachment valueForKey:@"tokenContentIdentifier"] ?: @""
            }];
        }
        if ([[attachment valueForKey:@"isLinkAttachment"] boolValue]) {
            NSManagedObject *target = [attachment valueForKey:@"linkedNote"];
            NSMutableDictionary *link = [@{
                @"id":attachment.objectID.URIRepresentation.absoluteString,
                @"name":[attachment valueForKey:@"displayText"] ?: @""
            } mutableCopy];
            if (target) link[@"target"] = target.objectID.URIRepresentation.absoluteString;
            [links addObject:link];
        }
    }
    NSAttributedString *text = [[note mergeableString] attributedString];
    NSMutableArray *runs = [NSMutableArray array];
    [text enumerateAttributesInRange:NSMakeRange(0, text.length) options:0 usingBlock:^(NSDictionary *attributes, NSRange range, BOOL *stop) {
        NSUInteger hints = [attributes[@"TTHints"] unsignedIntegerValue];
        NSMutableDictionary *run = [@{
            @"text":[text.string substringWithRange:range], @"location":@(range.location), @"length":@(range.length),
            @"bold":@((BOOL)((hints & 1) != 0)), @"italic":@((BOOL)((hints & 2) != 0))
        } mutableCopy];
        id style = attributes[@"TTStyle"];
        if (style) {
            run[@"style"] = [style valueForKey:@"style"];
            id todo = [style valueForKey:@"todo"];
            if (todo) run[@"checked"] = [todo valueForKey:@"done"];
        }
        [runs addObject:run];
    }];
    return @{
        @"id":note.objectID.URIRepresentation.absoluteString,
        @"title":[note valueForKey:@"title"] ?: @"",
        @"folder":noteFolder.objectID.URIRepresentation.absoluteString ?: @"",
        @"folderPath":[folderNames componentsJoinedByString:@"/"],
        @"pinned":@([[note valueForKey:@"isPinned"] boolValue]),
        @"needsCloudPush":[note valueForKey:@"needsToBePushedToCloud"],
        @"inCloud":[note valueForKey:@"isInCloud"],
        @"cloudAcknowledged":@((BOOL)([[note valueForKey:@"isInCloud"] boolValue] && [[note valueForKey:@"hasSuccessfullyPushedLatestVersionToCloud"] boolValue])),
        @"canRewriteHTML":@((BOOL)(!hasNonTableAttachment && ![note visibleInlineAttachments].count && ![[note valueForKey:@"hasChecklist"] boolValue] && ![[note valueForKey:@"isSharedViaICloud"] boolValue] && ![[note valueForKey:@"isDeletedOrInTrash"] boolValue])),
        @"text":text.string ?: @"",
        @"attachments":attachments,
        @"tags":tags,
        @"links":links,
        @"runs":runs,
        @"tables":tables
    };
}

- (NSArray<NSValue *> *)rangesForText:(NSString *)find inString:(NSString *)text all:(BOOL)all {
    NBRequire(find.length && ![find containsString:@"\uFFFC"], @"Text selection must be nonempty and cannot include attachment markers");
    NSMutableArray *ranges = [NSMutableArray array];
    NSRange remaining = NSMakeRange(0, text.length);
    while (remaining.length) {
        NSRange range = [text rangeOfString:find options:NSLiteralSearch range:remaining];
        if (range.location == NSNotFound) break;
        [ranges addObject:[NSValue valueWithRange:range]];
        remaining = NSMakeRange(NSMaxRange(range), text.length - NSMaxRange(range));
    }
    NBRequire(ranges.count, @"Text not found");
    NBRequire(ranges.count == 1 || all, @"Text occurs more than once, use --all");
    return ranges;
}

- (NSUInteger)position:(NSDictionary *)options inDocument:(id)document {
    NSString *before = options[@"before"];
    NSString *after = options[@"after"];
    NBRequire(!(before && after), @"Choose either --before or --after");
    NSString *text = [[document attributedString] string];
    if (!before && !after) return text.length;
    NSRange range = [[self rangesForText:before ?: after inString:text all:NO].firstObject rangeValue];
    return before ? range.location : NSMaxRange(range);
}

- (NSAttributedString *)marker:(NSManagedObject *)attachment {
    id marker = [[NSClassFromString(@"ICTTAttachment") alloc] init];
    [marker setValue:[attachment valueForKey:@"identifier"] forKey:@"attachmentIdentifier"];
    [marker setValue:[attachment valueForKey:@"typeUTI"] forKey:@"attachmentUTI"];
    return [[NSAttributedString alloc] initWithString:@"\uFFFC" attributes:@{NSAttachmentAttributeName:marker}];
}

- (void)insertAttachment:(NSManagedObject *)attachment intoDocument:(id)document replacingToken:(NSString *)token {
    NSAttributedString *marker = [self marker:attachment];
    NSString *text = [[document attributedString] string];
    if (![text containsString:token]) { [document insertAttributedString:marker atIndex:text.length]; return; }
    for (NSValue *range in [[self rangesForText:token inString:text all:YES] reverseObjectEnumerator]) [document replaceCharactersInRange:range.rangeValue withAttributedString:marker];
}

- (NSManagedObject *)copyAttachmentFromURL:(NSURL *)file toNote:(NSManagedObject *)note error:(NSError **)error {
    BOOL directory = NO;
    NBRequire([[NSFileManager defaultManager] fileExistsAtPath:file.path isDirectory:&directory] && !directory, @"Attachment file not found or is a directory");
    [note setValue:@NO forKey:@"shouldAddMediaAsynchronously"];
    NSManagedObject *created = [note addAttachmentWithFileURL:file];
    NBRequire(created != nil && [[created fileURL] checkResourceIsReachableAndReturnError:error], @"Notes could not copy the attachment file");
    return created;
}

- (NSManagedObject *)attachment:(NSString *)identifier inNote:(NSManagedObject *)note {
    for (NSManagedObject *attachment in [self attachmentsInNote:note]) {
        if ([attachment.objectID.URIRepresentation.absoluteString isEqualToString:identifier]) return attachment;
    }
    NBRequire(NO, @"Attachment not found in this note");
    return nil;
}

- (NSUInteger)removeMarkers:(NSManagedObject *)attachment fromDocument:(id)document {
    NSAttributedString *text = [document attributedString];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        if ([[value valueForKey:@"attachmentIdentifier"] isEqual:[attachment valueForKey:@"identifier"]]) [ranges addObject:[NSValue valueWithRange:range]];
    }];
    NBRequire(ranges.count, @"Attachment marker not found");
    for (NSValue *range in ranges.reverseObjectEnumerator) [document deleteCharactersInRange:range.rangeValue];
    return ranges.firstObject.rangeValue.location;
}

- (void)saveNote:(NSManagedObject *)note {
    [note didChangeNoteText];
    [note saveNoteData];
    [note setValue:[NSDate date] forKey:@"modificationDate"];
    [note updateDerivedAttributesIfNeeded];
}

- (void)formatDocument:(id)document options:(NSDictionary *)options {
    NSAttributedString *original = [[document attributedString] copy];
    NSString *styleName = options[@"style"];
    NSDictionary *paragraphStyles = @{@"title":@0, @"heading":@1, @"subheading":@2, @"body":@3, @"monospace":@4, @"bullet":@100, @"numbered":@102, @"checklist":@103};
    NSNumber *paragraphStyle = paragraphStyles[styleName];
    NBRequire(paragraphStyle || [@[@"bold", @"italic", @"underline", @"strikethrough"] containsObject:styleName], @"Unknown text style");
    NBRequire(!paragraphStyle || ![options[@"off"] boolValue], @"Use --style body to remove paragraph formatting");
    NBRequire(![options[@"checked"] boolValue] || [styleName isEqualToString:@"checklist"], @"--checked requires --style checklist");
    NSArray *ranges = [self rangesForText:options[@"find"] inString:original.string all:[options[@"all"] boolValue]];
    if (paragraphStyle) {
        NSMutableArray *paragraphs = [NSMutableArray array];
        for (NSValue *value in ranges) {
            NSUInteger position = value.rangeValue.location;
            while (position < NSMaxRange(value.rangeValue)) {
                NSRange paragraph = [original.string paragraphRangeForRange:NSMakeRange(position, 0)];
                NSValue *entry = [NSValue valueWithRange:paragraph];
                if (![paragraphs containsObject:entry]) [paragraphs addObject:entry];
                position = NSMaxRange(paragraph);
            }
        }
        ranges = paragraphs;
    }
    for (NSValue *value in [ranges reverseObjectEnumerator]) {
        NSRange range = value.rangeValue;
        id paragraphTodo = nil;
        if ([styleName isEqualToString:@"checklist"]) {
            id previousStyle = [original attribute:@"TTStyle" atIndex:range.location effectiveRange:nil];
            id previousTodo = [previousStyle valueForKey:@"todo"];
            paragraphTodo = [[NSClassFromString(@"ICTTTodo") alloc] init];
            [paragraphTodo setValue:[previousTodo valueForKey:@"uuid"] ?: NSUUID.UUID forKey:@"uuid"];
            [paragraphTodo setValue:options[@"checked"] ?: @NO forKey:@"done"];
        }
        NSMutableAttributedString *changed = [[original attributedSubstringFromRange:range] mutableCopy];
        NSAttributedString *attributesSource = [changed copy];
        [attributesSource enumerateAttributesInRange:NSMakeRange(0, changed.length) options:0 usingBlock:^(NSDictionary *attributes, NSRange part, BOOL *stop) {
            if (paragraphStyle) {
                id style = attributes[@"TTStyle"] ? [attributes[@"TTStyle"] mutableCopy] : [[NSClassFromString(@"ICTTParagraphStyle") alloc] init];
                [style setValue:paragraphStyle forKey:@"style"];
                [style setValue:paragraphTodo forKey:@"todo"];
                [changed addAttribute:@"TTStyle" value:style range:part];
            } else if ([styleName isEqualToString:@"bold"] || [styleName isEqualToString:@"italic"]) {
                NSUInteger flag = [styleName isEqualToString:@"bold"] ? 1 : 2;
                NSUInteger hints = [attributes[@"TTHints"] unsignedIntegerValue];
                hints = [options[@"off"] boolValue] ? hints & ~flag : hints | flag;
                [changed addAttribute:@"TTHints" value:@(hints) range:part];
            } else {
                NSString *key = [styleName isEqualToString:@"underline"] ? @"TTUnderline" : @"TTStrikethrough";
                [changed addAttribute:key value:@((BOOL)![options[@"off"] boolValue]) range:part];
            }
        }];
        [document replaceCharactersInRange:range withAttributedString:changed];
    }
}

- (void)editTableInNote:(NSManagedObject *)note operation:(NSString *)operation options:(NSDictionary *)options {
    NSManagedObject *attachment;
    if ([operation isEqualToString:@"table-new"]) {
        NBRequire([options[@"rows"] integerValue] > 0 && [options[@"columns"] integerValue] > 0, @"Table dimensions must be positive");
        attachment = [note addTableAttachment];
        id table = [[attachment tableModel] table];
        NBRequire(table != nil, @"Notes could not create the table");
        while ([table rowCount] < [options[@"rows"] unsignedIntegerValue]) [table insertRowAtIndex:[table rowCount]];
        while ([table columnCount] < [options[@"columns"] unsignedIntegerValue]) [table insertColumnAtIndex:[table columnCount]];
        while ([table rowCount] > [options[@"rows"] unsignedIntegerValue]) [table removeRowAtIndex:[table rowCount] - 1];
        while ([table columnCount] > [options[@"columns"] unsignedIntegerValue]) [table removeColumnAtIndex:[table columnCount] - 1];
        NSArray *grid = options[@"grid"];
        for (NSUInteger r = 0; r < grid.count; r++) {
            NSArray *row = grid[r];
            for (NSUInteger c = 0; c < row.count; c++) {
                [table setAttributedString:[[NSAttributedString alloc] initWithString:row[c]] columnIndex:c rowIndex:r];
            }
        }
        id document = [note mergeableString];
        [document insertAttributedString:[self marker:attachment] atIndex:[self position:options inDocument:document]];
    } else {
        NSMutableArray *tables = [NSMutableArray array];
        for (NSManagedObject *item in [self attachmentsInNote:note]) if ([[item valueForKey:@"isTable"] boolValue]) [tables addObject:item];
        NSInteger index = [options[@"table"] integerValue];
        NBRequire(index >= 1 && index <= (NSInteger)tables.count, @"Table index out of range");
        attachment = tables[index - 1];
        id table = [[attachment tableModel] table];
        NBRequire(table != nil, @"Notes could not read the table");
        NSInteger row = [options[@"row"] integerValue] - 1;
        NSInteger column = [options[@"column"] integerValue] - 1;
        if ([operation isEqualToString:@"table-set"]) {
            NBRequire(row >= 0 && row < (NSInteger)[table rowCount] && column >= 0 && column < (NSInteger)[table columnCount], @"Cell index out of range");
            [table setAttributedString:[[NSAttributedString alloc] initWithString:options[@"value"]] columnIndex:column rowIndex:row];
        } else {
            BOOL isRow = [operation hasSuffix:@"row"];
            BOOL insert = [operation hasPrefix:@"table-add"];
            NSInteger count = isRow ? [table rowCount] : [table columnCount];
            NSInteger at = options[@"at"] ? [options[@"at"] integerValue] - 1 : count;
            NBRequire(at >= 0 && at < count + (insert ? 1 : 0), @"Row or column index out of range");
            NBRequire(insert || count > 1, @"Cannot remove the last row or column");
            if (isRow && insert) [table insertRowAtIndex:at];
            else if (isRow) [table removeRowAtIndex:at];
            else if (insert) [table insertColumnAtIndex:at];
            else [table removeColumnAtIndex:at];
        }
    }
    id tableDocument = [[attachment tableModel] tableDocument];
    [[tableDocument innerTableDocument] realizeLocalChanges];
    [attachment setValue:[tableDocument serialize] forKey:@"mergeableData"];
}

- (NSDictionary *)readNote:(NSString *)identifier error:(NSError **)error {
    @try {
        NSManagedObject *note = [self note:identifier error:error];
        return note ? [self describeNote:note] : nil;
    } @catch (NSException *exception) {
        if (error) *error = NBError(exception.reason);
        return nil;
    }
}

- (NSArray<NSString *> *)noteIDsWithTag:(NSString *)tag error:(NSError **)error {
    @try {
        NSString *name = [tag hasPrefix:@"#"] ? [tag substringFromIndex:1] : tag;
        NSString *canonical = [NSClassFromString(@"ICHashtag") standardizedHashtagRepresentationForDisplayText:name];
        NSMutableArray *ids = [NSMutableArray array];
        for (NSManagedObjectID *objectID in [NSClassFromString(@"ICNote") notesContainingHashtagWithStandarizedContent:canonical context:_context]) {
            NSManagedObject *note = [_context existingObjectWithID:objectID error:error];
            if (!note) return nil;
            if (![[note valueForKey:@"isDeletedOrInTrash"] boolValue]) [ids addObject:note.objectID.URIRepresentation.absoluteString];
        }
        return ids;
    } @catch (NSException *exception) {
        if (error) *error = NBError(exception.reason);
        return nil;
    }
}

- (NSDictionary *)searchNotes:(NSString *)query options:(NSDictionary *)options error:(NSError **)error {
    NSString *readingIdentifier = nil;
    @try {
        NSString *field = options[@"field"] ?: @"all";
        NSInteger limit = options[@"limit"] ? [options[@"limit"] integerValue] : 50;
        NSInteger offset = [options[@"offset"] integerValue];
        NBRequire([query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length, @"Search query must not be empty");
        NBRequire([@[@"all", @"id", @"title", @"text", @"attachment", @"tag", @"link", @"document"] containsObject:field], @"Unknown search field");
        NBRequire(limit > 0 && offset >= 0, @"Limit must be positive and offset nonnegative");
        query = NBSearchText(query);
        NSRegularExpression *approximate = [NSRegularExpression regularExpressionWithPattern:NBSearchPattern(query) options:NSRegularExpressionCaseInsensitive error:error];
        if (!approximate) return nil;
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:NO], [NSSortDescriptor sortDescriptorWithKey:@"identifier" ascending:YES]];
        NSArray *notes = [_context executeFetchRequest:request error:error];
        if (!notes) return nil;
        NSMutableArray *matches = [NSMutableArray array];
        NSMutableArray *fuzzyMatches = [NSMutableArray array];
        NSUInteger protectedCount = 0;
        NSUInteger unavailableDocuments = 0;
        NSUInteger scannedDocuments = 0;
        NSMutableArray *documentErrors = [NSMutableArray array];
        for (NSManagedObject *note in notes) {
            if ([[note valueForKey:@"isDeletedOrInTrash"] boolValue]) continue;
            NSString *folder = [[note valueForKey:@"folder"] valueForKey:@"title"] ?: @"";
            if (options[@"folder"] && ![folder isEqualToString:options[@"folder"]] && ![[[note valueForKey:@"folder"] objectID].URIRepresentation.absoluteString isEqualToString:options[@"folder"]]) continue;
            if ([[note valueForKey:@"isPasswordProtected"] boolValue]) { protectedCount++; continue; }
            NSString *identifier = note.objectID.URIRepresentation.absoluteString;
            readingIdentifier = identifier;
            NSString *title = [note valueForKey:@"title"] ?: @"";
            NSMutableDictionary *values = [@{@"id":identifier, @"title":title} mutableCopy];
            if (![@[@"id", @"title"] containsObject:field]) {
                NSDictionary *description = [self describeNote:note];
                NSMutableArray *text = [NSMutableArray arrayWithObject:description[@"text"]];
                for (NSArray *table in description[@"tables"]) for (NSArray *row in table) [text addObjectsFromArray:row];
                values[@"text"] = [text componentsJoinedByString:@"\n"];
                for (NSString *key in @[@"attachment", @"tag", @"link"]) {
                    NSArray *items = description[[key stringByAppendingString:@"s"]];
                    values[key] = [[items valueForKey:@"name"] componentsJoinedByString:@"\n"];
                }
                if ([field isEqualToString:@"all"] || [field isEqualToString:@"document"]) {
                    NSMutableArray *documents = [NSMutableArray array];
                    for (NSManagedObject *attachment in [self attachmentsInNote:note]) {
                        if ([[attachment valueForKey:@"isTable"] boolValue]) continue;
                        NSMutableArray *indexedParts = [NSMutableArray array];
                        NSString *indexed = [attachment searchableTextContentWithoutTitle];
                        if (indexed.length) [indexedParts addObject:indexed];
                        for (NSString *key in @[@"ocrSummary", @"handwritingSummary", @"imageClassificationSummary", @"summary"]) {
                            NSString *value = [attachment valueForKey:key];
                            if ([value isKindOfClass:NSString.class] && value.length) [indexedParts addObject:value];
                        }
                        [documents addObjectsFromArray:indexedParts];
                        NSURL *file = [attachment fileURL];
                        if (!file || ![file checkResourceIsReachableAndReturnError:nil]) { unavailableDocuments++; continue; }
                        UTType *type = [UTType typeWithIdentifier:[attachment valueForKey:@"typeUTI"]];
                        if (![type conformsToType:UTTypePDF] && ![type conformsToType:UTTypeImage]) continue;
                        if ([field isEqualToString:@"all"] && [NBSearchText([indexedParts componentsJoinedByString:@"\n"]) rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
                        NSError *extractionError = nil;
                        NSString *content = NBReadDocumentText(file, &extractionError);
                        if (content) { [documents addObject:content]; scannedDocuments++; }
                        else [documentErrors addObject:@{@"note":identifier, @"attachment":attachment.objectID.URIRepresentation.absoluteString, @"error":extractionError.localizedDescription ?: @"Could not extract document text"}];
                    }
                    values[@"document"] = [documents componentsJoinedByString:@"\n"];
                }
            }
            NSMutableArray *fields = [NSMutableArray array];
            NSString *excerpt = @"";
            NSInteger bestMatch = 2;
            for (NSString *key in @[@"title", @"text", @"attachment", @"tag", @"link", @"document", @"id"]) {
                if (![field isEqualToString:@"all"] && ![field isEqualToString:key]) continue;
                NSString *value = values[key];
                if (!value) continue;
                value = NBSearchText(value);
                NSRange range = [value rangeOfString:query options:NSCaseInsensitiveSearch];
                NSInteger matchType = 0;
                if (range.location == NSNotFound && ![key isEqualToString:@"id"]) {
                    NSTextCheckingResult *match = [approximate firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
                    if (match) { range = match.range; matchType = 1; }
                }
                if (range.location == NSNotFound) continue;
                [fields addObject:key];
                if (matchType < bestMatch) {
                    bestMatch = matchType;
                    NSUInteger start = range.location > 40 ? range.location - 40 : 0;
                    NSRange preview = [value rangeOfComposedCharacterSequencesForRange:NSMakeRange(start, MIN((NSUInteger)160, value.length - start))];
                    excerpt = [value substringWithRange:preview];
                }
            }
            if (fields.count) [(bestMatch == 0 ? matches : fuzzyMatches) addObject:@{@"id":identifier, @"title":title, @"folder":folder, @"matchedFields":fields, @"excerpt":excerpt, @"matchType":bestMatch == 0 ? @"exact" : @"fuzzy"}];
        }
        [matches addObjectsFromArray:fuzzyMatches];
        NSUInteger start = MIN((NSUInteger)offset, matches.count);
        NSArray *page = [matches subarrayWithRange:NSMakeRange(start, MIN((NSUInteger)limit, matches.count - start))];
        return @{@"notes":page, @"total":@(matches.count), @"offset":@(offset), @"limit":@(limit), @"skippedProtected":@(protectedCount), @"unavailableDocuments":@(unavailableDocuments), @"scannedDocuments":@(scannedDocuments), @"documentErrors":documentErrors};
    } @catch (NSException *exception) {
        if (error) *error = NBError(readingIdentifier ? [NSString stringWithFormat:@"Could not read note %@: %@", readingIdentifier, exception.reason] : exception.reason);
        return nil;
    }
}

- (NSDictionary *)editNote:(NSString *)identifier operation:(NSString *)operation options:(NSDictionary *)options error:(NSError **)error {
    @try {
        [self requireWritable];
        NSManagedObject *note = [self note:identifier error:error];
        if (!note) return nil;
        NSDictionary *result = [self changeNote:note operation:operation options:options error:error];
        if (!result || ![self commitChanges:error]) { [_context rollback]; return nil; }
        return [self readNote:identifier error:error];
    } @catch (NSException *exception) { [_context rollback]; if (error) *error = NBError(exception.reason); return nil; }
}

- (NSDictionary *)changeNote:(NSManagedObject *)note operation:(NSString *)operation options:(NSDictionary *)options error:(NSError **)error {
    @try {
        NBRequire([@[@"pin", @"unpin", @"replace", @"insert", @"format", @"table-new", @"table-set", @"table-add-row", @"table-rm-row", @"table-add-col", @"table-rm-col", @"tag-add", @"tag-remove", @"link-add", @"link-replace", @"link-remove", @"attachment-add", @"attachment-remove", @"attachment-replace", @"attachment-move", @"attachment-view"] containsObject:operation], @"Unknown edit operation");
        [self requireWritable];
        if ([[note valueForKey:@"isSharedViaICloud"] boolValue]) {
            if (error) *error = NBError(@"Shared notes are not supported for editing");
            return nil;
        }
        NBRequire(![[note valueForKey:@"isDeletedOrInTrash"] boolValue], @"Cannot edit a deleted note");
        if ([operation isEqualToString:@"pin"] || [operation isEqualToString:@"unpin"]) {
            NBRequire([note isPinnable], @"This note cannot be pinned");
            BOOL pinned = [operation isEqualToString:@"pin"];
            if ([[note valueForKey:@"isPinned"] boolValue] != pinned) [note changePinStatusIfPossible];
            NBRequire([[note valueForKey:@"isPinned"] boolValue] == pinned, @"Notes did not change pin status");
            return [self describeNote:note];
        }
        id document = [note mergeableString];
        NSAttributedString *original = [[document attributedString] copy];
        if ([operation isEqualToString:@"replace"]) {
            NSString *replacement = options[@"replacement"];
            NBRequire(replacement && ![replacement containsString:@"\uFFFC"], @"Replacement cannot include attachment markers");
            NSArray *ranges = [self rangesForText:options[@"find"] inString:original.string all:[options[@"all"] boolValue]];
            for (NSValue *value in [ranges reverseObjectEnumerator]) [document replaceCharactersInRange:value.rangeValue withString:replacement];
        } else if ([operation isEqualToString:@"insert"]) {
            NSString *text = options[@"text"];
            NBRequire(text.length && ![text containsString:@"\uFFFC"], @"Inserted text must be nonempty and cannot include attachment markers");
            [document insertAttributedString:[[NSAttributedString alloc] initWithString:text] atIndex:[self position:options inDocument:document]];
        } else if ([operation isEqualToString:@"format"]) {
            [self formatDocument:document options:options];
        } else if ([operation hasPrefix:@"table-"]) {
            [self editTableInNote:note operation:operation options:options];
        } else if ([operation isEqualToString:@"link-add"] || [operation isEqualToString:@"link-replace"]) {
            NSManagedObject *target = [self note:options[@"target"] error:error];
            if (!target) return nil;
            NBRequire(![[target valueForKey:@"isDeletedOrInTrash"] boolValue], @"Cannot link to a deleted note");
            NSUInteger position = [self position:options inDocument:document];
            NSRange replaced = NSMakeRange(NSNotFound, 0);
            if ([operation isEqualToString:@"link-replace"]) {
                replaced = [self rangesForText:options[@"find"] inString:original.string all:NO].firstObject.rangeValue;
                position = replaced.location;
            }
            NSManagedObject *link = [NSClassFromString(@"ICInlineAttachment") newLinkAttachmentWithIdentifier:NSUUID.UUID.UUIDString toNote:target fromNote:note parentAttachment:nil];
            NBRequire(link != nil, @"Notes could not create this link");
            if (replaced.location != NSNotFound) [document deleteCharactersInRange:replaced];
            [document insertAttributedString:[self marker:link] atIndex:position];
        } else if ([operation isEqualToString:@"link-remove"]) {
            NSManagedObject *found = nil;
            for (NSManagedObject *link in [note visibleInlineAttachments]) {
                if ([[link valueForKey:@"isLinkAttachment"] boolValue] && [link.objectID.URIRepresentation.absoluteString isEqualToString:options[@"link"]]) { found = link; break; }
            }
            NBRequire(found != nil, @"Link not found in this note");
            [self removeMarkers:found fromDocument:document];
            [found updateMarkedForDeletionStateInlineAttachmentIsInUse:NO];
        } else if ([operation hasPrefix:@"tag-"]) {
            NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
            [allowed addCharactersInString:@"_-"];
            Class hashtag = NSClassFromString(@"ICHashtag");
            NSMutableCharacterSet *separators = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
            [separators addCharactersInString:@"/,"];
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            NSMutableSet<NSString *> *canonicalNames = [NSMutableSet set];
            for (NSString *part in [options[@"name"] componentsSeparatedByCharactersInSet:separators]) {
                if (!part.length) continue;
                NSString *name = [part hasPrefix:@"#"] ? [part substringFromIndex:1] : part;
                NBRequire(name.length && [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound, @"Invalid tag name");
                NSString *canonical = [hashtag standardizedHashtagRepresentationForDisplayText:name];
                if ([canonicalNames containsObject:canonical]) continue;
                [canonicalNames addObject:canonical];
                [names addObject:name];
            }
            NBRequire(names.count, @"Provide at least one tag name");
            for (NSString *name in names) {
                NSString *canonical = [hashtag standardizedHashtagRepresentationForDisplayText:name];
                NSMutableArray *matches = [NSMutableArray array];
                for (NSManagedObject *item in [note visibleInlineAttachments]) {
                    if (![[item valueForKey:@"isHashtagAttachment"] boolValue]) continue;
                    NSString *display = [item valueForKey:@"displayText"];
                    if ([display hasPrefix:@"#"]) display = [display substringFromIndex:1];
                    if ([[hashtag standardizedHashtagRepresentationForDisplayText:display] isEqualToString:canonical]) [matches addObject:item];
                }
                if ([operation isEqualToString:@"tag-add"] && !matches.count) {
                    id tag = [NSClassFromString(@"ICInlineAttachment") newHashtagAttachmentWithIdentifier:NSUUID.UUID.UUIDString hashtagText:name creatingHashtagIfNecessary:YES note:note parentAttachment:nil];
                    NBRequire(tag != nil, @"Notes could not create this tag");
                    [document insertAttributedString:[self marker:tag] atIndex:[self position:options inDocument:document]];
                } else if ([operation isEqualToString:@"tag-remove"]) {
                    for (NSManagedObject *tag in matches) {
                        [self removeMarkers:tag fromDocument:document];
                        [tag updateMarkedForDeletionStateInlineAttachmentIsInUse:NO];
                    }
                }
            }
        } else if ([operation hasPrefix:@"attachment-"]) {
            NSManagedObject *attachment = nil;
            if (![operation isEqualToString:@"attachment-add"]) attachment = [self attachment:options[@"attachment"] inNote:note];
            if ([operation isEqualToString:@"attachment-view"]) {
                NSInteger size = [options[@"size"] integerValue];
                NBRequire(size >= 0 && size <= 2, @"Attachment size must be 0, 1 or 2");
                [attachment setValue:@(size) forKey:@"preferredViewSize"];
            } else if ([operation isEqualToString:@"attachment-remove"]) {
                [self removeMarkers:attachment fromDocument:document];
                [attachment markForDeletion];
            } else if ([operation isEqualToString:@"attachment-move"]) {
                NSManagedObject *target = [self note:options[@"target"] error:error];
                if (!target) return nil;
                NBRequire(![[target valueForKey:@"isSharedViaICloud"] boolValue] && ![[target valueForKey:@"isDeletedOrInTrash"] boolValue], @"Target note cannot be shared or deleted");
                NBRequire([[note valueForKey:@"account"] isEqual:[target valueForKey:@"account"]], @"Moving attachments between accounts is not supported");
                [self removeMarkers:attachment fromDocument:document];
                [attachment setValue:target forKey:@"note"];
                id targetDocument = [target mergeableString];
                [targetDocument insertAttributedString:[self marker:attachment] atIndex:[self position:options inDocument:targetDocument]];
                [self saveNote:target];
            } else {
                NBRequire([operation isEqualToString:@"attachment-add"] || [operation isEqualToString:@"attachment-replace"], @"Unknown attachment operation");
                NSURL *file = [NSURL fileURLWithPath:options[@"file"]];
                NSUInteger position = attachment ? [self removeMarkers:attachment fromDocument:document] : [self position:options inDocument:document];
                NSManagedObject *created = [self copyAttachmentFromURL:file toNote:note error:error];
                [document insertAttributedString:[self marker:created] atIndex:position];
                if (attachment) [attachment markForDeletion];
            }
        } else {
            NBRequire(NO, @"Unknown edit operation");
        }
        [self saveNote:note];
        return [self describeNote:note];
    } @catch (NSException *exception) {
        [_context rollback];
        if (error) *error = NBError(exception.reason);
        return nil;
    }
}
@end
