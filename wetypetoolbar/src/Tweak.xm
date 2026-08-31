// WetypePlus — 直接注入「微信输入法」键盘扩展进程，在键盘自身视图里叠加工具栏。
//
// 为什么改方案：之前在「主 App 进程」里叠 toolbar，但 iOS 键盘是独立进程渲染、
// 再合成到屏幕最上层——App 窗口内的任何图层都永远在键盘下面，所以之前「什么都不显示 /
// 只在切 App 时黑底闪一下」。唯一稳的办法是写进键盘进程本身。
//
// 做法：hook UIInputViewController（所有第三方键盘的基类，微信输入法也是它），
// 把工具栏加进键盘自己的 view；用键盘的 textDocumentProxy 插字/移光标/粘贴。
// 对任意使用微信输入法的 App 都生效。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define WP_DOMAIN @"com.yzdmm.wetypeplus"
#define WP_NOTE   CFSTR("com.yzdmm.wetypeplus.changed")
// 工具栏高度：34pt。做法：把微信键盘的所有 subview 整体上移 WP_BAR_H（用 transform），
// 腾出最底部空条给工具栏；功能行(123/空格/中英/搜索)上移后与工具栏刚好相接、不重叠。
// 代价：键盘最顶部(语音/图标行)会顶出键盘上沿(被系统裁掉或压在输入框上)。
#define WP_BAR_H 34

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
- (void)relayout;
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
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        self.hidden = NO;
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
    if (self.superview != vc.view) [vc.view addSubview:self];
    [vc.view bringSubviewToFront:self];
    [self relayout];
}

- (void)relayout {
    UIInputViewController *vc = _vc;
    if (!vc || self.superview != vc.view) return;
    CGFloat w = vc.view.bounds.size.width;
    CGFloat h = WP_BAR_H;
    // 贴键盘底边：落在键盘最底部的留白区（home 指示条上方）
    self.frame = CGRectMake(0, vc.view.bounds.size.height - h, w, h);
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
    WPToolbar *t = [WPToolbar shared];
    if (t.superview != self.view) [self.view addSubview:t];

    // 把微信键盘自己的所有 subview 整体上移 WP_BAR_H（用 transform，不动 frame，
    // 不和 auto-layout 打架；hit-test 也跟着走）。
    // 这样微信键盘整体上移 WP_BAR_H，腾出最底部空条给工具栏；
    // 工具栏贴屏幕底边，与上移后的功能行(123/空格/中英/搜索)刚好相接、不重叠。
    // 代价：键盘最顶部(语音/图标行)会顶出键盘上沿(被系统裁掉或压在输入框上)。
    for (UIView *sv in [self.view.subviews copy]) {
        if (sv == t) continue;
        sv.transform = CGAffineTransformMakeTranslation(0, -WP_BAR_H);
    }
    [t relayout];
}

%end

%ctor {
    @autoreleasepool {
        wp_loadPrefs();
        // 诊断：tweak 一旦被注入键盘扩展进程就会写这个文件（含 bundle id + 时间），
        // 用于确认到底注入了哪个进程（iOS 上微信输入法键盘扩展的 bundle id 未知，靠它反查）。
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
