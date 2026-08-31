// WetypePlus 3.0.0 — 注入微信输入法键盘扩展进程，在「键盘上方」叠加一条工具栏。
//
// 布局关键（参考 SquidExtender）：工具栏加在键盘所属的 window 里、键盘顶边之上
// (y = 键盘顶边.y - WP_BAR_H)，叠在 App 内容之上、属于键盘图层所以不被键盘盖住。
// 这样既不压键盘任何按键行，也不占底部 home 指示条安全区（那是系统保留、第三方键盘不能用）。
//
// 做法：hook UIInputViewController（所有第三方键盘的基类，微信输入法也是它），
// 把工具栏加进键盘 window；用键盘的 textDocumentProxy 插字/移光标/粘贴。
// 对任意使用微信输入法的 App 都生效。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define WP_DOMAIN @"com.yzdmm.wetypeplus"
#define WP_NOTE   CFSTR("com.yzdmm.wetypeplus.changed")
// 工具栏高度：38pt，落在「键盘顶边之上」那道空隙（键盘 window 内、App 内容之上）。
#define WP_BAR_H 38

static BOOL wp_enabled = YES;
static BOOL wp_haptic  = YES;

static void wp_loadPrefs() {
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", WP_DOMAIN];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    if (d) {
        if (d[@"enabled"] != nil) wp_enabled = [d[@"enabled"] boolValue];
        if (d[@"haptic"]  != nil) wp_haptic  = [d[@"haptic"]  boolValue];
    }
}

// 监听设置变更的回调（必须是 C 函数，ARC 不允许把 block 转成 CFNotificationCallback）
static void wp_notifyCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    wp_loadPrefs();
}

static void wp_hapticBump() {
    if (!wp_haptic) return;
    UISelectionFeedbackGenerator *g = [[UISelectionFeedbackGenerator alloc] init];
    [g selectionChanged];
}

@interface WPToolbar : UIView
+ (WPToolbar *)shared;
- (void)attachTo:(UIInputViewController *)vc;
- (void)relayoutAboveKeyboard;
@end

@implementation WPToolbar {
    __weak UIInputViewController *_vc;
    BOOL _built;
}

+ (WPToolbar *)shared {
    static WPToolbar *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[WPToolbar alloc] initWithFrame:CGRectZero]; });
    return t;
}

- (id)initWithFrame:(CGRect)f {
    self = [super initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, WP_BAR_H)];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
        self.hidden = YES;
        self.userInteractionEnabled = YES;
        _built = NO;
    }
    return self;
}

- (void)buildIfNeeded {
    if (_built) return;
    _built = YES;
    // 键盘进程里只能用 textDocumentProxy 操作文本：光标左/右、粘贴、插入符号。
    // （selectAll/undo 在键盘代理里没有对应接口，故本版不含。）
    NSArray *titles = @[@"←",@"→",@"粘贴",@"@@",@"#",@"？",@"！"];
    NSUInteger n = titles.count;
    CGFloat w = self.bounds.size.width / n;
    for (NSUInteger i = 0; i < n; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(w * i, 0, w, WP_BAR_H);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15];
        b.tag = i;
        [b addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
        if (i > 0) {
            UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(w * i, 6, 0.5, WP_BAR_H - 12)];
            sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
            [self addSubview:sep];
        }
    }
}

- (void)attachTo:(UIInputViewController *)vc {
    _vc = vc;
    [self buildIfNeeded];
}

// 放在「键盘上方」：键盘顶边之上 WP_BAR_H 的位置（在键盘 window 内、App 内容之上，不被键盘盖住）。
- (void)relayoutAboveKeyboard {
    UIInputViewController *vc = _vc;
    if (!vc) return;
    UIWindow *win = vc.view.window;
    if (!win) return;
    CGRect kb = vc.view.frame;            // 键盘在 window 中的 frame
    CGFloat y = kb.origin.y - WP_BAR_H;   // 键盘顶边再往上 WP_BAR_H
    if (y < 0) y = 0;
    self.frame = CGRectMake(0, y, win.bounds.size.width, WP_BAR_H);
    if (self.superview != win) [win addSubview:self];
    [win bringSubviewToFront:self];
    self.hidden = NO;
}

- (void)onTap:(UIButton *)b {
    wp_hapticBump();
    UIInputViewController *vc = _vc;
    if (!vc) return;
    id proxy = vc.textDocumentProxy;
    if (!proxy) return;
    NSArray *acts = @[@"left",@"right",@"paste",@"ins:@@",@"ins:#",@"ins:？",@"ins:！"];
    if (b.tag >= acts.count) return;
    NSString *a = acts[b.tag];
    if ([a isEqualToString:@"left"]) {
        if ([proxy respondsToSelector:@selector(adjustTextPositionByCharacterOffset:)])
            [proxy adjustTextPositionByCharacterOffset:-1];
    } else if ([a isEqualToString:@"right"]) {
        if ([proxy respondsToSelector:@selector(adjustTextPositionByCharacterOffset:)])
            [proxy adjustTextPositionByCharacterOffset:1];
    } else if ([a isEqualToString:@"paste"]) {
        NSString *s = [UIPasteboard generalPasteboard].string;
        if (s.length && [proxy respondsToSelector:@selector(insertText:)]) [proxy insertText:s];
    } else if ([a hasPrefix:@"ins:"]) {
        NSString *s = [a substringFromIndex:4];
        if ([proxy respondsToSelector:@selector(insertText:)]) [proxy insertText:s];
    }
}

@end

%hook UIInputViewController

- (void)viewDidLoad {
    %orig;
    if (!wp_enabled) return;
    [[WPToolbar shared] attachTo:self];
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!wp_enabled) return;
    // 每次布局都重算位置（键盘出现/旋转/切换输入法时自动跟随）。
    [[WPToolbar shared] relayoutAboveKeyboard];
}

%end

%ctor {
    @autoreleasepool {
        wp_loadPrefs();
        // 诊断：tweak 一旦被注入键盘扩展进程就会写这个文件（含 bundle id + 时间），
        // 用于确认到底注入了哪个进程。
        NSString *mark = [NSString stringWithFormat:@"WetypePlus(KEYBOARD) loaded in %@ at %@\n",
            ([[NSBundle mainBundle] bundleIdentifier] ?: @"?"), [NSDate date]];
        [mark writeToFile:@"/var/mobile/wp_kb_loaded.log" atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)wp_notifyCallback,
            WP_NOTE, NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
