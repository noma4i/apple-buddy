#import "DocumentIndex.h"
#import "NotesNative.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

static NSArray *NBFileRevision(NSURL *file) {
    struct stat attributes;
    if (stat(file.fileSystemRepresentation, &attributes) != 0) return nil;
    return @[@(attributes.st_dev), @(attributes.st_ino), @(attributes.st_size),
        @(attributes.st_mtimespec.tv_sec), @(attributes.st_mtimespec.tv_nsec),
        @(attributes.st_ctimespec.tv_sec), @(attributes.st_ctimespec.tv_nsec)];
}

static NSURL *NBIndexFile(NSURL *file, NSURL *directory) {
    NSData *path = [file.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(path.bytes, (CC_LONG)path.length, digest);
    NSMutableString *name = [NSMutableString string];
    for (NSUInteger index = 0; index < sizeof(digest); index++) [name appendFormat:@"%02x", digest[index]];
    return [directory URLByAppendingPathComponent:[name stringByAppendingString:@".json"]];
}

NSArray<NSDictionary *> *NBIndexDocuments(NSArray<NSURL *> *files, NSURL *directory) {
    if (!files.count) return @[];
    NSFileManager *disk = NSFileManager.defaultManager;
    BOOL writable = [disk createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]
        && chmod(directory.fileSystemRepresentation, 0700) == 0;
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:files.count];
    NSMutableArray *pending = [NSMutableArray array];
    for (NSUInteger index = 0; index < files.count; index++) {
        NSURL *file = files[index];
        NSArray *revision = NBFileRevision(file);
        NSURL *entryURL = NBIndexFile(file, directory);
        NSData *data = [NSData dataWithContentsOfURL:entryURL];
        NSDictionary *entry = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"revision"] isEqual:revision] &&
            ([entry[@"text"] isKindOfClass:NSString.class] || [entry[@"error"] isKindOfClass:NSString.class])) {
            NSMutableDictionary *hit = [entry mutableCopy];
            hit[@"cached"] = @YES;
            [results addObject:hit];
        } else {
            [results addObject:NSNull.null];
            [pending addObject:@{@"index":@(index), @"file":file, @"entry":entryURL, @"revision":revision ?: @[]}];
        }
    }
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = MIN(4, NSProcessInfo.processInfo.activeProcessorCount);
    NSLock *lock = [[NSLock alloc] init];
    for (NSDictionary *task in pending) {
        [queue addOperationWithBlock:^{
            @autoreleasepool {
                NSError *error = nil;
                NSString *text = nil;
                @try { text = NBReadDocumentText(task[@"file"], &error); }
                @catch (NSException *exception) {
                    error = [NSError errorWithDomain:@"apple-buddy" code:1 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Could not extract document text"}];
                }
                NSMutableDictionary *entry = [@{@"revision":task[@"revision"], @"cached":@NO} mutableCopy];
                if (![task[@"revision"] isEqual:NBFileRevision(task[@"file"])]) {
                    entry[@"error"] = @"Document changed during indexing, retry search";
                } else {
                    if (text) entry[@"text"] = text;
                    else entry[@"error"] = error.localizedDescription ?: @"Could not extract document text";
                    if (writable) {
                        NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
                        [data writeToURL:task[@"entry"] options:NSDataWritingAtomic error:nil];
                        [disk setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:[task[@"entry"] path] error:nil];
                    }
                }
                [lock lock];
                results[[task[@"index"] unsignedIntegerValue]] = entry;
                [lock unlock];
            }
        }];
    }
    [queue waitUntilAllOperationsAreFinished];
    return results;
}
