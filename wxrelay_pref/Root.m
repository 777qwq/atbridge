#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface PSListController : UIViewController
@end

@interface WXPRootController : PSListController
- (void)openCfgInFilza;
- (void)reloadRules;
@end

@implementation WXPRootController

- (NSString *)cfgPath {
    NSString *appsDir = @"/var/mobile/Containers/Data/Application";
    NSArray *dirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *d in dirs) {
        NSString *meta = [appsDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@/.com.apple.mobile_container_manager.metadata.plist", d]];
        NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([[md objectForKey:@"MCMMetadataIdentifier"] isEqualToString:@"com.tencent.xin"]) {
            return [[appsDir stringByAppendingPathComponent:d] stringByAppendingPathComponent:@"tmp/wxrelay.cfg"];
        }
    }
    return nil;
}

- (void)openCfgInFilza {
    NSString *p = [self cfgPath];
    if (!p) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"未找到微信沙盒"
            message:@"先打开一次微信再试" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [UIPasteboard generalPasteboard].string = p;
    NSURL *u = [NSURL URLWithString:@"filza://"];
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"路径已复制"
        message:[NSString stringWithFormat:@"已打开 Filza，粘贴路径即可直达配置文件：\n%@", p]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)reloadRules {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)@"com.mos.wxrelay.cfgchanged", NULL, NULL, YES);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已触发重载"
        message:@"两端会在下一条消息/通知到达时使用新规则" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
