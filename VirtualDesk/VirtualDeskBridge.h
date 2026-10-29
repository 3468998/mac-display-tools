#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface VirtualDeskBridge : NSObject
- (instancetype)initWithSerial:(uint32_t)serial;
- (BOOL)configureWidth:(NSUInteger)width height:(NSUInteger)height refresh:(double)refresh hiDPI:(BOOL)hiDPI error:(NSError * _Nullable * _Nullable)error;
- (BOOL)selectConfiguredMode:(NSError * _Nullable * _Nullable)error;
- (BOOL)makeMain:(NSError * _Nullable * _Nullable)error;
- (void)stop;
- (NSDictionary<NSString *, id> *)snapshot;
@end

NS_ASSUME_NONNULL_END
