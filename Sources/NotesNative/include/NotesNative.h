#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * _Nullable NBReadDocumentText(NSURL *url, NSError **error);
FOUNDATION_EXPORT NSUInteger NBCommittedCommandWrites(void);
FOUNDATION_EXPORT NSWorkspaceOpenConfiguration * _Nullable NBNotesBackgroundConfiguration(NSError **error);
FOUNDATION_EXPORT BOOL NBStartNotesSyncSignals(NSError **error);
FOUNDATION_EXPORT void NBStopNotesSyncSignals(void);
FOUNDATION_EXPORT NSInteger NBNotesSyncInterruption(void);

@interface NBNotes : NSObject
+ (nullable NSManagedObjectModel *)installedModel;
- (nullable NSDictionary *)cloudStatus:(NSError **)error;
- (BOOL)pruneEmptyActivityEvents:(NSError **)error;
- (BOOL)queueUnsyncedObjects:(NSArray<NSString *> *)identifiers error:(NSError **)error;
- (nullable instancetype)initWithURL:(NSURL *)url readOnly:(BOOL)readOnly error:(NSError **)error;
- (nullable NSDictionary *)readNote:(NSString *)identifier error:(NSError **)error;
- (nullable NSDictionary *)noteOpenDetails:(NSString *)identifier error:(NSError **)error;
- (nullable NSDictionary<NSString *, NSString *> *)publicIdentifiersForIDs:(NSArray<NSString *> *)identifiers error:(NSError **)error;
- (nullable NSString *)canonicalIDForReference:(NSString *)reference entity:(NSString *)entity error:(NSError **)error;
- (nullable NSArray<NSString *> *)backupAttachmentPaths:(NSError **)error;
- (nullable NSArray<NSString *> *)noteIDsWithTag:(NSString *)tag error:(NSError **)error;
- (nullable NSDictionary *)searchNotes:(NSString *)query options:(NSDictionary *)options error:(NSError **)error;
- (nullable NSDictionary *)editNote:(NSString *)identifier operation:(NSString *)operation options:(NSDictionary *)options error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)listFolders:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)listNotesInFolder:(NSString *)folder error:(NSError **)error;
- (nullable NSString *)createFolder:(NSString *)name parent:(nullable NSString *)parent error:(NSError **)error;
- (BOOL)removeFolder:(NSString *)folder error:(NSError **)error;
- (nullable NSString *)createNoteInFolder:(NSString *)folder html:(NSString *)html error:(NSError **)error;
- (BOOL)moveNote:(NSString *)identifier toFolder:(NSString *)folder error:(NSError **)error;
- (BOOL)deleteNote:(NSString *)identifier error:(NSError **)error;
- (nullable NSString *)htmlForNote:(NSString *)identifier error:(NSError **)error;
- (BOOL)setHTML:(NSString *)html forNote:(NSString *)identifier error:(NSError **)error;
- (nullable NSDictionary *)importNoteWithIdentifier:(NSString *)identifier folder:(NSString *)folder html:(NSString *)html tags:(NSString *)tags files:(NSArray<NSString *> *)files error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
