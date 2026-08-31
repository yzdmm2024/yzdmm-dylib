// WetypePlus — 在「正在打字的主 App」里、键盘底部留白区(spacebar 下方/home-bar 上方)叠加一条通用工具栏。
// 不进键盘扩展进程（微信输入法闭源+反调试），直接 hook 主 App 的键盘通知，
// 用第一响应者(输入框)的公开 API 插字/移光标/粘贴/全选。对任意键盘(含微信输入法)都生效。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define WP_DOMAIN @"com.yzdmm.wetypeplus"
#define WP_NOTE   CFSTR("com.yzdmm.wetypeplus.changed")
// 工具栏高度：收紧到 34pt，正好落在键盘最底部的留白(spacebar 下方 / home-bar 上方)，
// 不压数字行、也不压空格键那一行。
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

// 取当前第一响应者(输入框)：向 first responder 发送一个它多半没实现的选择子，
// 由它在自己的实现里把自己记下来。这是 UIKit 里拿 first responder 的经典 trick。
static __weak id wp_fr = nil;
@interface UIResponder (WP)
+ (id)wp_currentFirstResponder;
@end
@implementation UIResponder (WP)
+ (id)wp_currentFirstResponder {
    wp_fr = nil;
    [[UIApplication sharedApplication] sendAction:@selector(wp_capture:) to:nil from:nil forEvent:nil];
    return wp_fr;
}
- (void)wp_capture:(id)sender { wp_fr = self; }
@end

static void wp_hapticBump() {
    if (!wp_haptic) return;
    UISelectionFeedbackGenerator *g = [[UISelectionFeedbackGenerator alloc] init];
    [g selectionChanged];
}

// 监听设置变更的回调（必须是 C 函数，ARC 不允许把 block 转成 CFNotificationCallback）
static void wp_notifyCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    wp_loadPrefs();
}

@interface WPToolbar : UIView
+ (WPToolbar *)shared;
- (void)showAbove:(CGRect)kbFrame;
- (void)hide;
@end

@implementation WPToolbar {
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
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.hidden = YES;
        self.userInteractionEnabled = YES;
        _built = NO;
    }
    return self;
}

- (void)buildIfNeeded {
    if (_built) return;
    _built = YES;
    NSArray *titles = @[@"←",@"→",@"全选",@"粘贴",@"撤销",@"@@",@"#",@"？",@"！"];
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

- (void)onTap:(UIButton *)b {
    wp_hapticBump();
    NSArray *acts = @[@"left",@"right",@"selectAll",@"paste",@"undo",@"ins:@@",@"ins:#",@"ins:？",@"ins:！"];
    if (b.tag >= acts.count) return;
    NSString *a = acts[b.tag];
    id fr = [UIResponder wp_currentFirstResponder];
    if (!fr) return;
    if ([a isEqualToString:@"left"]) {
        if ([fr respondsToSelector:@selector(adjustTextPositionByCharacterOffset:)])
            [fr adjustTextPositionByCharacterOffset:-1];
    } else if ([a isEqualToString:@"right"]) {
        if ([fr respondsToSelector:@selector(adjustTextPositionByCharacterOffset:)])
            [fr adjustTextPositionByCharacterOffset:1];
    } else if ([a isEqualToString:@"selectAll"]) {
        if ([fr respondsToSelector:@selector(selectAll:)]) [fr selectAll:nil];
    } else if ([a isEqualToString:@"paste"]) {
        NSString *s = [UIPasteboard generalPasteboard].string;
        if (s.length && [fr respondsToSelector:@selector(insertText:)]) [fr insertText:s];
    } else if ([a isEqualToString:@"undo"]) {
        if ([fr respondsToSelector:@selector(undo)]) [fr undo];
    } else if ([a hasPrefix:@"ins:"]) {
        NSString *s = [a substringFromIndex:4];
        if ([fr respondsToSelector:@selector(insertText:)]) [fr insertText:s];
    }
}

- (void)showAbove:(CGRect)kbFrame {
    if (!wp_enabled) { self.hidden = YES; return; }
    [self buildIfNeeded];
    // 找到键盘所在的 window：优先 UITextEffectsWindow / 名字含 Keyboard 的 window；
    // 兜底取当前窗口列表里 level 最高的可见 window（iOS 16 键盘 window 一般 level 最高）。
    UIWindow *tew = nil;
    UIWindow *top = nil;
    UIWindowLevel topLevel = -MAXFLOAT;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSString *cn = NSStringFromClass(w.class);
        if ([cn containsString:@"TextEffects"] || [cn containsString:@"Keyboard"]) { tew = w; break; }
        if (!w.hidden && w.windowLevel > topLevel) { topLevel = w.windowLevel; top = w; }
    }
    if (!tew) tew = top ?: [UIApplication sharedApplication].keyWindow;
    if (!tew) return;
    if (self.superview != tew) [tew addSubview:self];
    [tew bringSubviewToFront:self];
    // 工具栏放在键盘「底部空隙」(spacebar 下方 / home-bar 上方那道留白)：
    // 顶边贴键盘底边，落在键盘最下方的空白里——不挡输入框、也不盖数字行。
    // 代价：若某键盘底部留白 < WP_BAR_H，会轻微压到空格键那一行最下缘。
    CGFloat h = WP_BAR_H;
    CGFloat y = kbFrame.origin.y + kbFrame.size.height - h;
    self.frame = CGRectMake(kbFrame.origin.x, y, kbFrame.size.width, h);
    self.hidden = NO;
}

- (void)hide { self.hidden = YES; }

@end

%ctor {
    @autoreleasepool {
        wp_loadPrefs();
        // 诊断：tweak 一旦被注入目标 App 就会写这个文件，用于确认是否真的加载进 App。
        // roothide 默认不注入普通 App，所以「什么都不显示」多半是没注入——看这个文件就知道。
        NSString *mark = [NSString stringWithFormat:@"WetypePlus loaded in %@ at %@\n",
            ([[NSBundle mainBundle] bundleIdentifier] ?: @"?"), [NSDate date]];
        [mark writeToFile:@"/var/mobile/wp_injected.log" atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)wp_notifyCallback,
            WP_NOTE, NULL, CFNotificationSuspensionBehaviorCoalesce);

        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification object:nil queue:nil usingBlock:^(NSNotification *n){
            CGRect f = [[n.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
            [[WPToolbar shared] showAbove:f];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidChangeFrameNotification object:nil queue:nil usingBlock:^(NSNotification *n){
            CGRect f = [[n.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
            CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
            if (f.origin.y < screenH - 1) [[WPToolbar shared] showAbove:f];
            else [[WPToolbar shared] hide];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidHideNotification object:nil queue:nil usingBlock:^(NSNotification *n){
            [[WPToolbar shared] hide];
        }];
    }
}
