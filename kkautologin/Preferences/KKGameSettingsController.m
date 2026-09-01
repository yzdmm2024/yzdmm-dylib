// KKGameSettingsController.m — KKGameAutoLogin 设置面板
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <spawn.h>

// Preferences.framework 的 PSListController（私有框架，SDK 无头文件，前向声明）
@interface PSListController : UIViewController
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
- (id)readPreferenceValue:(id)specifier;
@property (nonatomic, retain) NSArray *specifiers;
@end

@interface KKGameSettingsController : PSListController
@end

@implementation KKGameSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    @try {
        NSArray *specs = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (specs && specs.count > 0) {
            self.specifiers = specs;
        }
    } @catch (NSException *e) {
        NSLog(@"[KKGameAutoLogin] prefs init failed: %@", e.reason);
    }
}

- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    [super setPreferenceValue:value specifier:specifier];
    // 设置保存在 FaceSettings（Preferences 进程）的偏好域里，
    // 而游戏进程的 NSUserDefaults/CFPreferences 与其隔离、读不到。
    // 故这里把配置再显式写入游戏进程可读的固定 plist 文件，实现跨进程共享。
    [self flushKKConfigToFiles];
    // 提示游戏进程里已打开的设置无需刷新；仅作记录，可选。
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.yzdmm.kkgameautologin.changed"),
                                         NULL, NULL, YES);
}

// 读取设置域当前值，写入多个候选路径，保证 roothide 下游戏进程能读到
- (void)flushKKConfigToFiles {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *account = [ud stringForKey:@"account"] ?: @"";
    NSString *password = [ud stringForKey:@"password"] ?: @"";
    id enabledVal = [ud objectForKey:@"autoLoginEnabled"];
    BOOL enabled = (enabledVal == nil) ? YES : [enabledVal boolValue];
    NSDictionary *dict = @{
        @"account": account,
        @"password": password,
        @"autoLoginEnabled": @(enabled),
    };
    NSArray *paths = @[
        @"/var/mobile/Library/Preferences/com.yzdmm.kkgameautologin.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.kkgameautologin.plist",
    ];
    for (NSString *p in paths) {
        BOOL ok = [dict writeToFile:p atomically:YES];
        NSLog(@"[KKGameAutoLogin] prefs written to %@ -> %d", p, ok);
    }
}

- (void)respring {
    pid_t pid;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, NULL);
}

@end