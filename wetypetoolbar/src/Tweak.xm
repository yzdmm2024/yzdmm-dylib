// WetypePlus 3.0.3 — 诊断增强版。
//
// 相对 3.0.2 的变化：
//   1) 日志统一写到一个文件 wp_geo.log，且 %ctor 启动时「立即写一行」。
//      判读规则（非常重要）：
//        - wp_geo.log 存在且有 [ctor] 行      => 注入成功，tweak 已加载；
//        - wp_geo.log 完全不存在              => dylib 根本没加载（filter 不匹配 / per-app 没开 /
//                                               deb 没真正安装 / 键盘进程没重启）。
//   2) 日志路径多候选兜底：/var/mobile/wp_geo.log -> /var/mobile/Library/Caches/wp_geo.log
//      -> /tmp/wp_geo.log。首行会打印「最终生效路径」，规避某些进程对 /var/mobile 无写权限。
//   3) viewDidLayoutSubviews 每次调用都写入口日志（vc 类名 / view 类名 / 子视图数 / enabled），
//      首次调用额外 dump 前 3 层视图树，直接从 tweak 视角确认 WBTopBar 是否可达。
//
// 工具栏定位逻辑（递归按类名 WBTopBar 命中图标行、占据其原位、隐藏其按钮）保持不变。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define WP_DOMAIN @"com.yzdmm.wetypeplus"
#define WP_NOTE   CFSTR("com.yzdmm.wetypeplus.changed")
#define WP_BAR_H_DEFAULT 38

static BOOL wp_enabled = YES;
static BOOL wp_haptic  = YES;

// ---------------- 日志（多路径兜底） ----------------
static NSString *g_wpLogPath = nil;

static NSString *wp_resolveLogPath() {
    if (g_wpLogPath) return g_wpLogPath;
    NSArray *cands = @[
        @"/var/mobile/wp_geo.log",
        @"/var/mobile/Library/Caches/wp_geo.log",
        @"/tmp/wp_geo.log"
    ];
    for (NSString *f in cands) {
        // 先 probe 这一行，能写说明路径可用，随即清空，避免污染日志
        if ([@"probe\n" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            [[NSData data] writeToFile:f atomically:YES]; // 清空成空文件
            g_wpLogPath = f;
            return f;
        }
    }
    g_wpLogPath = cands.firstObject; // 全都不行也硬写一个，至少看报错
    return g_wpLogPath;
}

static void wp_log(NSString *line) {
    NSString *file = wp_resolveLogPath();
    NSString *stamp = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    NSString *cur = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] ?: @"";
    if (cur.length > 20000) cur = [cur substringFromIndex:cur.length - 10000]; // 防无限增长
    [[cur stringByAppendingString:stamp] writeToFile:file
                                          atomically:YES
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
}

// 递归 dump 视图树（限前 3 层），直接从 tweak 视角看键盘层级
static void wp_dumpTree(UIView *v, int depth, NSMutableString *out) {
    if (!v || depth > 3) return;
    for (int i = 0; i < depth; i++) [out appendString:@"  "];
    CGRect f = v.frame;
    [out appendFormat:@"%@ {%.1f,%.1f,%.1f,%.1f} sub=%lu\n",
        NSStringFromClass(v.class), f.origin.x, f.origin.y, f.size.width, f.size.height,
        (unsigned long)v.subviews.count];
    for (UIView *s in v.subviews) wp_dumpTree(s, depth + 1, out);
}

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
    if (!vc) { self.hidden = YES; wp_log(@"[relayout] bail: _vc nil"); return; }
    UIView *root = vc.view;
    if (!root) { self.hidden = YES; wp_log(@"[relayout] bail: vc.view nil"); return; }

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
            CGFloat bestY = 1e9;
            iconBar = [self findIconHeuristicIn:root depth:0 bestY:&bestY];
            how = @"heuristic";
        }
        if (iconBar) {
            objc_setAssociatedObject(root, "wp.iconBar", iconBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(root, "wp.iconBarHow", how, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGRect f = iconBar.frame;
            wp_log([NSString stringWithFormat:@"FOUND iconBar via %@ class=%@ frame={%.1f,%.1f,%.1f,%.1f} subviews=%lu",
                    how, NSStringFromClass(iconBar.class),
                    f.origin.x, f.origin.y, f.size.width, f.size.height,
                    (unsigned long)iconBar.subviews.count]);
        } else {
            wp_log(@"NO iconBar found (all strategies failed)");
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
        wp_log([NSString stringWithFormat:@"APPLIED toolbar frame={%.1f,%.1f,%.1f,%.1f} host=%@",
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
    if (!wp_enabled) {
        wp_log(@"[layout] disabled via prefs, skip");
        return;
    }
    UIInputViewController *vc = self;
    static BOOL sFirstLayout = YES;
    if (sFirstLayout) {
        sFirstLayout = NO;
        NSMutableString *tree = [NSMutableString string];
        wp_dumpTree(vc.view, 0, tree);
        wp_log([NSString stringWithFormat:
                @"[layout] FIRST vc=%@ view=%@ subviews=%d\n%@",
                NSStringFromClass(vc.class),
                vc.view ? NSStringFromClass(vc.view.class) : @"nil",
                (int)(vc.view ? vc.view.subviews.count : 0),
                tree]);
    } else {
        wp_log([NSString stringWithFormat:
                @"[layout] vc=%@ view=%@ subviews=%d",
                NSStringFromClass(vc.class),
                vc.view ? NSStringFromClass(vc.view.class) : @"nil",
                (int)(vc.view ? vc.view.subviews.count : 0)]);
    }
    [[WPToolbar shared] relayoutReplacingIconBar];
}

%end

%ctor {
    @autoreleasepool {
        wp_loadPrefs();
        wp_resolveLogPath(); // 确定可写路径（会清掉 probe 行）
        wp_log([NSString stringWithFormat:
                @"[ctor] WetypePlus 3.0.3 loaded | process=%@ bundle=%@ logPath=%@",
                ([[NSProcessInfo processInfo] processName] ?: @"?"),
                ([[NSBundle mainBundle] bundleIdentifier] ?: @"?"),
                wp_resolveLogPath()]);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)wp_notifyCallback,
            WP_NOTE, NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
