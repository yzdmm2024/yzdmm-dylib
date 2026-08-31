// WetypePlus 3.0.1 — 注入微信输入法键盘扩展进程，用工具栏替换顶部图标行。
//
// 布局关键：工具栏加进键盘的 view(vc.view)，占据原"图标行"的位置(y=0, h=图标行高度)，
// 并把图标行里的所有 subview 隐藏。这样视觉上无缝替代——QWERTYUIOP 仍紧贴工具栏底边，
// 不影响键盘总高度、不压任何按键、不压输入框。
//
// 上一版 3.0.0 把工具栏放在 vc.view.window / 键盘顶边之上的空隙里，结果压到了微信键盘
// 顶部的"按住说话/语音/AI/键盘切换"那排圆形图标按钮，看着糊。
//
// 关键 hook：viewDidLayoutSubviews 内首次探查顶部"图标行"，记下其高度并把所有 subview 隐藏。
// 因为不能用 frida 在真机调试，启发式判据：y<5、高度 28~55、子视图>=3、宽度接近满屏。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define WP_DOMAIN @"com.yzdmm.wetypeplus"
#define WP_NOTE   CFSTR("com.yzdmm.wetypeplus.changed")
// 工具栏高度：若图标行探查成功则取图标行高度，否则用 38 兜底。
#define WP_BAR_H_DEFAULT 38

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

static void wp_notifyCallback(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    wp_loadPrefs();
}

static void wp_hapticBump() {
    if (!wp_haptic) return;
    UISelectionFeedbackGenerator *g = [[UISelectionFeedbackGenerator alloc] init];
    [g selectionChanged];
}

// 把诊断信息写到一行 log（追加），方便真机反馈时定位布局问题。
static void wp_diag(NSString *line) {
    NSString *path = @"/var/mobile/wp_kb_loaded.log";
    NSString *stamp = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    NSString *cur = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [[cur stringByAppendingString:stamp] writeToFile:path
                                          atomically:YES
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
}

@interface WPToolbar : UIView
+ (WPToolbar *)shared;
- (void)attachTo:(UIInputViewController *)vc;
- (void)relayoutReplacingIconBar;
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
    self = [super initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, WP_BAR_H_DEFAULT)];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.98];
        self.hidden = YES;
        self.userInteractionEnabled = YES;
        _built = NO;
    }
    return self;
}

- (void)buildIfNeeded {
    if (_built) return;
    _built = YES;
    NSArray *titles = @[@"←",@"→",@"粘贴",@"@@",@"#",@"？",@"！"];
    NSUInteger n = titles.count;
    CGFloat w = self.bounds.size.width / n;
    for (NSUInteger i = 0; i < n; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(w * i, 0, w, self.bounds.size.height);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15];
        b.tag = i;
        [b addTarget:self action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
        if (i > 0) {
            UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(w * i, 6, 0.5, self.bounds.size.height - 12)];
            sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
            [self addSubview:sep];
        }
    }
}

- (void)attachTo:(UIInputViewController *)vc {
    _vc = vc;
    [self buildIfNeeded];
    if (vc.view && self.superview != vc.view) {
        [vc.view addSubview:self];
    }
    self.hidden = NO;
}

// 找顶部"图标行"（y≈0、高度 28~55、子视图>=3、宽度接近满屏），返回第一个匹配的。
// 若用 NSClassFromString 探不到 WTypeTopBar 之类私有类，只能用启发式 fallback。
- (UIView *)probeIconBarIn:(UIView *)v {
    UIView *cur = nil;
    CGFloat screenW = v.bounds.size.width;
    for (UIView *sub in v.subviews) {
        if (sub == self) continue;
        CGRect f = sub.frame;
        BOOL atTop = fabs(f.origin.y) < 2;
        BOOL iconHeight = f.size.height > 28 && f.size.height < 55;
        BOOL wideEnough = f.size.width >= screenW * 0.95;
        BOOL hasChildren = sub.subviews.count >= 3;
        if (atTop && iconHeight && wideEnough && hasChildren) {
            cur = sub;
            break;
        }
    }
    if (!cur) {
        // 兜底：放宽"子视图数"约束（部分键盘图标行只有一个容器 view）
        for (UIView *sub in v.subviews) {
            if (sub == self) continue;
            CGRect f = sub.frame;
            if (fabs(f.origin.y) < 2 && f.size.height > 28 && f.size.height < 55
                && f.size.width >= screenW * 0.95) {
                cur = sub;
                break;
            }
        }
    }
    return cur;
}

// 占据图标行原位置；同时隐藏图标行内所有 subview，但保留图标行 view 的 frame
// （键盘总高度/布局不会因此变化）。
- (void)relayoutReplacingIconBar {
    UIInputViewController *vc = _vc;
    if (!vc || !vc.view) { self.hidden = YES; return; }
    UIView *v = vc.view;

    UIView *iconBar = objc_getAssociatedObject(v, "wp.iconBar");
    if (!iconBar) {
        iconBar = [self probeIconBarIn:v];
        if (iconBar) {
            objc_setAssociatedObject(v, "wp.iconBar", iconBar,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            wp_diag([NSString stringWithFormat:@"probed iconBar=%@ frame={%.1f,%.1f,%.1f,%.1f} subviews=%lu",
                     NSStringFromClass(iconBar.class),
                     iconBar.frame.origin.x, iconBar.frame.origin.y,
                     iconBar.frame.size.width, iconBar.frame.size.height,
                     (unsigned long)iconBar.subviews.count]);
        } else {
            wp_diag(@"NO iconBar matched in keyboard view");
        }
    }

    if (self.superview != v) [v addSubview:self];
    [v bringSubviewToFront:self];

    CGRect barRect;
    if (iconBar) {
        // 用图标行原位
        CGRect f = iconBar.frame;
        barRect = CGRectMake(0, 0, f.size.width, f.size.height);
        // 隐藏图标行内容
        iconBar.hidden = NO;
        for (UIView *sub in iconBar.subviews) sub.hidden = YES;
        objc_setAssociatedObject(v, "wp.iconBarH", @(f.size.height),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        // 没找到图标行——退回到顶部固定高度
        barRect = CGRectMake(0, 0, v.bounds.size.width, WP_BAR_H_DEFAULT);
    }

    if (!CGRectEqualToRect(self.frame, barRect)) {
        self.frame = barRect;
        // 重建按钮以匹配新高度
        _built = NO;
        for (UIView *sub in [self.subviews copy]) [sub removeFromSuperview];
        [self buildIfNeeded];
    }
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

static const void *kWpSetupDone = &kWpSetupDone;

- (void)viewDidLoad {
    %orig;
    if (!wp_enabled) return;
    [[WPToolbar shared] attachTo:self];
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!wp_enabled) return;
    [[WPToolbar shared] relayoutReplacingIconBar];
}

%end

%ctor {
    @autoreleasepool {
        wp_loadPrefs();
        NSString *mark = [NSString stringWithFormat:@"[ctor] WetypePlus(KEYBOARD) loaded in %@ at %@\n",
            ([[NSBundle mainBundle] bundleIdentifier] ?: @"?"), [NSDate date]];
        NSString *cur = [NSString stringWithContentsOfFile:@"/var/mobile/wp_kb_loaded.log"
                                                  encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [[cur stringByAppendingString:mark] writeToFile:@"/var/mobile/wp_kb_loaded.log"
                                              atomically:YES
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)wp_notifyCallback,
            WP_NOTE, NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
