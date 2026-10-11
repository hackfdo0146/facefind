#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside @try/@catch. Returns the block's result, or nil if the
/// block threw an NSException (Swift cannot catch those natively).
/// Imported to Swift as: ObjCExceptionCatcher.safeRunBlock(_:)
@interface ObjCExceptionCatcher : NSObject
+ (nullable id)safeRunBlock:(id(^)(void))block;
@end

NS_ASSUME_NONNULL_END
