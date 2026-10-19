// ATBridge — Activator 壳 (fake libactivator for ATTweak 连点器)
// ATTweak 的 isActivatorAvailable 只查 objc_getClass("LAActivator")，
// 本壳注册同名类即可让其走 Activator 绑定路径。
// 事件源：darwin 通知 net.autotouch.atbridge.<eventname>
//   -> 通知任意外部工具用 `notifyutil -p net.autotouch.atbridge.main` 触发
// 绑定：用户在 me.autotouch.AutoTouch.ios8 域里把
//   AT.ACTIVATOR.main / AT.ACTIVATOR.sub 设为任意事件名（如 atbridge.main），
//   然后用同名的 atbridge 通知触发。
#import "Tweak.h"
#include <CoreFoundation/CoreFoundation.h>

static NSMutableDictionary *listeners;   // name -> listener
static LAActivator *shared;

@implementation LAEvent {
    NSString *_name;
    NSString *_mode;
}
- (instancetype)initWithName:(NSString *)name mode:(NSString *)mode {
    if ((self = [super init])) { _name = [name copy]; _mode = [mode copy] ?: @"shortHold"; }
    return self;
}
- (NSString *)name { return _name; }
- (NSString *)mode { return _mode; }
@end

@implementation LAActivator
+ (instancetype)sharedActivator {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}
- (void)registerListener:(id)listener forName:(NSString *)name {
    if (!listeners) listeners = [NSMutableDictionary new];
    listeners[name] = listener;
    NSLog(@"[ATBridge] registered listener: %@", name);
}
- (id)listenerForName:(NSString *)name { return listeners[name]; }
- (BOOL)isListenerRegistered:(NSString *)name { return listeners[name] != nil; }
- (id)eventWithName:(NSString *)name {
    return [[LAEvent alloc] initWithName:name mode:@"shortHold"];
}
- (void)sendEventToListener:(LAEvent *)event forListenerName:(NSString *)name {
    id l = listeners[name];
    if (!l) return;
    SEL r = NSSelectorFromString(@"activator:receiveEvent:forListenerName:");
    if ([l respondsToSelector:r]) ((void(*)(id,SEL,id,id,id))objc_msgSend)(l, r, shared, event, name);
    else {
        SEL r2 = NSSelectorFromString(@"activator:receiveEvent:");
        if ([l respondsToSelector:r2]) ((void(*)(id,SEL,id,id))objc_msgSend)(l, r2, shared, event);
    }
}
- (void)sendEventToListener:(LAEvent *)event { [self sendEventToListener:event forListenerName:nil]; }
- (NSArray *)eventNamesForListenerWithName:(NSString *)name { return @[]; }

// 安全网：吞掉 ATTweak 调的其他 Activator API，避免 unrecognized selector 崩溃
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [super methodSignatureForSelector:sel];
    if (s) return s;
    return [NSMethodSignature signatureWithObjCTypes:"@^v^c"]; // no-op 吞掉
}
- (void)forwardInvocation:(NSInvocation *)inv { /* no-op */ }
+ (BOOL)resolveInstanceMethod:(SEL)sel { return YES; }
@end

// ---------- darwin 通知桥 ----------
static void bridge_cb(CFNotificationCenterRef center, void *observer,
                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @autoreleasepool {
        NSString *n = (__bridge NSString *)name;
        if (![n hasPrefix:@"net.autotouch.atbridge."]) return;
        NSString *eventName = [n substringFromIndex:@"net.autotouch.atbridge.".length];
        if ([eventName length] == 0) return;
        LAEvent *ev = [[LAEvent alloc] initWithName:eventName mode:@"shortHold"];
        // 投递给所有已注册 listener（ATTweak 只有一个）
        for (NSString *ln in listeners) {
            [(LAActivator *)[LAActivator sharedActivator] sendEventToListener:ev forListenerName:ln];
        }
    }
}

__attribute__((constructor)) static void ATBridgeInit(void) {
    @autoreleasepool {
        listeners = [NSMutableDictionary new];
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            bridge_cb, CFSTR("net.autotouch.atbridge."), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // 确保类已注册（触发 +initialize 顺序无碍）
        [LAActivator sharedActivator];
        NSLog(@"[ATBridge] fake LAActivator ready; trigger via: notifyutil -p net.autotouch.atbridge.<eventname>");
    }
}
