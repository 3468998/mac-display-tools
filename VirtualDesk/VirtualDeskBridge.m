#import "VirtualDeskBridge.h"
#import "VirtualDeskEngine.h"

@implementation VirtualDeskBridge {
    VirtualDeskEngine *_engine;
}
- (instancetype)initWithSerial:(uint32_t)serial {
    if ((self = [super init])) _engine = [[VirtualDeskEngine alloc] initWithSerial:serial];
    return self;
}
- (BOOL)configureWidth:(NSUInteger)width height:(NSUInteger)height refresh:(double)refresh hiDPI:(BOOL)hiDPI error:(NSError **)error {
    return [_engine configureWidth:width height:height refresh:refresh hiDPI:hiDPI error:error];
}
- (BOOL)selectConfiguredMode:(NSError **)error { return [_engine selectConfiguredMode:error]; }
- (BOOL)makeMain:(NSError **)error { return [_engine makeMain:error]; }
- (void)stop { [_engine stop]; }
- (NSDictionary<NSString *, id> *)snapshot { return [_engine snapshot]; }
@end
