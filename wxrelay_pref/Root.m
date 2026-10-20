/**
 * WXPRootController — 设置 App 内的 WXRelay 规则编辑器
 * 编辑目标：微信沙盒 tmp/wxrelay.cfg（运行时扫描定位微信容器）
 * 保存即热生效（微信侧每次收信现读；SB 侧每条通知现读）
 */
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

@interface WXPRootController : UIViewController <UITextViewDelegate>
@end
@implementation WXPRootController {
    UITextView *_tv;
    UILabel *_status;
    NSString *_cfgPath;
}

- (NSString *)resolveCfgPath {
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

- (NSString *)defaultTemplate {
    return @"# WXRelay 配置（保存即热生效，无需重启）\n"
           "# catch=匹配文本#目标id1#目标id2   ← 微信消息触发规则，可多行\n"
           "# 目标 id 用懒猫的复制按钮拿（wxid_xxx / 群id@chatroom / filehelper）\n"
           "testTarget=\n"
           "keepAlive=1\n"
           "catch=指令#filehelper\n";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"WXRelay";

    _cfgPath = [self resolveCfgPath];

    UILabel *pathLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 60, self.view.bounds.size.width - 32, 30)];
    pathLabel.text = _cfgPath ?: @"未找到微信沙盒（先打开一次微信）";
    pathLabel.font = [UIFont systemFontOfSize:11];
    pathLabel.textColor = [UIColor secondaryLabelColor];
    pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:pathLabel];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(16, 100, self.view.bounds.size.width - 32, 420)];
    tv.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    tv.layer.borderColor = [UIColor separatorColor].CGColor;
    tv.layer.borderWidth = 1;
    tv.layer.cornerRadius = 8;
    tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tv = tv;
    [self.view addSubview:tv];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(16, 530, self.view.bounds.size.width - 32, 30)];
    _status.font = [UIFont systemFontOfSize:12];
    _status.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:_status];

    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
        target:self action:@selector(saveTapped)];
    self.navigationItem.rightBarButtonItem = save;

    if (_cfgPath && [[NSFileManager defaultManager] fileExistsAtPath:_cfgPath]) {
        _tv.text = [NSString stringWithContentsOfFile:_cfgPath encoding:NSUTF8StringEncoding error:nil] ?: [self defaultTemplate];
    } else {
        _tv.text = [self defaultTemplate];
    }
}

- (void)saveTapped {
    @try {
        if (!_cfgPath) { _status.text = @"保存失败：未找到微信沙盒"; return; }
        NSError *err = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:[_cfgPath stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:&err];
        [_tv.text writeToFile:_cfgPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
        _status.text = err ? [NSString stringWithFormat:@"保存失败: %@", err.localizedDescription]
                           : @"已保存，热生效（下一条消息/通知起用新规则）";
        // darwin 通知（预留：触发端可监听做即时重载；当前两端本就每条现读）
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)@"com.mos.wxrelay.cfgchanged", NULL, NULL, YES);
    } @catch (NSException *e) {
        _status.text = [NSString stringWithFormat:@"异常: %@", e.name];
    }
}
