#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ABReminderKit : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (nullable instancetype)openWithError:(NSError **)error;
- (nullable NSDictionary<NSString *, NSDictionary *> *)detailsForReminders:(nullable NSArray<NSString *> *)identifiers error:(NSError **)error;
- (BOOL)updateReminder:(NSString *)identifier options:(NSDictionary *)options error:(NSError **)error;
- (nullable NSString *)createSubtask:(NSString *)title parent:(NSString *)parent error:(NSError **)error;
- (nullable NSDictionary *)addAttachmentToReminder:(NSString *)identifier file:(nullable NSString *)path uti:(nullable NSString *)uti width:(NSInteger)width height:(NSInteger)height url:(nullable NSString *)url error:(NSError **)error;
- (BOOL)removeAttachment:(NSString *)attachment fromReminder:(NSString *)identifier error:(NSError **)error;
- (nullable NSArray<NSDictionary *> *)sectionsInList:(NSString *)list error:(NSError **)error;
- (nullable NSDictionary *)createSection:(NSString *)name inList:(NSString *)list error:(NSError **)error;
- (nullable NSDictionary *)renameSection:(NSString *)section to:(NSString *)name error:(NSError **)error;
- (BOOL)removeSection:(NSString *)section error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
