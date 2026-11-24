#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>

extern "C" void STRegisterSwiftUICallback(NSString *(*callback)(NSString *));

// Embedded JSON section symbol fallback
extern "C" const char STBuiltinJSON[] __attribute__((section("__TEXT,__const")));

static NSDictionary<NSString *, NSString *> *STDictionary = nil;
static BOOL STEnabled = YES;
static NSString *STLanguage = @"zh-Hans";
static NSString *STOrigin = @"embedded";
static BOOL STPreloadedBeforeLC = NO;

#pragma mark - Dictionary Loading & Status Reporting

static NSString *STDocumentsSubdir(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [docs stringByAppendingPathComponent:@"SideStoreTranslator"];
}

static void STWriteStatusJSON(NSString *source, NSUInteger keyCount, BOOL externalFound) {
    NSString *dir = STDocumentsSubdir();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSDictionary *status = @{
        @"status": STEnabled ? @"active" : @"disabled",
        @"language": STLanguage ?: @"zh-Hans",
        @"source": source ?: @"embedded",
        @"translationCount": @(keyCount),
        @"externalJSONFound": @(externalFound),
        @"preloadedBeforeLC": @(STPreloadedBeforeLC),
        @"checkedAt": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        [data writeToFile:[dir stringByAppendingPathComponent:@"status.json"] atomically:YES];
    }
}

static NSDictionary<NSString *, NSString *> *STParseJSONData(NSData *data, BOOL *outEnabled, NSString **outLang) {
    if (!data || data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *root = (NSDictionary *)obj;
    if ([root[@"enabled"] respondsToSelector:@selector(boolValue)]) {
        if (outEnabled) *outEnabled = [root[@"enabled"] boolValue];
    }
    if ([root[@"language"] isKindOfClass:[NSString class]]) {
        if (outLang) *outLang = root[@"language"];
    }
    NSDictionary *translations = root[@"translations"];
    if ([translations isKindOfClass:[NSDictionary class]] && translations.count > 0) {
        return translations;
    }
    return nil;
}

static NSData *STLoadEmbeddedJSONData(void) {
    Dl_info info;
    if (dladdr((const void *)&STLoadEmbeddedJSONData, &info) && info.dli_fbase) {
        unsigned long size = 0;
        const uint8_t *ptr = getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__TEXT", "__st_json", &size);
        if (ptr && size > 0) {
            return [NSData dataWithBytesNoCopy:(void *)ptr length:size freeWhenDone:NO];
        }
    }
    return nil;
}

static void STInitializeDictionary(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *dir = STDocumentsSubdir();
        NSString *externalPath = [dir stringByAppendingPathComponent:@"zh-Hans.json"];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL externalFound = [fm fileExistsAtPath:externalPath];

        NSDictionary<NSString *, NSString *> *dict = nil;
        if (externalFound) {
            NSData *extData = [NSData dataWithContentsOfFile:externalPath];
            dict = STParseJSONData(extData, &STEnabled, &STLanguage);
            if (dict) {
                STOrigin = @"external";
            } else {
                NSLog(@"[SideStoreTranslator] Invalid external JSON; using bundled translations.");
            }
        }

        if (!dict) {
            NSData *embeddedData = STLoadEmbeddedJSONData();
            dict = STParseJSONData(embeddedData, &STEnabled, &STLanguage);
            STOrigin = @"embedded";
        }

        if (!dict) {
            NSLog(@"[SideStoreTranslator] No valid translation dictionary.");
            dict = @{};
        }

        STDictionary = dict;
        NSLog(@"[SideStoreTranslator] %@ lang=%@ keys=%lu enabled=%d",
              STOrigin, STLanguage, (unsigned long)STDictionary.count, STEnabled);
        STWriteStatusJSON(STOrigin, STDictionary.count, externalFound);
    });
}

#pragma mark - Translation Lookup

static NSString *STTranslate(NSString *input) {
    if (!STEnabled || !input || input.length == 0) return input;
    STInitializeDictionary();
    NSString *hit = STDictionary[input];
    if (hit && hit.length > 0) {
        return hit;
    }
    // Trim whitespace/newline fallback check
    NSString *trimmed = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 0 && ![trimmed isEqualToString:input]) {
        NSString *trimmedHit = STDictionary[trimmed];
        if (trimmedHit && trimmedHit.length > 0) {
            return [input stringByReplacingOccurrencesOfString:trimmed withString:trimmedHit];
        }
    }
    return input;
}

static NSString *STSwiftUIBridgeCallback(NSString *key) {
    return STTranslate(key);
}

#pragma mark - Bundle Filter

static BOOL STBundleIsAllowed(NSBundle *bundle) {
    if (!bundle) return YES;
    NSString *bid = bundle.bundleIdentifier;
    if (!bid) return YES;
    if ([bid hasPrefix:@"com.SideStore"] || [bid containsString:@"SideStore"]) {
        return YES;
    }
    if ([bundle.bundlePath containsString:@"SideStore"]) {
        return YES;
    }
    return NO;
}

#pragma mark - Method Swizzling Helpers

static IMP STOriginalLocalized = NULL;
static IMP STOriginalLabelSetText = NULL;
static IMP STOriginalButtonSetTitle = NULL;
static IMP STOriginalBarItemSetTitle = NULL;
static IMP STOriginalNavItemSetTitle = NULL;
static IMP STOriginalSegmentSetTitle = NULL;
static IMP STOriginalViewWillAppear = NULL;
static IMP STOriginalClassicLaunch = NULL;

static NSString *STHookLocalized(id self, SEL _cmd, NSString *key, NSString *value, NSString *tableName) {
    NSString *orig = ((NSString *(*)(id, SEL, NSString *, NSString *, NSString *))STOriginalLocalized)(self, _cmd, key, value, tableName);
    if (!STEnabled || !STBundleIsAllowed(self)) {
        return orig;
    }
    if (orig && orig.length > 0) {
        NSString *t = STTranslate(orig);
        if (![t isEqualToString:orig]) return t;
    }
    if (key && key.length > 0) {
        NSString *t = STTranslate(key);
        if (![t isEqualToString:key]) return t;
    }
    return orig;
}

static void STHookLabelSetText(UILabel *self, SEL _cmd, NSString *text) {
    NSString *translated = STTranslate(text);
    ((void (*)(id, SEL, NSString *))STOriginalLabelSetText)(self, _cmd, translated);
}

static void STHookButtonSetTitle(UIButton *self, SEL _cmd, NSString *title, UIControlState state) {
    NSString *translated = STTranslate(title);
    ((void (*)(id, SEL, NSString *, UIControlState))STOriginalButtonSetTitle)(self, _cmd, translated, state);
}

static void STHookBarItemSetTitle(UIBarButtonItem *self, SEL _cmd, NSString *title) {
    NSString *translated = STTranslate(title);
    ((void (*)(id, SEL, NSString *))STOriginalBarItemSetTitle)(self, _cmd, translated);
}

static void STHookNavItemSetTitle(UINavigationItem *self, SEL _cmd, NSString *title) {
    NSString *translated = STTranslate(title);
    ((void (*)(id, SEL, NSString *))STOriginalNavItemSetTitle)(self, _cmd, translated);
}

static void STHookSegmentSetTitle(UISegmentedControl *self, SEL _cmd, NSString *title, NSUInteger segment) {
    NSString *translated = STTranslate(title);
    ((void (*)(id, SEL, NSString *, NSUInteger))STOriginalSegmentSetTitle)(self, _cmd, translated, segment);
}

static void STLocalizeViewTree(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        if (lbl.text.length > 0) {
            NSString *t = STTranslate(lbl.text);
            if (![t isEqualToString:lbl.text]) lbl.text = t;
        }
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *cur = [btn titleForState:UIControlStateNormal];
        if (cur.length > 0) {
            NSString *t = STTranslate(cur);
            if (![t isEqualToString:cur]) [btn setTitle:t forState:UIControlStateNormal];
        }
    }
    for (UIView *sub in view.subviews) {
        STLocalizeViewTree(sub);
    }
}

static void STHookViewWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))STOriginalViewWillAppear)(self, _cmd, animated);
    if (STEnabled && self.isViewLoaded) {
        if (self.navigationItem.title.length > 0) {
            self.navigationItem.title = STTranslate(self.navigationItem.title);
        }
        if (self.tabBarItem.title.length > 0) {
            self.tabBarItem.title = STTranslate(self.tabBarItem.title);
        }
        STLocalizeViewTree(self.view);
    }
}

static void STReplaceMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *outOriginal = method_setImplementation(m, replacement);
}

#pragma mark - LiveContainer Classic Mode Preload Support

static void STEnsurePreloadInLiveContainer(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libDir = paths.firstObject;
    if (!libDir) return;
    NSString *preloadFile = [libDir stringByAppendingPathComponent:@"preloadLibraries.txt"];
    NSString *entry = @"SideStoreTranslator.dylib";
    NSString *existing = [NSString stringWithContentsOfFile:preloadFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
    if (![existing containsString:entry]) {
        NSMutableString *updated = [existing mutableCopy];
        if (updated.length > 0 && ![updated hasSuffix:@"\n"]) {
            [updated appendString:@"\n"];
        }
        [updated appendFormat:@"%@\n", entry];
        [updated writeToFile:preloadFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        STPreloadedBeforeLC = YES;
        NSLog(@"[SideStoreTranslator] Built-in SideStore preload queued=1");
    }
}

static void STHookClassicLaunch(id self, SEL _cmd, id guestAppInfo) {
    STEnsurePreloadInLiveContainer();
    if (STOriginalClassicLaunch) {
        ((void (*)(id, SEL, id))STOriginalClassicLaunch)(self, _cmd, guestAppInfo);
    }
}

#pragma mark - Constructor

__attribute__((constructor))
static void STBootstrap(void) {
    STInitializeDictionary();
    STRegisterSwiftUICallback(&STSwiftUIBridgeCallback);

    STReplaceMethod([NSBundle class],
                    @selector(localizedStringForKey:value:table:),
                    (IMP)&STHookLocalized,
                    &STOriginalLocalized);

    STReplaceMethod([UILabel class],
                    @selector(setText:),
                    (IMP)&STHookLabelSetText,
                    &STOriginalLabelSetText);

    STReplaceMethod([UIButton class],
                    @selector(setTitle:forState:),
                    (IMP)&STHookButtonSetTitle,
                    &STOriginalButtonSetTitle);

    STReplaceMethod([UIBarButtonItem class],
                    @selector(setTitle:),
                    (IMP)&STHookBarItemSetTitle,
                    &STOriginalBarItemSetTitle);

    STReplaceMethod([UINavigationItem class],
                    @selector(setTitle:),
                    (IMP)&STHookNavItemSetTitle,
                    &STOriginalNavItemSetTitle);

    STReplaceMethod([UISegmentedControl class],
                    @selector(setTitle:forSegmentAtIndex:),
                    (IMP)&STHookSegmentSetTitle,
                    &STOriginalSegmentSetTitle);

    STReplaceMethod([UIViewController class],
                    @selector(viewWillAppear:),
                    (IMP)&STHookViewWillAppear,
                    &STOriginalViewWillAppear);

    Class lcUtils = NSClassFromString(@"LCSharedUtils");
    if (lcUtils) {
        STReplaceMethod(lcUtils,
                        NSSelectorFromString(@"launchToGuestAppWithClassicMode:"),
                        (IMP)&STHookClassicLaunch,
                        &STOriginalClassicLaunch);
        NSLog(@"[SideStoreTranslator] LC classic launch hook ready.");
    }

    NSLog(@"[SideStoreTranslator] Hooks armed; earlyPreload=%d", STPreloadedBeforeLC);
}
