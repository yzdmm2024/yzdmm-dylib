// KBPSettingsController.m - KeyboardPlusPro 设置面板
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

@interface KBPSettingsController : PSListController
@end

@implementation KBPSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    @try {
        NSArray *specs = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (specs && specs.count > 0) {
            self.specifiers = specs;
        }
    } @catch (NSException *e) {
        NSLog(@"[KeyboardPlusPro] prefs init failed: %@", e.reason);
    }
}

- (void)setPreferenceValue:(id)value specifier:(id)specifier {
    [super setPreferenceValue:value specifier:specifier];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.yzdmm.keyboardplusprefs.changed"),
                                         NULL, NULL, YES);
}

- (void)respring {
    pid_t pid;
    const char *args[] = {"killall", "-9", "SpringBoard", NULL};
    posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)args, NULL);
}

@end