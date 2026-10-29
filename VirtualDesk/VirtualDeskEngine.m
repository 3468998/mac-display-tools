#import "VirtualDeskEngine.h"
#import "VirtualDisplayPrivate.h"
#include <math.h>

static NSString * const VDErrorDomain = @"local.virtualdesk";
static const uint32_t VDVendor = 0x56d0;
static const uint32_t VDProduct = 0x0001;

static BOOL Fail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:VDErrorDomain code:code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

@interface VDDisplayBaseline : NSObject
@property uint32_t identifier;
@property CGRect bounds;
@property(strong) id mode;
@end
@implementation VDDisplayBaseline
@end

@interface VirtualDeskEngine ()
@property(strong) CGVirtualDisplay *display;
@property(strong) CGVirtualDisplaySettings *settings;
@property uint32_t serial;
@property NSUInteger width;
@property NSUInteger height;
@property double refresh;
@property BOOL hiDPI;
@property BOOL needsPlacement;
@property(strong) NSArray<VDDisplayBaseline *> *baseline;
@end

@implementation VirtualDeskEngine
+ (BOOL)supported {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor") &&
           NSClassFromString(@"CGVirtualDisplaySettings") && NSClassFromString(@"CGVirtualDisplayMode");
}

- (instancetype)initWithSerial:(uint32_t)serial {
    if ((self = [super init])) _serial = serial ?: 1;
    return self;
}

- (uint32_t)displayID { return self.display ? self.display.displayID : 0; }
- (BOOL)running { return self.display && CGDisplayIsOnline(self.displayID) == 1; }

- (BOOL)configureWidth:(NSUInteger)width height:(NSUInteger)height
               refresh:(double)refresh hiDPI:(BOOL)hiDPI error:(NSError **)error {
    if (![VirtualDeskEngine supported]) return Fail(error, 1, @"此 macOS 不提供可用的虚拟显示接口。");
    const NSUInteger scale = hiDPI ? 2 : 1;
    if (width < 800 || height < 600 || width > 7680 / scale || height > 4320 / scale ||
        !isfinite(refresh) || refresh < 24 || refresh > 240) {
        return Fail(error, 2, @"所选分辨率或刷新率超出支持范围。");
    }
    BOOL created = NO;
    if (!self.display) {
        CGDirectDisplayID ids[32]; uint32_t count = 0;
        CGGetOnlineDisplayList(32, ids, &count);
        NSMutableArray *baseline = [NSMutableArray array];
        for (uint32_t i = 0; i < count; i++) {
            VDDisplayBaseline *item = [VDDisplayBaseline new];
            item.identifier = ids[i];
            item.bounds = CGDisplayBounds(ids[i]);
            item.mode = CFBridgingRelease(CGDisplayCopyDisplayMode(ids[i]));
            [baseline addObject:item];
        }
        self.baseline = baseline;
        CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
        descriptor.name = @"Virtual Desk";
        descriptor.vendorID = VDVendor;
        descriptor.productID = VDProduct;
        descriptor.serialNum = self.serial;
        if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) descriptor.serialNumber = self.serial;
        descriptor.maxPixelsWide = 7680;
        descriptor.maxPixelsHigh = 4320;
        descriptor.sizeInMillimeters = CGSizeMake(600, 337.5);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        descriptor.redPrimary = CGPointMake(0.64, 0.33);
        descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        descriptor.queue = dispatch_get_main_queue();
        self.display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!self.display) return Fail(error, 3, @"macOS 拒绝创建虚拟屏幕，当前显示设置未修改。");
        created = YES;
    }
    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)width
                                                                         height:(unsigned int)height
                                                                    refreshRate:refresh]];
    if (![self.display applySettings:settings]) {
        if (created) self.display = nil;
        return Fail(error, 4, @"macOS 未接受虚拟屏模式。请尝试 4K 60Hz 或关闭 HiDPI。");
    }
    self.settings = settings;
    self.width = width;
    self.height = height;
    self.refresh = refresh;
    self.hiDPI = hiDPI;
    self.needsPlacement = created;
    return YES;
}

- (BOOL)selectConfiguredMode:(NSError **)error {
    if (!self.display) return Fail(error, 5, @"虚拟屏幕尚未创建。");
    if (!self.running) return Fail(error, 6, @"虚拟屏幕还未上线。");
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(self.displayID, (__bridge CFDictionaryRef)options));
    CGDisplayModeRef selected = NULL;
    const NSUInteger scale = self.hiDPI ? 2 : 1;
    for (id object in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)object;
        if (CGDisplayModeGetWidth(mode) == self.width && CGDisplayModeGetHeight(mode) == self.height &&
            CGDisplayModeGetPixelWidth(mode) == self.width * scale &&
            CGDisplayModeGetPixelHeight(mode) == self.height * scale &&
            fabs(CGDisplayModeGetRefreshRate(mode) - self.refresh) < 0.2) {
            selected = mode;
            break;
        }
    }
    if (!selected) return Fail(error, 7, @"系统没有提供与所选 HiDPI / 刷新率对应的虚拟屏模式。");

    CGDisplayConfigRef config = NULL;
    CGError result = CGBeginDisplayConfiguration(&config);
    if (result != kCGErrorSuccess) return Fail(error, result, @"无法开始虚拟屏配置。");
    // macOS can initially attach a virtual display as the source of a mirror set.
    result = CGConfigureDisplayMirrorOfDisplay(config, self.displayID, kCGNullDirectDisplay);
    for (VDDisplayBaseline *item in self.baseline) {
        if (result != kCGErrorSuccess) break;
        if (CGDisplayIsOnline(item.identifier) != 1) continue;
        if (CGDisplayMirrorsDisplay(item.identifier) == self.displayID) {
            result = CGConfigureDisplayMirrorOfDisplay(config, item.identifier, kCGNullDirectDisplay);
            if (result == kCGErrorSuccess && item.mode) {
                result = CGConfigureDisplayWithDisplayMode(config, item.identifier,
                    (__bridge CGDisplayModeRef)item.mode, NULL);
            }
        }
        if (result == kCGErrorSuccess && self.needsPlacement) {
            result = CGConfigureDisplayOrigin(config, item.identifier,
                (int32_t)item.bounds.origin.x, (int32_t)item.bounds.origin.y);
        }
    }
    if (result == kCGErrorSuccess) result = CGConfigureDisplayWithDisplayMode(config, self.displayID, selected, NULL);
    if (result == kCGErrorSuccess && self.needsPlacement) {
        // Place only our display, keeping the existing main display at the origin.
        CGDirectDisplayID ids[32]; uint32_t count = 0;
        CGGetOnlineDisplayList(32, ids, &count);
        CGFloat rightEdge = 0;
        BOOL otherDisplay = NO;
        for (uint32_t i = 0; i < count; i++) {
            if (ids[i] == self.displayID) continue;
            CGRect bounds = CGDisplayBounds(ids[i]);
            for (VDDisplayBaseline *item in self.baseline) {
                if (item.identifier == ids[i]) { bounds = item.bounds; break; }
            }
            rightEdge = MAX(rightEdge, CGRectGetMaxX(bounds));
            otherDisplay = YES;
        }
        if (otherDisplay) {
            result = CGConfigureDisplayOrigin(config, self.displayID, (int32_t)rightEdge, 0);
        }
    }
    if (result == kCGErrorSuccess) result = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    else CGCancelDisplayConfiguration(config);
    if (result != kCGErrorSuccess) return Fail(error, result, @"无法应用虚拟屏配置。");
    self.needsPlacement = NO;
    return YES;
}

- (BOOL)makeMain:(NSError **)error {
    if (!self.running) return Fail(error, 8, @"请先启动虚拟显示器。");
    CGRect targetBounds = CGDisplayBounds(self.displayID);
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    CGError result = CGGetOnlineDisplayList(32, ids, &count);
    if (result != kCGErrorSuccess) return Fail(error, result, @"无法读取显示器布局。");
    CGDisplayConfigRef config = NULL;
    result = CGBeginDisplayConfiguration(&config);
    if (result == kCGErrorSuccess) {
        // Translate the whole desktop to preserve the relative display arrangement.
        for (uint32_t i = 0; i < count && result == kCGErrorSuccess; i++) {
            if (CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay) continue;
            CGRect bounds = CGDisplayBounds(ids[i]);
            result = CGConfigureDisplayOrigin(config, ids[i],
                (int32_t)(bounds.origin.x - targetBounds.origin.x),
                (int32_t)(bounds.origin.y - targetBounds.origin.y));
        }
        if (result == kCGErrorSuccess) result = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        else CGCancelDisplayConfiguration(config);
    }
    return result == kCGErrorSuccess || Fail(error, result, @"无法将虚拟屏设置为主显示器。");
}

- (void)stop {
    self.display = nil;
    self.settings = nil;
    self.needsPlacement = NO;
}

- (NSDictionary<NSString *,id> *)snapshot {
    uint32_t identifier = self.displayID;
    NSMutableDictionary *result = [@{
        @"displayID": @(identifier), @"online": @(self.running),
        @"active": @(identifier && CGDisplayIsActive(identifier) == 1),
        @"main": @(identifier && CGDisplayIsMain(identifier) == 1),
        @"vendor": @(identifier ? CGDisplayVendorNumber(identifier) : 0),
        @"product": @(identifier ? CGDisplayModelNumber(identifier) : 0),
        @"serial": @(self.serial)
    } mutableCopy];
    CGDisplayModeRef mode = identifier ? CGDisplayCopyDisplayMode(identifier) : NULL;
    if (mode) {
        result[@"width"] = @(CGDisplayModeGetWidth(mode));
        result[@"height"] = @(CGDisplayModeGetHeight(mode));
        result[@"pixelWidth"] = @(CGDisplayModeGetPixelWidth(mode));
        result[@"pixelHeight"] = @(CGDisplayModeGetPixelHeight(mode));
        result[@"refreshRate"] = @(CGDisplayModeGetRefreshRate(mode));
        CGDisplayModeRelease(mode);
    }
    return result;
}
@end
