//
//  BBAdBlockPlugin.m
//  内部专用工具插件（通用 iOS hook，干净实现，不依赖任何第三方二进制）：
//   1. 广告加速       (adSpeedEnabled)   —— 开启时同时做三件事：
//                                             ① 视频广告倍速播放
//                                             ② 自动跳过开屏广告（点掉「跳过」按钮 / 移除全屏广告视图）
//                                             ③ 拦截常见广告 SDK 域名
//   2. 防止跳转浏览器 (blockBrowserEnabled) —— 拦截 UIApplication openURL: 系列，阻止跳出到浏览器
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

static NSString *const kBBAdSpeedKey       = @"BB_adSpeedEnabled";       // 广告加速（含开屏跳过 + 域名拦截）
static NSString *const kBBBlockBrowserKey  = @"BB_blockBrowserEnabled";  // 防止跳转浏览器

// 广告加速倍速：把视频广告按此倍速播放（30 秒广告 ≈ 30/倍速 秒看完）
static const float kBBAdSpeedRate = 16.0f;

// 广告 SDK 域名黑名单（用于「广告加速」开关开启时的域名拦截，借鉴公开去广告域名清单）
static NSArray<NSString *> *kBBAdDomains(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            // 快手 / 快手广告
            @"open.kuaishouzt.com", @"adkwai.com", @"adukwai.com",
            @"wlog.kuaishou.com", @"e.kuaishou.cn", @"e.kuaishou.com",
            @"gdfp.gifshow.com", @"yximgs.com", @"gepush.com",
            // 穿山甲 / 巨量引擎
            @"pangolin-sdk-toutiao.com", @"pangolin-sdk-toutiao-b.com",
            @"pangolin-sdk-toutiao1.com", @"pglstatp-toutiao.com",
            @"api-access.pangolin-sdk-toutiao.com", @"csjplatform.com",
            // 字节系
            @"ad.zijieapi.com", @"mon.zijieapi.com", @"mcs.zijieapi.com",
            @"ads3-normal-lq.zijieapi.com", @"ads5-normal-lq.zijieapi.com",
            @"ads5-normal-lf.zijieapi.com",
            // 百度
            @"mobads.baidu.com",
            // 腾讯广点通
            @"e.qq.com", @"gdt.qq.com", @"m.qq.com",
            // 谷歌广告
            @"googleads.g.doubleclick-cn.net", @"fundingchoicesmessages.google.com",
            // 个推
            @"getui.net", @"getui.com", @"getui.cn",
            // 友盟
            @"umeng.com", @"umengcloud.com", @"app-measurement.com",
            // 其他常见广告 SDK
            @"sigmob.com", @"sigmob.cn", @"anythinktech.com", @"tradplusad.com",
            @"admobile.top", @"sdk.tianmu.mobi", @"beizi.biz", @"hubcloud.com.cn",
            @"ad-scope.com.cn", @"ad-scope.com", @"telecome.cn",
            @"shouji.sogou.com", @"ctobsnssdk.com"
        ];
    });
    return list;
}

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

// 判断 URL 是否命中广告域名（仅当「广告加速」开启时生效）
static BOOL bbIsAdDomain(NSURL *url) {
    NSString *host = [url.host lowercaseString];
    if (!host.length) return NO;
    for (NSString *d in kBBAdDomains()) {
        if ([host isEqualToString:d] || [host hasSuffix:[@"." stringByAppendingString:d]]) return YES;
    }
    return NO;
}

#pragma mark - 方法交换工具

static void bb_swizzle(Class cls, SEL orig, SEL repl) {
    if (!cls) return;
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

#pragma mark - 防止跳转浏览器 / 拦截广告域名：hook UIApplication openURL: 系列

@implementation UIApplication (BBBlock)

- (void)bb_openURL:(NSURL *)url
           options:(NSDictionary<NSString *, id> *)options
 completionHandler:(void (^)(BOOL))completion {

    if (bbBlockBrowserEnabled()) {                       // 防跳转：拦截一切跳转
        if (completion) completion(NO);
        return;
    }
    if (bbAdSpeedEnabled() && bbIsAdDomain(url)) {       // 广告加速开启时，拦截广告域名
        if (completion) completion(NO);
        return;
    }
    [self bb_openURL:url options:options completionHandler:completion];
}

- (void)bb_openURL:(NSURL *)url
           options:(NSDictionary<NSString *, id> *)options {
    if (bbBlockBrowserEnabled()) return;
    if (bbAdSpeedEnabled() && bbIsAdDomain(url)) return;
    [self bb_openURL:url options:options];
}

- (BOOL)bb_openURLSimple:(NSURL *)url {
    if (bbBlockBrowserEnabled()) return NO;
    if (bbAdSpeedEnabled() && bbIsAdDomain(url)) return NO;
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
        [self startSplashTimer];   // 开屏广告自动跳过（运行时按开关生效）
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
    _fab.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [_fab setTitle:@"内" forState:UIControlStateNormal];
    [_fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_fab addTarget:self action:@selector(fabTapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(fabPanned:)];
    [_fab addGestureRecognizer:pan];
}

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 240, 156)];
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

- (void)adSpeedChanged:(UISwitch *)sw     { bbSetAdSpeed(sw.on); }
- (void)blockChanged:(UISwitch *)sw       { bbSetBlockBrowser(sw.on); }

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

#pragma mark - 跳过开屏广告：定时扫描 keyWindow，点掉「跳过」按钮、移除全屏广告视图
// 仅当「广告加速」开启时生效（并入广告加速开关）

- (void)startSplashTimer {
    [NSTimer scheduledTimerWithTimeInterval:0.5
                                     target:self
                                   selector:@selector(bb_splashTick:)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)bb_splashTick:(NSTimer *)timer {
    if (bbAdSpeedEnabled()) [self bb_scanSplash];
}

- (void)bb_scanSplash {
    UIWindow *kw = [self keyWindow];
    if (!kw) return;
    [self bb_killAdsIn:kw];
}

- (void)bb_killAdsIn:(UIView *)view {
    if (!view) return;
    // 复制一份，遍历时可能会被移除
    for (UIView *sub in [view.subviews copy]) {
        // 1) 自动点击「跳过 / Skip」按钮
        if ([sub isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)sub;
            NSString *t = [btn titleForState:UIControlStateNormal];
            if (t.length &&
                ([t containsString:@"跳过"] || [t containsString:@"Skip"] || [t containsString:@"skip"])) {
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        }
        // 2) 移除全屏广告视图（类名含关键词）
        NSString *cls = NSStringFromClass([sub class]);
        BOOL adish = ([cls containsString:@"Ad"] || [cls containsString:@"Splash"] ||
                      [cls containsString:@"Launch"] || [cls containsString:@"Banner"] ||
                      [cls containsString:@"SplashAd"] || [cls containsString:@"LaunchAd"]);
        if (adish) {
            CGSize s = [UIScreen mainScreen].bounds.size;
            if (sub.frame.size.width >= s.width * 0.8 &&
                sub.frame.size.height >= s.height * 0.8) {
                [sub setHidden:YES];
                [sub removeFromSuperview];
            }
        }
        [self bb_killAdsIn:sub];
    }
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
