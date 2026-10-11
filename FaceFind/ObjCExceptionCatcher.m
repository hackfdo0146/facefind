#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable id)safeRunBlock:(id(^)(void))block {
    @try {
        return block();
    }
    @catch (NSException *exception) {
        NSLog(@"[FaceFind] private PhotoKit call threw: %@", exception.reason ?: exception.name);
        return nil;
    }
}

@end
