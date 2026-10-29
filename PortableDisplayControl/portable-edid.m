#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <dlfcn.h>

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*CreateAV)(CFAllocatorRef, io_service_t);
typedef IOReturn (*CopyEDID)(IOAVServiceRef, CFDataRef *);
typedef IOReturn (*SetVirtualEDID)(IOAVServiceRef, uint32_t, CFDataRef);

static BOOL validEDID(NSData *data) {
    static const uint8_t header[] = {0, 255, 255, 255, 255, 255, 255, 0};
    if (data.length < 128 || data.length % 128 || data.length > 4096) return NO;
    const uint8_t *bytes = data.bytes;
    if (memcmp(bytes, header, sizeof(header)) || data.length != (bytes[126] + 1) * 128) return NO;
    for (NSUInteger start = 0; start < data.length; start += 128) {
        unsigned sum = 0;
        for (NSUInteger i = 0; i < 128; i++) sum += bytes[start + i];
        if (sum & 255) return NO;
    }
    return YES;
}

static BOOL consoleUserHasLoggedIn(void) {
    SCDynamicStoreRef store = SCDynamicStoreCreate(
        kCFAllocatorDefault, CFSTR("PortableDisplayControlPreLogin"), NULL, NULL);
    if (!store) return NO;
    CFPropertyListRef value = SCDynamicStoreCopyValue(store, CFSTR("State:/Users/ConsoleUser"));
    CFRelease(store);
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
        if (value) CFRelease(value);
        return NO;
    }
    NSDictionary *session = CFBridgingRelease(value);
    NSNumber *uid = session[@"UID"];
    if (uid.unsignedIntValue > 500) return YES;
    NSArray *sessions = session[@"SessionInfo"];
    for (NSDictionary *entry in sessions) {
        NSNumber *sessionUID = entry[@"kCGSessionUserIDKey"];
        NSNumber *loginDone = entry[@"kCGSessionLoginDoneKey"];
        NSNumber *onConsole = entry[@"kCGSessionOnConsoleKey"];
        if (sessionUID.unsignedIntValue > 500 && loginDone.boolValue && onConsole.boolValue) {
            return YES;
        }
    }
    return NO;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: portable-edid inspect | dump FILE | apply FILE | ensure FILE ORIGINAL | boot-ensure FILE ORIGINAL | reset\n");
            return 2;
        }
        void *lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        CreateAV create = (CreateAV)dlsym(lib, "IOAVServiceCreateWithService");
        CopyEDID copy = (CopyEDID)dlsym(lib, "IOAVServiceCopyEDID");
        SetVirtualEDID set = (SetVirtualEDID)dlsym(lib, "IOAVServiceSetVirtualEDIDMode");
        if (!create || !copy || !set) {
            fprintf(stderr, "Required runtime display APIs are unavailable.\n");
            return 3;
        }
        NSString *command = @(argv[1]);
        BOOL ensure = [command isEqualToString:@"ensure"] && argc == 4;
        BOOL preloginEnsure = [command isEqualToString:@"boot-ensure"] && argc == 4;
        if (preloginEnsure && consoleUserHasLoggedIn()) {
            return 0;
        }
        io_iterator_t iterator = 0;
        IOReturn result = IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"), &iterator);
        if (result) return 4;
        IOAVServiceRef target = NULL;
        NSData *current = nil;
        io_service_t service;
        while ((service = IOIteratorNext(iterator))) {
            CFTypeRef location = IORegistryEntryCreateCFProperty(service, CFSTR("Location"),
                kCFAllocatorDefault, 0);
            BOOL external = location && CFEqual(location, CFSTR("External"));
            if (location) CFRelease(location);
            IOAVServiceRef av = external ? create(kCFAllocatorDefault, service) : NULL;
            IOObjectRelease(service);
            if (!av) continue;
            CFDataRef data = NULL;
            result = copy(av, &data);
            if (!result && data) {
                NSData *candidate = CFBridgingRelease(data);
                const uint8_t *bytes = candidate.bytes;
                if (validEDID(candidate) && bytes[8] == 0x06 && bytes[9] == 0xaf &&
                    bytes[10] == 0x94 && bytes[11] == 0xb3) {
                    if (target) {
                        CFRelease(av);
                        CFRelease(target);
                        IOObjectRelease(iterator);
                        fprintf(stderr, "More than one matching panel; refusing to modify.\n");
                        return 5;
                    }
                    target = av;
                    current = candidate;
                    continue;
                }
            } else if (data) {
                CFRelease(data);
            }
            CFRelease(av);
        }
        IOObjectRelease(iterator);
        if (!target) {
            if (ensure || preloginEnsure) return 0;
            fprintf(stderr, "The AUO 06af:b394 external panel is not available.\n");
            return 6;
        }
        if ([command isEqualToString:@"inspect"]) {
            const uint8_t *b = current.bytes;
            const uint8_t *d = b + 54;
            unsigned h = d[2] | ((d[4] & 0xf0) << 4);
            unsigned hb = d[3] | ((d[4] & 0x0f) << 8);
            unsigned v = d[5] | ((d[7] & 0xf0) << 4);
            unsigned vb = d[6] | ((d[7] & 0x0f) << 8);
            unsigned hf = d[8] | ((d[11] & 0xc0) << 2);
            unsigned hs = d[9] | ((d[11] & 0x30) << 4);
            unsigned clock = (d[0] | (d[1] << 8)) * 10000;
            printf("Panel 06af:b394, EDID %lu bytes, native %ux%u %.4f Hz\n",
                (unsigned long)current.length, h, v, (double)clock / ((h + hb) * (v + vb)));
            printf("Horizontal blank=%u front=%u sync=%u back=%d\n", hb, hf, hs, (int)hb - hf - hs);
            printf("EDID: %s\n", [[current base64EncodedStringWithOptions:0] UTF8String]);
        } else if ([command isEqualToString:@"dump"] && argc == 3) {
            NSError *error = nil;
            if (![current writeToFile:@(argv[2]) options:NSDataWritingWithoutOverwriting error:&error]) {
                fprintf(stderr, "Backup failed: %s\n", error.localizedDescription.UTF8String);
                CFRelease(target);
                return 7;
            }
            printf("Saved %lu bytes.\n", (unsigned long)current.length);
        } else if (([command isEqualToString:@"apply"] && argc == 3) || ensure || preloginEnsure) {
            NSData *replacement = [NSData dataWithContentsOfFile:@(argv[2])];
            const uint8_t *b = replacement.bytes;
            if (!validEDID(replacement) || memcmp(b + 8, (const uint8_t *)current.bytes + 8, 10)) {
                fprintf(stderr, "Replacement checksum or panel identity mismatch.\n");
                CFRelease(target);
                return 8;
            }
            if ((ensure || preloginEnsure) && [current isEqualToData:replacement]) {
                CFRelease(target);
                return 0;
            }
            if (ensure) {
                NSData *original = [NSData dataWithContentsOfFile:@(argv[3])];
                if (![current isEqualToData:original]) {
                    NSString *parent = [@(argv[2]) stringByDeletingLastPathComponent];
                    BOOL knownProfile = NO;
                    for (NSString *profile in @[@"panel-compatible-60hz.bin", @"panel-compatible-120hz.bin"]) {
                        NSData *known = [NSData dataWithContentsOfFile:[parent stringByAppendingPathComponent:profile]];
                        if (validEDID(known) && [current isEqualToData:known]) {
                            knownProfile = YES;
                            break;
                        }
                    }
                    if (knownProfile) {
                        result = set(target, 1, (__bridge CFDataRef)replacement);
                        printf("Restored selected EDID profile: 0x%08x\n", result);
                        CFRelease(target);
                        return result ? 9 : 0;
                    }
                    fprintf(stderr, "Different EDID configuration detected; leaving it unchanged.\n");
                    CFRelease(target);
                    return 0;
                }
            }
            // This runtime override never calls a hardware EEPROM write API.
            result = set(target, 1, (__bridge CFDataRef)replacement);
            printf("Temporary EDID result: 0x%08x\n", result);
        } else if ([command isEqualToString:@"reset"]) {
            result = set(target, 0, NULL);
            printf("Factory EDID restore result: 0x%08x\n", result);
        } else {
            result = 1;
        }
        CFRelease(target);
        return result ? 9 : 0;
    }
}
