#import "RemindersNative.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const ABReminderEntity = @"REMCDReminder";
static NSString *const ABListEntity = @"REMCDList";
static NSString *const ABSectionEntity = @"REMCDListSection";
static NSInteger const ABUserHashtagType = 1;

static NSError *ABError(NSString *text) {
    return [NSError errorWithDomain:@"abdy.reminderkit" code:1 userInfo:@{NSLocalizedDescriptionKey: text}];
}

static id ABSend(id target, NSString *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selector));
}

static void ABSendVoid(id target, NSString *selector) {
    ((void (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selector));
}

static void ABSendVoid1(id target, NSString *selector, id argument) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(selector), argument);
}

static id ABSend1(id target, NSString *selector, id argument) {
    return ((id (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(selector), argument);
}

static id ABSend2(id target, NSString *selector, id first, id second) {
    return ((id (*)(id, SEL, id, id))objc_msgSend)(target, NSSelectorFromString(selector), first, second);
}

static id ABFetch(id target, NSString *selector, NSError **error) {
    return ((id (*)(id, SEL, NSError **))objc_msgSend)(target, NSSelectorFromString(selector), error);
}

static id ABFetch1(id target, NSString *selector, id argument, NSError **error) {
    return ((id (*)(id, SEL, id, NSError **))objc_msgSend)(target, NSSelectorFromString(selector), argument, error);
}

static NSString *ABUUID(id object) {
    return [[[object valueForKey:@"objectID"] valueForKey:@"uuid"] UUIDString];
}

static id ABObjectID(NSString *identifier, NSString *entity) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid) return nil;
    return ((id (*)(id, SEL, id, id))objc_msgSend)(NSClassFromString(@"REMObjectID"), NSSelectorFromString(@"objectIDWithUUID:entityName:"), uuid, entity);
}

@implementation ABReminderKit {
    id _store;
    id _sectionsView;
}

+ (nullable instancetype)openWithError:(NSError **)error {
    ABReminderKit *kit = [[self alloc] init];
    if (!dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW) || !NSClassFromString(@"REMStore")) {
        if (error) *error = ABError(@"ReminderKit is not available on this macOS");
        return nil;
    }
    kit->_store = [[NSClassFromString(@"REMStore") alloc] init];
    kit->_sectionsView = ABSend1([NSClassFromString(@"REMListSectionsDataView") alloc], @"initWithStore:", kit->_store);
    return kit;
}

- (instancetype)init {
    return [super init];
}

- (nullable id)reminder:(NSString *)identifier error:(NSError **)error {
    NSError *failure = nil;
    id objectID = ABObjectID(identifier, ABReminderEntity);
    id reminder = objectID ? ABFetch1(_store, @"fetchReminderWithObjectID:error:", objectID, &failure) : nil;
    if (!reminder && error) *error = ABError([NSString stringWithFormat:@"Reminder not found in Reminders: %@", identifier]);
    return reminder;
}

- (nullable id)list:(NSString *)identifier error:(NSError **)error {
    NSError *failure = nil;
    id objectID = ABObjectID(identifier, ABListEntity);
    id list = objectID ? ABFetch1(_store, @"fetchListWithObjectID:error:", objectID, &failure) : nil;
    if (!list && error) *error = ABError([NSString stringWithFormat:@"List not found in Reminders: %@", identifier]);
    return list;
}

- (nullable id)section:(NSString *)identifier error:(NSError **)error {
    NSError *failure = nil;
    id objectID = ABObjectID(identifier, ABSectionEntity);
    id section = objectID ? ABFetch1(_store, @"fetchListSectionWithObjectID:error:", objectID, &failure) : nil;
    if (!section && error) *error = ABError([NSString stringWithFormat:@"Section not found: %@", identifier]);
    return section;
}

- (id)saveRequest {
    return ABSend1([NSClassFromString(@"REMSaveRequest") alloc], @"initWithStore:", _store);
}

- (BOOL)save:(id)request action:(NSString *)action error:(NSError **)error {
    NSError *failure = nil;
    BOOL saved = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(request, NSSelectorFromString(@"saveSynchronouslyWithError:"), &failure);
    if (!saved && error) *error = ABError([NSString stringWithFormat:@"Reminders refused to %@: %@", action, failure.localizedDescription ?: @"unknown error"]);
    return saved;
}

- (NSDictionary *)describeAttachment:(id)attachment {
    NSMutableDictionary *value = [NSMutableDictionary dictionaryWithObject:ABUUID(attachment) forKey:@"id"];
    NSString *uti = [attachment valueForKey:@"uti"];
    if (uti) value[@"uti"] = uti;
    if ([attachment isKindOfClass:NSClassFromString(@"REMURLAttachment")]) {
        value[@"kind"] = @"url";
        value[@"url"] = [[attachment valueForKey:@"url"] absoluteString] ?: @"";
        return value;
    }
    value[@"kind"] = [attachment isKindOfClass:NSClassFromString(@"REMImageAttachment")] ? @"image" : @"file";
    NSURL *fileURL = [attachment valueForKey:@"fileURL"];
    if (fileURL) {
        value[@"path"] = fileURL.path;
        value[@"name"] = fileURL.lastPathComponent;
    }
    NSNumber *size = [attachment valueForKey:@"fileSize"];
    if (size.integerValue > 0) value[@"size"] = size;
    if ([value[@"kind"] isEqualToString:@"image"]) {
        value[@"width"] = @([[attachment valueForKey:@"width"] integerValue]);
        value[@"height"] = @([[attachment valueForKey:@"height"] integerValue]);
    }
    return value;
}

- (NSDictionary *)describeSection:(id)section {
    return @{@"id": ABUUID(section), @"title": [section valueForKey:@"displayName"] ?: @"", @"listID": [[[[section valueForKey:@"storage"] valueForKey:@"listID"] valueForKey:@"uuid"] UUIDString] ?: @""};
}

- (NSDictionary *)describeReminder:(id)reminder listsWithSections:(NSMutableDictionary *)listsWithSections {
    NSMutableDictionary *value = [NSMutableDictionary dictionary];
    value[@"flagged"] = @([[ABSend(reminder, @"flaggedContext") valueForKey:@"flagged"] boolValue]);
    NSMutableArray *tags = [NSMutableArray array];
    for (id hashtag in ABSend(ABSend(reminder, @"hashtagContext"), @"hashtags")) [tags addObject:[hashtag valueForKey:@"name"]];
    value[@"tags"] = [tags sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *attachments = [NSMutableArray array];
    for (id attachment in ABSend(ABSend(reminder, @"attachmentContext"), @"attachments")) [attachments addObject:[self describeAttachment:attachment]];
    value[@"attachments"] = attachments;
    id parent = [[reminder valueForKey:@"storage"] valueForKey:@"parentReminderID"];
    if (parent) value[@"parent"] = [[parent valueForKey:@"uuid"] UUIDString];
    id list = [reminder valueForKey:@"list"];
    NSString *listID = ABUUID(list);
    if (!listsWithSections[listID]) listsWithSections[listID] = @([[ABSend(list, @"sectionContext") valueForKey:@"hasSections"] boolValue]);
    if ([listsWithSections[listID] boolValue]) {
        NSError *missing = nil;
        id section = ABFetch1(_sectionsView, @"fetchListSectionWithReminderID:error:", [reminder valueForKey:@"objectID"], &missing);
        if (section) {
            value[@"sectionID"] = ABUUID(section);
            value[@"section"] = [section valueForKey:@"displayName"] ?: @"";
        }
    }
    return value;
}

- (nullable NSDictionary<NSString *, NSDictionary *> *)detailsForReminders:(nullable NSArray<NSString *> *)identifiers error:(NSError **)error {
    NSMutableArray *reminders = [NSMutableArray array];
    if (identifiers) {
        for (NSString *identifier in identifiers) {
            id reminder = [self reminder:identifier error:error];
            if (!reminder) return nil;
            [reminders addObject:reminder];
        }
    } else {
        NSError *failure = nil;
        NSArray *lists = ABFetch(_store, @"fetchListsForEventKitBridgingWithError:", &failure);
        if (!lists) {
            if (error) *error = ABError([NSString stringWithFormat:@"Reminders did not return lists: %@", failure.localizedDescription]);
            return nil;
        }
        for (id list in lists) [reminders addObjectsFromArray:ABFetch(list, @"fetchRemindersAndSubtasksWithError:", &failure) ?: @[]];
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableDictionary *listsWithSections = [NSMutableDictionary dictionary];
    for (id reminder in reminders) result[ABUUID(reminder)] = [self describeReminder:reminder listsWithSections:listsWithSections];
    return result;
}

- (BOOL)updateReminder:(NSString *)identifier options:(NSDictionary *)options error:(NSError **)error {
    id reminder = [self reminder:identifier error:error];
    if (!reminder) return NO;
    id request = [self saveRequest];
    id change = ABSend1(request, @"updateReminder:", reminder);
    NSNumber *flagged = options[@"flagged"];
    if (flagged) ((void (*)(id, SEL, BOOL))objc_msgSend)(ABSend(change, @"flaggedContext"), NSSelectorFromString(@"setFlagged:"), flagged.boolValue);
    NSArray<NSString *> *tags = options[@"tags"];
    if (tags) {
        id context = ABSend(change, @"hashtagContext");
        NSMutableSet *missing = [NSMutableSet setWithArray:tags];
        for (id hashtag in ABSend(ABSend(reminder, @"hashtagContext"), @"hashtags")) {
            NSString *name = [hashtag valueForKey:@"name"];
            if ([missing containsObject:name]) [missing removeObject:name]; else ABSendVoid1(context, @"removeHashtag:", hashtag);
        }
        for (NSString *name in tags) {
            if ([missing containsObject:name]) ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(context, NSSelectorFromString(@"addHashtagWithType:name:"), ABUserHashtagType, name);
        }
    }
    NSString *parent = options[@"parent"];
    if (parent) {
        id parentReminder = [self reminder:parent error:error];
        if (!parentReminder) return NO;
        ABSendVoid1(ABSend(ABSend1(request, @"updateReminder:", parentReminder), @"subtaskContext"), @"addReminderChangeItem:", change);
    }
    if ([options[@"clearParent"] boolValue]) ABSendVoid1(ABSend1(request, @"updateList:", [reminder valueForKey:@"list"]), @"addReminderChangeItem:", change);
    NSString *section = options[@"section"];
    if (section || [options[@"clearSection"] boolValue]) {
        NSUUID *group = nil;
        if (section) {
            id target = [self section:section error:error];
            if (!target) return NO;
            group = [[target valueForKey:@"objectID"] valueForKey:@"uuid"];
        }
        id sections = ABSend(ABSend1(request, @"updateList:", [reminder valueForKey:@"list"]), @"sectionsContextChangeItem");
        id membership = ((id (*)(id, SEL, id, id, BOOL, id))objc_msgSend)([NSClassFromString(@"REMMembership") alloc], NSSelectorFromString(@"initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:"),
                                                                        [[reminder valueForKey:@"objectID"] valueForKey:@"uuid"], group, NO, [NSDate date]);
        [sections setValue:ABSend1([NSClassFromString(@"REMMemberships") alloc], @"initWithMemberships:", @[membership]) forKey:@"unsavedMembershipsOfRemindersInSections"];
    }
    return [self save:request action:@"update the reminder" error:error];
}

- (nullable NSString *)createSubtask:(NSString *)title parent:(NSString *)parent error:(NSError **)error {
    id parentReminder = [self reminder:parent error:error];
    if (!parentReminder) return nil;
    id request = [self saveRequest];
    id subtask = ABSend2(request, @"addReminderWithTitle:toReminderSubtaskContextChangeItem:", title, ABSend(ABSend1(request, @"updateReminder:", parentReminder), @"subtaskContext"));
    if (![self save:request action:@"create the subtask" error:error]) return nil;
    return ABUUID(subtask);
}

- (nullable NSDictionary *)addAttachmentToReminder:(NSString *)identifier file:(nullable NSString *)path uti:(nullable NSString *)uti width:(NSInteger)width height:(NSInteger)height url:(nullable NSString *)url error:(NSError **)error {
    id reminder = [self reminder:identifier error:error];
    if (!reminder) return nil;
    id request = [self saveRequest];
    id context = ABSend(ABSend1(request, @"updateReminder:", reminder), @"attachmentContext");
    id attachment = nil;
    if (url) {
        NSURL *link = [NSURL URLWithString:url];
        if (!link.scheme) {
            if (error) *error = ABError([NSString stringWithFormat:@"Not a valid URL: %@", url]);
            return nil;
        }
        attachment = ABSend1(context, @"addURLAttachmentWithURL:", link);
    } else {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) {
            if (error) *error = ABError([NSString stringWithFormat:@"file not readable: %@", path]);
            return nil;
        }
        if (width > 0 && height > 0) {
            attachment = ((id (*)(id, SEL, id, id, NSUInteger, NSUInteger))objc_msgSend)(context, NSSelectorFromString(@"addImageAttachmentWithData:uti:width:height:"), data, uti, (NSUInteger)width, (NSUInteger)height);
        } else {
            attachment = ABSend2(context, @"addFileAttachmentWithData:uti:", data, uti);
        }
    }
    if (!attachment) {
        if (error) *error = ABError(@"Reminders did not create the attachment");
        return nil;
    }
    NSString *attachmentID = ABUUID(attachment);
    if (![self save:request action:@"add the attachment" error:error]) return nil;
    id saved = [self reminder:identifier error:error];
    for (id item in ABSend(ABSend(saved, @"attachmentContext"), @"attachments")) {
        if ([ABUUID(item) isEqualToString:attachmentID]) return [self describeAttachment:item];
    }
    if (error) *error = ABError(@"Reminders saved the reminder without the attachment");
    return nil;
}

- (BOOL)removeAttachment:(NSString *)attachmentID fromReminder:(NSString *)identifier error:(NSError **)error {
    id reminder = [self reminder:identifier error:error];
    if (!reminder) return NO;
    id request = [self saveRequest];
    id context = ABSend(ABSend1(request, @"updateReminder:", reminder), @"attachmentContext");
    for (id item in ABSend(ABSend(reminder, @"attachmentContext"), @"attachments")) {
        if (![ABUUID(item) isEqualToString:attachmentID]) continue;
        ABSendVoid1(context, @"removeAttachment:", item);
        return [self save:request action:@"remove the attachment" error:error];
    }
    if (error) *error = ABError([NSString stringWithFormat:@"Attachment not found in this reminder: %@", attachmentID]);
    return NO;
}

- (nullable NSArray<NSDictionary *> *)sectionsInList:(NSString *)listID error:(NSError **)error {
    id list = [self list:listID error:error];
    if (!list) return nil;
    NSError *failure = nil;
    NSArray *sections = ABFetch1(_sectionsView, @"fetchListSectionsInList:error:", list, &failure);
    if (!sections) {
        if (error) *error = ABError([NSString stringWithFormat:@"Reminders did not return sections: %@", failure.localizedDescription]);
        return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (id section in sections) [result addObject:[self describeSection:section]];
    return result;
}

- (nullable NSDictionary *)createSection:(NSString *)name inList:(NSString *)listID error:(NSError **)error {
    id list = [self list:listID error:error];
    if (!list) return nil;
    id request = [self saveRequest];
    id section = ABSend2(request, @"addListSectionWithDisplayName:toListSectionContextChangeItem:", name, ABSend(ABSend1(request, @"updateList:", list), @"sectionsContextChangeItem"));
    NSString *sectionID = ABUUID(section);
    if (![self save:request action:@"create the section" error:error]) return nil;
    id saved = [self section:sectionID error:error];
    return saved ? [self describeSection:saved] : nil;
}

- (nullable NSDictionary *)renameSection:(NSString *)sectionID to:(NSString *)name error:(NSError **)error {
    id section = [self section:sectionID error:error];
    if (!section) return nil;
    id request = [self saveRequest];
    [ABSend1(request, @"updateListSection:", section) setValue:name forKey:@"displayName"];
    if (![self save:request action:@"rename the section" error:error]) return nil;
    id saved = [self section:sectionID error:error];
    return saved ? [self describeSection:saved] : nil;
}

- (BOOL)removeSection:(NSString *)sectionID error:(NSError **)error {
    id section = [self section:sectionID error:error];
    if (!section) return NO;
    id request = [self saveRequest];
    ABSendVoid(ABSend1(request, @"updateListSection:", section), @"removeFromList");
    return [self save:request action:@"remove the section" error:error];
}

@end
