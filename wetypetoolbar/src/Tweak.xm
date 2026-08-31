// WetypePlus 3.0.2 — 注入微信输入法键盘扩展进程，用工具栏替换顶部图标行(WBTopBar)。
//
// 关键修正（相对 3.0.1）：
//   3.0.1 的 probeIconBarIn: 只查 vc.view 的「直接子视图」，但图标行的真实类名是
//   WBTopBar，它埋在 7 层嵌套里(UIInputView->_UIInputViewContent->WBRootInputView->
//   WBMainInputView->WBTopBar)，永远不是直接子视图 → 永远命中不了 → 退化成 y=0/38pt
//   固定条，而真正的图标行(嵌套子视图)也在 y≈0 → 视觉重叠 == "还是一样"。
//   另外本扩展里 vc.view.frame 全为 0，导致之前的宽度判据也失效。
//
//   3.0.2：在 vc.view 上「递归」查找，按类名精确匹配 WBTopBar（frida 已实锤该名字）；
//   命中后读它的真实 frame，把工具栏加进它「同一个父视图」(同坐标系)，并把 WBTopBar
//   的所有 subview 递归 hidden。不再依赖 vc.view.frame。真实几何写进 wp_geo.log 供核对。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define WP_DOMAIN @"com.yzdmm.wetypeplus"
#define WP_NOTE   CFSTR("com.yzdmm.wetypeplus.changed")
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

static void wp_log(NSString *file, NSString *line) {
    NSString *stamp = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    NSString *cur = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [[cur stringByAppendingString:stamp] writeToFile:file
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
    BOOL _geoLogged;
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
        _geoLogged = NO;
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
    self.hidden = NO;
}

// 递归在 view 树里找指定类名的子视图（不限于直接子视图）。
- (UIView *)findClass:(NSString *)clsName inView:(UIView *)v depth:(int)d {
    if (!v || d > 24) return nil;
    NSString *cn = NSStringFromClass(v.class);
    if ([cn isEqualToString:clsName]) return v;
    for (UIView *s in v.subviews) {
        UIView *r = [self findClass:clsName inView:s depth:d + 1];
        if (r) return r;
    }
    return nil;
}

// 递归在 view 树里找「类名含子串」的子视图，优先返回最靠上(y 最小)的。
- (UIView *)findClassContains:(NSString *)sub inView:(UIView *)v depth:(int)d bestY:(CGFloat *)bestY {
    if (!v || d > 24) return nil;
    NSString *cn = NSStringFromClass(v.class);
    UIView *found = nil;
    if ([cn rangeOfString:sub].location != NSNotFound) {
        CGRect f = v.frame;
        if (f.size.height > 20 && f.size.height < 70 && f.size.width > 200) {
            if (!found || f.origin.y < *bestY) { found = v; *bestY = f.origin.y; }
        }
    }
    for (UIView *s in v.subviews) {
        UIView *r = [self findClassContains:sub inView:s depth:d + 1 bestY:bestY];
        if (r) found = r;
    }
    return found;
}

- (void)relayoutReplacingIconBar {
    UIInputViewController *vc = _vc;
    if (!vc) { self.hidden = YES; return; }
    UIView *root = vc.view;
    if (!root) { self.hidden = YES; return; }

    UIView *iconBar = objc_getAssociatedObject(root, "wp.iconBar");
    NSString *how = objc_getAssociatedObject(root, "wp.iconBarHow");
    if (!iconBar) {
        // 1) 精确匹配 frida 实锤的 WBTopBar
        iconBar = [self findClass:@"WBTopBar" inView:root depth:0];
        how = @"WBTopBar";
        // 2) 退而求其次：类名含 TopBar
        if (!iconBar) {
            CGFloat bestY = 1e9;
            iconBar = [self findClassContains:@"TopBar" inView:root depth:0 bestY:&bestY];
            how = @"*TopBar*";
        }
        // 3) 再退化：递归找顶部、高度 28~55、宽>200、子视图>=3 的第一条
        if (!iconBar) {
            iconBar = [self findIconHeuristicIn:root depth:0 bestY:&(CGFloat){1e9}];
            how = @"heuristic";
        }
        if (iconBar) {
            objc_setAssociatedObject(root, "wp.iconBar", iconBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(root, "wp.iconBarHow", how, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGRect f = iconBar.frame;
            wp_log(@"/var/mobile/wp_geo.log",
                   [NSString stringWithFormat:@"FOUND iconBar via %@ class=%@ frame={%.1f,%.1f,%.1f,%.1f} subviews=%lu",
                    how, NSStringFromClass(iconBar.class),
                    f.origin.x, f.origin.y, f.size.width, f.size.height,
                    (unsigned long)iconBar.subviews.count]);
        } else {
            wp_log(@"/var/mobile/wp_geo.log", @"NO iconBar found (all strategies failed)");
        }
    }

    if (!iconBar) {
        // 实在找不到：退回顶部固定 38pt（至少可见，不保证不重叠）
        if (self.superview != root) [root addSubview:self];
        [root bringSubviewToFront:self];
        if (!CGRectEqualToRect(self.frame, CGRectMake(0, 0, root.bounds.size.width, WP_BAR_H_DEFAULT))) {
            self.frame = CGRectMake(0, 0, root.bounds.size.width, WP_BAR_H_DEFAULT);
            _built = NO; for (UIView *s in [self.subviews copy]) [s removeFromSuperview]; [self buildIfNeeded];
        }
        return;
    }

    // 加进图标行「同一个父视图」，坐标系一致，frame 直接取图标行原位。
    UIView *host = iconBar.superview ?: root;
    if (self.superview != host) [host addSubview:self];
    [host bringSubviewToFront:self];

    CGRect f = iconBar.frame;
    CGRect barRect = CGRectMake(f.origin.x, f.origin.y, f.size.width, f.size.height);
    if (!CGRectEqualToRect(self.frame, barRect)) {
        self.frame = barRect;
        _built = NO; for (UIView *s in [self.subviews copy]) [s removeFromSuperview]; [self buildIfNeeded];
    }

    // 隐藏图标行内容（递归），视觉上由工具栏无缝替代。
    [self hideAllSubviewsOf:iconBar];

    if (!_geoLogged) {
        _geoLogged = YES;
        wp_log(@"/var/mobile/wp_geo.log",
               [NSString stringWithFormat:@"APPLIED toolbar frame={%.1f,%.1f,%.1f,%.1f} host=%@",
                self.frame.origin.x, self.frame.origin.y, self.frame.size.width, self.frame.size.height,
                NSStringFromClass(host.class)]);
    }
}

- (void)hideAllSubviewsOf:(UIView *)v {
    for (UIView *s in v.subviews) {
        s.hidden = YES;
        [self hideAllSubviewsOf:s];
    }
}

// 递归启发式：找顶部(最小 y)、高度 28~55、宽>200、子视图>=3 的第一条 view。
- (UIView *)findIconHeuristicIn:(UIView *)v depth:(int)d bestY:(CGFloat *)bestY {
    if (!v || d > 24) return nil;
    UIView *best = nil;
    CGRect f = v.frame;
    if (f.size.height > 28 && f.size.height < 55 && f.size.width > 200 && v.subviews.count >= 3) {
        if (f.origin.y < *bestY) { *bestY = f.origin.y; best = v; }
    }
    for (UIView *s in v.subviews) {
        UIView *r = [self findIconHeuristicIn:s depth:d + 1 bestY:bestY];
        if (r) best = r;
    }
    return best;
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
        wp_log(@"/var/mobile/wp_kb_loaded.log",
               [NSString stringWithFormat:@"[ctor] WetypePlus(KEYBOARD) loaded in %@ at %@",
                ([[NSBundle mainBundle] bundleIdentifier] ?: @"?"), [NSDate date]]);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)wp_notifyCallback,
            WP_NOTE, NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
