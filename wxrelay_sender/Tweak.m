/**
 * WXRelay v0.2.0 — 发送器可测版
 *
 * 已验证（v0.1 探针, 微信 8.0.78）:
 *   CMessageMgr EXIST + AddMsg:MsgWrap: instance YES
 *   CMessageWrap initWithMsgType: / m_nsContent / m_nsToUsr / m_nsFromUsr YES
 *   MMServiceCenter defaultCenter YES（getClass: 是实例方法）
 *
 * 本版：
 *   1. 启动后探测自身 wxid（CAccountMgr.m_nsUsrName 候选）
 *   2. 读配置 com.mos.wxrelay（CFPreferences）：testTarget = 目标 id
 *   3. 启动 15s 后发测试消息 "WXRelay 自测 <时间>" → 验证静默发送链路
 *   4. CPDistributedMessaging 监听器就绪（捕获器后续接入）
 * 日志：微信沙盒 tmp/wxrelay.log
 */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

#define WR_CENTER_NAME   @"com.mos.wxrelay"
#define WR_TEST_DELAY    20.0
#pragma clang assume_nonnull begin
#pragma clang assume_nonnull end

static void wrLog(NSString *msg) {
    @try {
        static NSDateFormatter *f = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss"; });
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], msg];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        NSLog(@"[WXRelay] %@", line);
    } @catch (NSException *e) { }
}

static id WRElvis(id obj) { return obj ?: [NSNull null]; }

/* ---------- 收信捕获：hook CMessageMgr AddMsg:MsgWrap:（进站消息全文） ---------- */
static void (*orig_AddMsg)(id, SEL, id, id);
static NSMutableDictionary *wrCatchRules; // matchText -> [targets]
static NSString *wrSelfId = nil;

static void WRLoadCatchRules(void) {
    wrCatchRules = [NSMutableDictionary new];
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay.cfg"];
    NSString *content = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![l hasPrefix:@"catch="]) continue;
        NSString *rule = [l substringFromIndex:6]; // 匹配文本#目标id1#目标id2
        NSArray *parts = [rule componentsSeparatedByString:@"#"];
        if (parts.count < 2) continue;
        NSString *match = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!match.length) continue;
        NSMutableArray *ts = [NSMutableArray new];
        for (NSUInteger i = 1; i < parts.count; i++) {
            NSString *t = [parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length) [ts addObject:t];
        }
        if (ts.count) wrCatchRules[match] = ts;
    }
    wrLog([NSString stringWithFormat:@"catch rules loaded: %@", wrCatchRules]);
}

static BOOL wrIsIncoming(id wrap) {
    @try {
        if (!wrSelfId) {
            // 懒解析自身 wxid（CContactMgr.getSelfContact）
            Class svc = NSClassFromString(@"MMServiceCenter");
            id center = ((id(*)(id,SEL))objc_msgSend)(svc, NSSelectorFromString(@"defaultCenter"));
            Class cmCls = NSClassFromString(@"CContactMgr");
            id cm = ((id(*)(id,SEL,Class))objc_msgSend)(center, NSSelectorFromString(@"getService:"), cmCls);
            SEL gsc = NSSelectorFromString(@"getSelfContact");
            if (cm && [cm respondsToSelector:gsc]) {
                id contact = ((id(*)(id,SEL))objc_msgSend)(cm, gsc);
                if (contact && [contact respondsToSelector:NSSelectorFromString(@"m_nsUsrName")]) {
                    wrSelfId = ((id(*)(id,SEL))objc_msgSend)(contact, NSSelectorFromString(@"m_nsUsrName"));
                    wrLog([NSString stringWithFormat:@"selfId resolved: %@", wrSelfId]);
                }
            }
        }
        if (!wrSelfId) return NO;
        NSString *to = [wrap respondsToSelector:NSSelectorFromString(@"m_nsToUsr")] ?
            ((id(*)(id,SEL))objc_msgSend)(wrap, NSSelectorFromString(@"m_nsToUsr")) : nil;
        NSString *from = [wrap respondsToSelector:NSSelectorFromString(@"m_nsFromUsr")] ?
            ((id(*)(id,SEL))objc_msgSend)(wrap, NSSelectorFromString(@"m_nsFromUsr")) : nil;
        return [to isEqualToString:wrSelfId] && ![from isEqualToString:wrSelfId];
    } @catch (NSException *e) { return NO; }
}

static void hooked_AddMsg(id self, SEL _cmd, id arg1, id wrap) {
    orig_AddMsg(self, _cmd, arg1, wrap);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            @try {
                if (![wrap isKindOfClass:[NSString class]] && !wrap) return;
                if (!wrIsIncoming(wrap)) return;
                NSString *content = [wrap respondsToSelector:NSSelectorFromString(@"m_nsContent")] ?
                    ((id(*)(id,SEL))objc_msgSend)(wrap, NSSelectorFromString(@"m_nsContent")) : nil;
                NSString *from = ((id(*)(id,SEL))objc_msgSend)(wrap, NSSelectorFromString(@"m_nsFromUsr"));
                if (![content isKindOfClass:[NSString class]] || !content.length) return;
                if (!wrCatchRules.count) return;
                wrLog([NSString stringWithFormat:@"incoming from %@ len=%lu", from, (unsigned long)content.length]);
                for (NSString *match in wrCatchRules) {
                    if (![content containsString:match]) continue;
                    NSArray *targets = wrCatchRules[match];
                    wrLog([NSString stringWithFormat:@"catch [%@] -> %@", match, targets]);
                    for (NSString *t in targets) WRSendMessage(t, content); // 全文转发
                }
            } @catch (NSException *e) {
                wrLog([NSString stringWithFormat:@"AddMsg hook EXC: %@", e.name]);
            }
        }
    });
}

/* ---------- 保活：静默音频防冻结 ---------- */
static void self_setupKeepAlive(void) {
    @try {
        NSString *wav = [NSTemporaryDirectory() stringByAppendingPathComponent:@"silence.wav"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:wav]) {
            int sampleRate = 8000, seconds = 2;
            int dataLen = sampleRate * seconds * 2;
            struct __attribute__((packed)) WH { char r[4]; uint32_t sz; char w[4]; char f[4]; uint32_t fs; uint16_t af; uint16_t ch; uint32_t sr; uint32_t br; uint16_t ba; uint16_t bps; char dd[4]; uint32_t ds; } wh;
            memcpy(wh.r,"RIFF",4); wh.sz=36+dataLen; memcpy(wh.w,"WAVE",4); memcpy(wh.f,"fmt ",4);
            wh.fs=16; wh.af=1; wh.ch=1; wh.sr=sampleRate; wh.br=sampleRate*2; wh.ba=2; wh.bps=16;
            memcpy(wh.dd,"data",4); wh.ds=dataLen;
            NSMutableData *out = [NSMutableData dataWithBytes:&wh length:44];
            [out increaseLengthBy:dataLen];
            [out writeToFile:wav atomically:YES];
        }
        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err];
        [session setActive:YES error:&err];
        id player = [[NSClassFromString(@"AVAudioPlayer") alloc] initWithContentsOfURL:[NSURL fileURLWithPath:wav] error:&err];
        if (!player) { wrLog([NSString stringWithFormat:@"keepalive player fail: %@", err]); return; }
        ((void(*)(id,SEL,long))objc_msgSend)(player, NSSelectorFromString(@"setNumberOfLoops:"), -1);
        ((void(*)(id,SEL,float))objc_msgSend)(player, NSSelectorFromString(@"setVolume:"), 1.0f);
        ((BOOL(*)(id,SEL))objc_msgSend)(player, NSSelectorFromString(@"play"));
        id app = [UIApplication sharedApplication];
        if (app) objc_setAssociatedObject(app, @selector(keyWindow), player, OBJC_ASSOCIATION_RETAIN);
        wrLog(@"keepalive: silent audio looping");
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"keepalive EXC: %@", e.name]);
    }
}

/* ---------- 发送核心：进程内直调 handleOpenURL（懒猫接管） ---------- */
static BOOL WRSendMessage(NSString *targetId, NSString *text) {
    @try {
        id delegate = [UIApplication sharedApplication].delegate;
        if (!delegate) { wrLog(@"send: app delegate nil"); return NO; }
        SEL h = NSSelectorFromString(@"application:handleOpenURL:bundleID:annotation:");
        if (![delegate respondsToSelector:h]) { wrLog(@"send: handleOpenURL not responding"); return NO; }

        NSString *escaped = [text stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *urlStr = [NSString stringWithFormat:@"weixin://aiwmao/user=%@&msg=%@", targetId, escaped];
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) { wrLog([NSString stringWithFormat:@"send: bad url %@", urlStr]); return NO; }

        wrLog([NSString stringWithFormat:@"send: invoking handleOpenURL (text len=%lu) full-text=%@", (unsigned long)text.length, text]);
        ((BOOL(*)(id,SEL,id,id,id,id))objc_msgSend)(delegate, h, nil, url, nil, nil);
        wrLog(@"send: handleOpenURL invoked (LazyCat hook expected to fire)");
        return YES;
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"send EXC: %@ %@", e.name, e.reason]);
        return NO;
    }
}

/* ---------- 自身 wxid 探测 ---------- */
static NSString *WRDetectSelfWxid(void) {
    @try {
        Class svc = NSClassFromString(@"MMServiceCenter");
        id center = ((id(*)(id,SEL))objc_msgSend)(svc, NSSelectorFromString(@"defaultCenter"));
        for (NSString *clsName in @[@"CAccountMgr", @"CAppAccountMgr", @"WCSession"]) {
            Class c = NSClassFromString(clsName);
            if (!c) continue;
            SEL gcS = NSSelectorFromString(@"getClass:");
            if (![center respondsToSelector:gcS]) { wrLog(@"selfwxid: center no getClass:"); continue; }
            id obj = ((id(*)(id,SEL,Class))objc_msgSend)(center, gcS, c);
            if (!obj) continue;
            for (NSString *prop in @[@"m_nsUsrName", @"userName", @"GetUserName"]) {
                SEL s = NSSelectorFromString(prop);
                if ([obj respondsToSelector:s]) {
                    id v = ((id(*)(id,SEL))objc_msgSend)(obj, s);
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                        wrLog([NSString stringWithFormat:@"self wxid via %@.%@ = %@", clsName, prop, v]);
                        return v;
                    }
                }
            }
            wrLog([NSString stringWithFormat:@"self wxid: %@ no usable prop", clsName]);
        }
    } @catch (NSException *e) {
        wrLog([NSString stringWithFormat:@"selfwxid EXC: %@", e.name]);
    }
    return nil;
}

/* ---------- 配置读取 ---------- */
static NSString *WRTmpPath(NSString *fn) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:fn];
}

/* 配置：与 wxrelay.log 同目录的纯文本 wxrelay.cfg，行格式 key=value */
static NSString *WRConfig(NSString *key) {
    NSString *p = WRTmpPath(@"wxrelay.cfg");
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSString *tpl = @"# WXRelay 配置（纯文本，改完重启微信）\n"
            @"# testTarget=自测发送目标 id（例：filehelper 或 wxid_xxx 或 群id@chatroom）\n"
            @"testTarget=\n";
        [tpl writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        wrLog([NSString stringWithFormat:@"config template created: %@", p]);
    }
    NSString *content = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (l.length == 0 || [l hasPrefix:@"#"]) continue;
        NSRange eq = [l rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[l substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *v = [[l substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k isEqualToString:key] && v.length) {
            wrLog([NSString stringWithFormat:@"config %@ = %@ (cfg)", key, v]);
            return v;
        }
    }
    return nil;
}

/* ---------- CPDistributedMessaging 监听（捕获器接入点） ---------- */
static void WRFlushTasks(void) {
    @try {
        NSString *taskDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxrelay_tasks"];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:taskDir error:nil];
        if (!files.count) return;
        wrLog([NSString stringWithFormat:@"flush %lu task file(s)", (unsigned long)files.count]);
        for (NSString *fn in files) {
            if (![fn hasSuffix:@".json"]) continue;
            NSString *p = [taskDir stringByAppendingPathComponent:fn];
            NSDictionary *task = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:p]
                options:NSJSONReadingAllowFragments error:nil];
            if ([task isKindOfClass:[NSDictionary class]]) {
                NSString *text = task[@"text"];
                NSArray *targets = task[@"targets"];
                if ([text isKindOfClass:[NSString class]] && [targets isKindOfClass:[NSArray class]]) {
                    for (NSString *target in targets) {
                        if ([target isKindOfClass:[NSString class]]) WRSendMessage(target, text);
                    }
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil]; // 处理完删自己的文件
        }
        wrLog(@"flush done");
    } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"flush EXC %@", e.name]); }
}

static void WRTaskNotifyCallback(CFNotificationCenterRef __unused center, void __unused *observer,
                                 CFStringRef __unused name, const void __unused *object, CFDictionaryRef __unused userInfo) {
    @autoreleasepool { WRFlushTasks(); }
}



__attribute__((constructor)) static void wxrelayCtor(void) {
    @autoreleasepool {
        wrLog(@"step0: ctor enter");
        id selfId = nil;

        wrLog(@"step1: self wxid detect (guarded)");
        selfId = WRDetectSelfWxid();
        wrLog([NSString stringWithFormat:@"step1 done: %@", WRElvis(selfId)]);
        (void)selfId;

        wrLog(@"step2: darwin task listener (file-based queue)");
        @try {
            Class mm = NSClassFromString(@"CMessageMgr");
            SEL ams = NSSelectorFromString(@"AddMsg:MsgWrap:");
            Method m = class_getInstanceMethod(mm, ams);
            if (m) {
                orig_AddMsg = (void (*)(id, SEL, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)hooked_AddMsg);
                wrLog(@"AddMsg hook installed");
            } else wrLog(@"AddMsg method not found");
        } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"hook EXC %@", e.name]); }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            WRTaskNotifyCallback, (__bridge CFStringRef)@"com.mos.wxrelay.task", NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        wrLog(@"step2: task listener ready");

        wrLog(@"step3: config");
        // 配置读取（内部含模板生成）
        NSString *testTarget = WRConfig(@"testTarget");
        wrLog([NSString stringWithFormat:@"step3 done: %@", WRElvis(testTarget)]);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WRLoadCatchRules();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(WR_TEST_DELAY * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                @try {
                    Class svcC = NSClassFromString(@"MMServiceCenter");
                    id ctr = ((id(*)(id,SEL))objc_msgSend)(svcC, NSSelectorFromString(@"defaultCenter"));
                    wrLog([NSString stringWithFormat:@"[20s] defaultCenter: %@ class=%@", WRElvis(ctr), NSStringFromClass([ctr class])]);
                    unsigned int n = 0; NSMutableArray *sv = [NSMutableArray new];
                    Method *ms = class_copyMethodList(object_getClass(ctr), &n);
                    for (unsigned int i = 0; i < n; i++) {
                        NSString *mn = NSStringFromSelector(method_getName(ms[i]));
                        if ([mn.lowercaseString containsString:@"service"] || [mn.lowercaseString containsString:@"getclass"])
                            [sv addObject:mn];
                    }
                    free(ms);
                    wrLog([NSString stringWithFormat:@"[20s] service accessors: %@", sv]);
                } @catch (NSException *e) { wrLog([NSString stringWithFormat:@"[20s] dump EXC %@", e.name]); }

                WRFlushTasks(); // 启动补发积压任务
                NSString *ka = WRConfig(@"keepAlive");
                if ([ka isEqualToString:@"1"]) {
                    wrLog(@"[20s] keepAlive enabled, starting silent audio");
                    self_setupKeepAlive();
                } else { wrLog(@"[20s] keepAlive off"); }
                NSString *testTarget = WRConfig(@"testTarget");
                if (!testTarget) { wrLog(@"[20s] testTarget not set — skip self-test"); return; }
                NSString *msg = [NSString stringWithFormat:@"[WXRelay 自测] %@", [NSDate date]];
                BOOL ok = WRSendMessage(testTarget, msg);
                wrLog([NSString stringWithFormat:@"[20s] self-test: %@", ok ? @"CALLED" : @"FAILED"]);
            });
        wrLog(@"ctor complete");
    }
}