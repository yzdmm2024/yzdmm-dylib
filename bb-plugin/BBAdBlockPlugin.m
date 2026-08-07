//
//  BBAdBlockPlugin.m
//  内部专用工具插件（通用 iOS hook，干净实现，不依赖任何第三方二进制）：
//   1. 广告加速  (adSpeedEnabled)         —— 通用 hook：把 AVPlayer 播放速率调高
//   2. 防止跳转浏览器 (blockBrowserEnabled) —— 通用 hook：拦截 UIApplication openURL:
//
//  运行方式：纯 Objective-C runtime 方法交换，不依赖 Cydia Substrate / ElleKit，
//  因此【非越狱自签注入】也能工作（把本 dylib 注入目标 App 并重签即可）。
//
//  两个开关默认关闭，App 内悬浮窗手动开启，运行时即时生效（无需重启）。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - 配置（NSUserDefaults，默认关闭，运行时即时读取）

static NSString *const kBBAdSpeedKey       = @"BB_adSpeedEnabled";
static NSString *const kBBBlockBrowserKey  = @"BB_blockBrowserEnabled";

// 广告加速倍速：把视频广告按此倍速播放（30 秒广告 ≈ 30/倍速 秒看完）
static const float kBBAdSpeedRate = 16.0f;

static BOOL bbAdSpeedEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kBBAdSpeedKey];
}
static BOOL bbBlockBrowserEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kBBBlockBrowserKey];
}
static void bbSetAdSpeed(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kBBAdSpeedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
static void bbSetBlockBrowser(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kBBBlockBrowserKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 方法交换工具

static void bb_swizzle(Class cls, SEL orig, SEL repl) {
    if (!cls) return;
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

#pragma mark - 防止跳转浏览器：hook UIApplication openURL: 系列

@implementation UIApplication (BBBlockBrowser)

- (void)bb_openURL:(NSURL *)url
           options:(NSDictionary<NSString *, id> *)options
 completionHandler:(void (^)(BOOL))completion {

    if (bbBlockBrowserEnabled() && url) {
        // 拦截：不调用原实现，直接回调“打开失败”
        if (completion) completion(NO);
        return;
    }
    [self bb_openURL:url options:options completionHandler:completion];
}

- (void)bb_openURL:(NSURL *)url
           options:(NSDictionary<NSString *, id> *)options {
    if (bbBlockBrowserEnabled() && url) return;
    [self bb_openURL:url options:options];
}

- (BOOL)bb_openURLSimple:(NSURL *)url {
    if (bbBlockBrowserEnabled() && url) return NO;
    return [self bb_openURLSimple:url];
}

@end

#pragma mark - 广告加速：hook AVPlayer 播放速率

@implementation AVPlayer (BBAdSpeed)

- (void)bb_play {
    [self bb_play];
    if (bbAdSpeedEnabled()) {
        // play 之后稍等一帧再设倍速，确保 player 已处于可播放状态
        [self performSelector:@selector(bb_applyRate) withObject:nil afterDelay:0.05];
    }
}

- (void)bb_playImmediatelyAtRate:(float)rate {
    float r = bbAdSpeedEnabled() ? kBBAdSpeedRate : rate;
    [self bb_playImmediatelyAtRate:r];
}

- (void)bb_applyRate {
    if (bbAdSpeedEnabled()) {
        @try { self.rate = kBBAdSpeedRate; } @catch (...) {}
    }
}

@end

#pragma mark - App 内悬浮窗（两个开关，默认关闭，可拖拽）

@interface BBFloatingPanel : NSObject
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView   *panel;
@property (nonatomic, assign) BOOL      dragging;
@property (nonatomic, assign) CGPoint   dragOffset;
+ (instancetype)shared;
@end

@implementation BBFloatingPanel

+ (instancetype)shared {
    static BBFloatingPanel *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[BBFloatingPanel alloc] init]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        [self buildFab];
        [self buildPanel];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(attachToKeyWindow)
            name:UIWindowDidBecomeKeyNotification object:nil];
        [self performSelector:@selector(attachToKeyWindow) withObject:nil afterDelay:0.5];
    }
    return self;
}

- (UIWindow *)keyWindow {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) return w;
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (void)attachToKeyWindow {
    UIWindow *kw = [self keyWindow];
    if (!kw) return;
    if (self.fab.superview != kw) [kw addSubview:self.fab];
    if (self.panel.superview != kw) [kw addSubview:self.panel];
    [kw bringSubviewToFront:self.fab];
    [kw bringSubviewToFront:self.panel];
    [self restoreFabPosition];
}

- (void)buildFab {
    _fab = [UIButton buttonWithType:UIButtonTypeCustom];
    _fab.frame = CGRectMake(0, 0, 56, 56);
    _fab.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:0.85];
    _fab.layer.cornerRadius = 28;
    _fab.layer.masksToBounds = YES;
    _fab.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_fab setTitle:@"BB" forState:UIControlStateNormal];
    [_fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_fab addTarget:self action:@selector(fabTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fabPanned:)];
    [_fab addGestureRecognizer:pan];
}

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 240, 168)];
    _panel.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.16 alpha:0.96];
    _panel.layer.cornerRadius = 14;
    _panel.layer.masksToBounds = YES;
    _panel.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, 212, 22)];
    title.text = @"内部专用";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [_panel addSubview:title];

    [_panel addSubview:[self rowWithY:48 title:@"广告加速"        key:kBBAdSpeedKey       initial:bbAdSpeedEnabled()       action:@selector(adSpeedChanged:)]];
    [_panel addSubview:[self rowWithY:96 title:@"防止跳转浏览器"  key:kBBBlockBrowserKey  initial:bbBlockBrowserEnabled()  action:@selector(blockChanged:)]];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(200, 12, 28, 22);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(fabTapped) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:close];
}

- (UIView *)rowWithY:(CGFloat)y title:(NSString *)title key:(NSString *)key initial:(BOOL)initial action:(SEL)action {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, 240, 44)];
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 160, 44)];
    lab.text = title;
    lab.textColor = [UIColor whiteColor];
    lab.font = [UIFont systemFontOfSize:15];
    [row addSubview:lab];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(176, 6, 51, 31)];
    sw.on = initial;
    sw.tag = (key == kBBAdSpeedKey) ? 1 : 2;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
    return row;
}

- (void)adSpeedChanged:(UISwitch *)sw { bbSetAdSpeed(sw.on); }
- (void)blockChanged:(UISwitch *)sw  { bbSetBlockBrowser(sw.on); }

- (void)fabTapped {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) [self positionPanelNearFab];
}

- (void)fabPanned:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        self.dragOffset = [g locationInView:self.fab];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [g locationInView:[self keyWindow]];
        CGRect f = self.fab.frame;
        f.origin.x = p.x - self.dragOffset.x;
        f.origin.y = p.y - self.dragOffset.y;
        self.fab.frame = f;
    } else if (g.state == UIGestureRecognizerStateEnded) {
        self.dragging = NO;
        [self restoreFabPosition];
        if (!self.panel.hidden) [self positionPanelNearFab];
    }
}

- (void)restoreFabPosition {
    UIWindow *kw = [self keyWindow];
    CGFloat W = kw.bounds.size.width, H = kw.bounds.size.height;
    CGRect f = self.fab.frame;
    f.origin.x = MAX(8, MIN(f.origin.x, W - f.size.width - 8));
    f.origin.y = MAX(60, MIN(f.origin.y, H - f.size.height - 8));
    self.fab.frame = f;
}

- (void)positionPanelNearFab {
    UIWindow *kw = [self keyWindow];
    CGFloat W = kw.bounds.size.width;
    CGRect pf = self.panel.frame;
    CGRect ff = self.fab.frame;
    CGFloat x = ff.origin.x + ff.size.width/2 - pf.size.width/2;
    x = MAX(8, MIN(x, W - pf.size.width - 8));
    CGFloat y = ff.origin.y - pf.size.height - 8;
    if (y < 60) y = ff.origin.y + ff.size.height + 8;
    self.panel.frame = CGRectMake(x, y, pf.size.width, pf.size.height);
}

@end

#pragma mark - 入口：+load 时完成交换并弹出悬浮窗

@interface BBInternalPlugin : NSObject
@end

@implementation BBInternalPlugin

+ (void)load {
    @autoreleasepool {
        // 方法交换（不依赖 Substrate，非越狱可用）
        bb_swizzle([UIApplication class],
                   @selector(openURL:options:completionHandler:),
                   @selector(bb_openURL:options:completionHandler:));
        bb_swizzle([UIApplication class],
                   @selector(openURL:options:),
                   @selector(bb_openURL:options:));
        bb_swizzle([UIApplication class],
                   @selector(openURL:),
                   @selector(bb_openURLSimple:));
        bb_swizzle([AVPlayer class],
                   @selector(play),
                   @selector(bb_play));
        bb_swizzle([AVPlayer class],
                   @selector(playImmediatelyAtRate:),
                   @selector(bb_playImmediatelyAtRate:));

        // 延迟到主线程构建悬浮窗（启动时 keyWindow 可能尚未就绪）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [BBFloatingPanel shared];
        });
    }
}

@end
