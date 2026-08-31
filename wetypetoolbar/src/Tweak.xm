// WetypePlus 3.0.6 — 根治「挡住候选栏」。
//
// 之前 3.0.0~3.0.5 的做法是「把工具栏叠在 WBTopBar（候选栏）原位并隐藏它的子视图」，
// 结果就是候选栏（你打的字）被盖住/被隐藏。frida 实锤 WBTopBar 就是顶部候选栏容器。
//
// 3.0.6 改成本质不同的方案：不碰候选栏，而是把【整个键盘向上撑高 WP_GROW(36pt)】，
// 工具栏作为全新的一行钉在键盘最顶，候选栏 + 按键整体下移 WP_GROW，三者互不重叠。
//
// 具体实现：hook 系统键盘视图 UIInputView：
//   - setFrame: 每次系统设置键盘高度时，把高度 +WP_GROW、原点 y -WP_GROW（向上撑高）。
//   - layoutSubviews: 系统布局完后，把所有「直接子视图」（候选栏/按键区）向下平移 WP_GROW，
//     再把工具栏钉到顶部 (0,0,W,WP_GROW)。平移只作用于仍停留在顶部区(y<WP_GROW)的子视图，
//     因此是幂等、可自愈的（系统每次重布局后都会重新平移）。
//
// 诊断日志优先写到 App Group（扩展与容器共享，便于远程读取），兜底 /var/mobile、tmp。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define WP_DOMAIN @"com.yzdmm.wetypeplus"
#define WP_NOTE   CFSTR("com.yzdmm.wetypeplus.changed")
#define WP_GROW   36   // 工具栏行高，键盘整体向上撑高的值

static BOOL wp_enabled = YES;
static BOOL wp_haptic  = YES;

// ---------------- 日志 ----------------
static NSString *g_wpLogPath = nil;

static NSString *wp_resolveLogPath() {
    if (g_wpLogPath) return g_wpLogPath;
    NSMutableArray *cands = [NSMutableArray array];
    // 1) App Group（扩展与容器共享，frida 探得 group.com.tencent.wetype）：
    //    扩展能写、容器 frida 能读，便于远程诊断。
    id fm = [NSFileManager defaultManager];
    if (fm) {
        id url = [fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.tencent.wetype"];
        if (url) [cands addObject:[[url path] stringByAppendingPathComponent:@"wp_wp.log"]];
    }
    // 2) /var/mobile
    [cands addObject:@"/var/mobile/wp_wp.log"];
    // 3) 进程私有临时目录
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length) [cands addObject:[tmp stringByAppendingPathComponent:@"wp_wp.log"]];
    // 4) /tmp
    [cands addObject:@"/tmp/wp_wp.log"];
    for (NSString *f in cands) {
        if ([@"probe\n" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            [[NSData data] writeToFile:f atomically:YES]; // 清空
            g_wpLogPath = f;
            return f;
        }
    }
    g_wpLogPath = cands.firstObject;
    return g_wpLogPath;
}

static void wp_log(NSString *line) {
    NSLog(@"[WetypePlus] %@", line); // syslog 兜底
    NSString *file = wp_resolveLogPath();
    NSString *stamp = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    NSString *cur = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] ?: @"";
    if (cur.length > 20000) cur = [cur substringFromIndex:cur.length - 10000];
    [[cur stringByAppendingString:stamp] writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

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
- (void)buildIfNeeded;
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
    self = [super initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, WP_GROW)];
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

- (void)onTap:(UIButton *)b {
    wp_hapticBump();
    // 工具栏挂在 UIInputView 上，不直接持有 vc。从键盘窗口的响应链里找 UIInputViewController，
    // 取其 textDocumentProxy 操作光标/文本。
    id proxy = nil;
    NSArray *wins = [UIApplication sharedApplication].windows;
    for (UIWindow *w in wins) {
        UIResponder *r = w.rootViewController;
        while (r) {
            if ([r isKindOfClass:[UIInputViewController class]]) {
                proxy = [(UIInputViewController *)r textDocumentProxy];
                break;
            }
            r = [r nextResponder];
        }
        if (proxy) break;
    }
    if (!proxy) {
        // 退化：直接遍历所有响应者
        UIResponder *r = [UIApplication sharedApplication];
        while (r) {
            if ([r isKindOfClass:[UIInputViewController class]]) {
                proxy = [(UIInputViewController *)r textDocumentProxy];
                break;
            }
            r = [r nextResponder];
        }
    }
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

// ---------------- hook 系统键盘视图：向上撑高，工具栏钉顶 ----------------
%hook UIInputView

- (void)setFrame:(CGRect)f {
    // 本 dylib 只注入微信输入法键盘进程(wxkb_plugin)，这里的 UIInputView 即微信键盘。
    // 向上撑高 WP_GROW（高度+WP_GROW，y-WP_GROW），底部不变、顶部上移腾出一行。
    f.size.height += WP_GROW;
    f.origin.y    -= WP_GROW;
    %orig(f);
}

- (void)layoutSubviews {
    %orig;
    if (!wp_enabled) return;
    WPToolbar *tb = [WPToolbar shared];
    [tb buildIfNeeded];

    BOOL foundWB = NO;
    for (UIView *sv in self.subviews) {
        NSString *cn = NSStringFromClass(sv.class);
        if ([cn rangeOfString:@"WB"].location != NSNotFound ||
            [cn rangeOfString:@"Wetype"].location != NSNotFound) { foundWB = YES; break; }
    }
    if (!foundWB) return; // 不是微信键盘视图，不动

    // 把仍停留在顶部区(y < WP_GROW)的直接子视图整体下移 WP_GROW，
    // 给顶部腾出一行给工具栏；已下移过的(y>=WP_GROW)不再动，幂等自愈。
    CGRect vf = self.bounds;
    for (UIView *sv in self.subviews) {
        if (sv == tb) continue;
        CGRect f = sv.frame;
        if (f.origin.y < WP_GROW) {
            f.origin.y += WP_GROW;
            sv.frame = f;
        }
    }
    // 工具栏钉到顶部 (0,0,W,WP_GROW)
    if (tb.superview != self) [self addSubview:tb];
    [self bringSubviewToFront:tb];
    CGRect tbFrame = CGRectMake(0, 0, vf.size.width, WP_GROW);
    if (!CGRectEqualToRect(tb.frame, tbFrame)) {
        tb.frame = tbFrame;
        tb.hidden = NO;
    }
    tb.hidden = NO;

    static BOOL sFirst = YES;
    if (sFirst) {
        sFirst = NO;
        NSMutableString *tree = [NSMutableString string];
        wp_dumpTree(self, 0, tree);
        wp_log([NSString stringWithFormat:
                @"[kb] FIRST UIInputView bounds={%.1f,%.1f,%.1f,%.1f} subviews=%lu\n%@",
                vf.origin.x, vf.origin.y, vf.size.width, vf.size.height,
                (unsigned long)self.subviews.count, tree]);
        wp_log([NSString stringWithFormat:
                @"[kb] APPLIED toolbar at top band (0,0,%.1f,%.1f); candidate row shifted down by %d",
                vf.size.width, (float)WP_GROW, (int)WP_GROW]);
    }
}

%end

%hook UIInputViewController

- (void)viewDidLoad {
    %orig;
    if (!wp_enabled) return;
    [[WPToolbar shared] buildIfNeeded]; // 确保工具栏已构建（实际挂载在 UIInputView 里）
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!wp_enabled) return;
    // 仅记录；真正的布局在 UIInputView 的 layoutSubviews 里完成
    static BOOL sFirst = YES;
    if (sFirst) {
        sFirst = NO;
        wp_log([NSString stringWithFormat:
                @"[vc] FIRST vc=%@ view=%@",
                NSStringFromClass(self.class),
                self.view ? NSStringFromClass(self.view.class) : @"nil"]);
    }
}

%end

%ctor {
    @autoreleasepool {
        wp_loadPrefs();
        wp_resolveLogPath();
        wp_log([NSString stringWithFormat:
                @"[ctor] WetypePlus 3.0.6 loaded | process=%@ bundle=%@ logPath=%@",
                ([[NSProcessInfo processInfo] processName] ?: @"?"),
                ([[NSBundle mainBundle] bundleIdentifier] ?: @"?"),
                wp_resolveLogPath()]);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)wp_notifyCallback,
            WP_NOTE, NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
}
