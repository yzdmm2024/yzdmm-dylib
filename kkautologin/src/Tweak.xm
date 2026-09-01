// KKGameAutoLogin.xm — 游戏授权页「秒验证」自动登录插件
// 方案（针对硬沙盒游戏，本插件实测可用的唯一稳定通道）：
//   账号密码优先从【游戏自己沙盒的 NSUserDefaults】(域键 KKAccount/KKPassword) 读取；
//   沙盒无记录时【回退到内置默认号 KK_DEF_*】，实现"下载即秒过、零登录"。
//   因为该游戏有完整沙盒，读不到任何外部偏好文件/外部偏好域/全局域，
//   所以不再依赖系统设置面板（它对这台沙盒游戏物理上不生效）。
//   玩家若想用自己的号：在游戏授权页手动填一次并提交 -> 脚本捕获回传原生，写入游戏沙盒，即覆盖默认号。
//   之后每次：进入授权页自动填号+提交，秒过。换号就在游戏里再手输一次覆盖。
// 注入方式：TrollFools / TweakInject / Relaxin 通用；纯 ObjC swizzle + dyld 镜像回调。
// 目标：com.hortor.mwdl.ios / com.hortor.yqzd，授权页 login.php

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKUserScript.h>
#import <WebKit/WKNavigation.h>
#import <WebKit/WKScriptMessage.h>

static NSString* KK_CAPTURE_HANDLER = @"kkLogin";   // 注入 JS 与原生回传的桥
static NSString* KK_NSUD_ACCOUNT   = @"KKAccount";
static NSString* KK_NSUD_PASSWORD  = @"KKPassword";

// 内置默认号（零登录兜底）：任一被注入且走同一登录站的游戏打开即用此号自动秒过。
// 玩家在游戏里手输自己的号提交后，会覆盖这些默认值（存进游戏本人沙盒）。
static NSString* const KK_DEF_ACCOUNT  = @"yzdmm2025";
static NSString* const KK_DEF_PASSWORD = @"yzdmm2025";

// 注入脚本模板（%1$@ 账号、%2$@ 密码均已转义，%3$@='1'=有凭据需自动登录）
// forMainFrameOnly=NO 覆盖子 iframe；MutationObserver+定时器兼容延迟渲染/SPA。
// 自动填号最多重试 5 次防死循环；提交时捕获字段值回传原生，让首次手输被记住。
static NSString* const KK_Auth_JS_Format =
    @"(function(){"
     "var USER='%1$@',PASS='%2$@',AUTO='%3$@';"
     "function isLogin(){return (location.pathname+location.search).indexOf('login.php')!==-1;}"
     "function setVal(el,val){"
       "try{var s=Object.getOwnPropertyDescriptor((el.tagName==='TEXTAREA'?HTMLTextAreaElement:HTMLInputElement).prototype,'value').set;s.call(el,val);}catch(e){el.value=val;}"
       "el.dispatchEvent(new Event('input',{bubbles:true}));"
       "el.dispatchEvent(new Event('change',{bubbles:true}));"
     "}"
     "function findU(){return document.getElementById('username')||document.querySelector('input[name=username],input[type=text][name=user],input[autocomplete=username],input[name=account],input[name=loginName],input[name=tel]');}"
     "function findP(){return document.getElementById('password')||document.querySelector('input[type=password],input[name=passwd],input[name=pwd]');}"
     "function capture(){"
       "try{"
       "if(!window.webkit||!window.webkit.messageHandlers||!window.webkit.messageHandlers.kkLogin)return;"
       "var u=findU(),p=findP();if(!u||!p)return;"
       "var au=(u.value||'').trim(),ap=(p.value||'');if(!au)return;"
       "window.webkit.messageHandlers.kkLogin.postMessage({account:au,password:ap});"
       "}catch(e){}"
     "}"
     "function fire(f){"
       "if(!f)return;"
       "var b=f.querySelector('button[type=submit],input[type=submit],.btn-login,button.login,#loginBtn,#btnLogin,#submit')"
          "||document.querySelector('button[type=submit],input[type=submit],.btn-login,button.login,#loginBtn,#btnLogin,#submit');"
       "if(b){try{b.click();return;}catch(e){}}"
       "try{f.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));return;}catch(e){}"
       "try{f.submit();return;}catch(e){}"
     "}"
     "function attach(){"
       "try{"
       "if(window.__kkCapDone)return;window.__kkCapDone=true;"
       "var u=findU();if(!u)return;"
       "var f=u.form||document.querySelector('form');"
       "if(f){f.addEventListener('submit',capture,false);f.addEventListener('click',function(){setTimeout(capture,400);},false);}"
       "var b=f?f.querySelector('button[type=submit],input[type=submit],.btn-login,button.login,#loginBtn,#btnLogin,#submit'):null;"
       "if(b){b.addEventListener('click',function(){setTimeout(capture,400);},false);}"
       "}catch(e){}"
     "}"
     "function go(){"
       "try{"
       "if(!isLogin())return;"
       "var u=findU(),p=findP();if(!u||!p)return;"
       "attach();"
       "if(AUTO=='1'&&!sessionStorage.getItem('kk_auto_done')){"
          "var n=parseInt(sessionStorage.getItem('kk_a')||'0',10);if(n>=5)return;sessionStorage.setItem('kk_a',String(n+1));"
          "setVal(u,USER);setVal(p,PASS);"
          "var r=document.getElementById('remember-me')||document.querySelector('input[name=remember],input[type=checkbox]');"
          "if(r&&!r.checked){r.checked=true;r.dispatchEvent(new Event('change',{bubbles:true}));}"
          "sessionStorage.setItem('kk_auto_done','1');"
          "fire(u.form||document.querySelector('form'));"
          "setTimeout(capture,500);"
       "}"
       "}catch(e){}"
     "}"
     "go();"
     "new MutationObserver(go).observe(document.documentElement||document.body,{childList:true,subtree:true,attributes:true});"
     "setInterval(go,300);"
     "window.addEventListener('pagehide',capture,false);"
     "})();";

// 转义，使任意用户输入都能安全嵌入单引号 JS 字符串
static NSString* KK_EscapeJS(NSString* s) {
    if (!s) return @"";
    NSMutableString* m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'" withString:@"\\'" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\r" withString:@"" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

#pragma mark - 凭据读写（优先游戏沙盒，空时回退内置默认号）
static NSString* KK_Account(void) {
    NSString* s = [[NSUserDefaults standardUserDefaults] stringForKey:KK_NSUD_ACCOUNT];
    return (s.length ? s : KK_DEF_ACCOUNT);
}
static NSString* KK_Password(void) {
    NSString* s = [[NSUserDefaults standardUserDefaults] stringForKey:KK_NSUD_PASSWORD];
    return (s.length ? s : KK_DEF_PASSWORD);
}
static BOOL KK_AutoEnabled(void) {
    // 未显式关闭时默认开启自动登录
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    id v = [ud objectForKey:@"KKAutoLoginEnabled"];
    return (v == nil) ? YES : [v boolValue];
}
static void KK_SaveCaptured(NSString* account, NSString* password) {
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    if (account.length) [ud setObject:account forKey:KK_NSUD_ACCOUNT];
    [ud setObject:(password ?: @"") forKey:KK_NSUD_PASSWORD];
    [ud synchronize];
    NSLog(@"[KKGameAutoLogin] captured & saved creds into game sandbox (account len=%lu)", (unsigned long)account.length);
}

#pragma mark - 原生桥（接收页面回传，记住首次手输）
@interface KKAuthBridge : NSObject <WKScriptMessageHandler>
@end
static KKAuthBridge* KK_SharedBridge(void) {
    static KKAuthBridge* b = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [[KKAuthBridge alloc] init]; });
    return b;
}
@implementation KKAuthBridge
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:KK_CAPTURE_HANDLER]) return;
    id body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString* acc = body[@"account"]; NSString* pw = body[@"password"];
    if (![acc isKindOfClass:[NSString class]]) acc = nil;
    if (![pw isKindOfClass:[NSString class]]) pw = @"";
    if (acc.length) KK_SaveCaptured(acc, pw);
}
@end

#pragma mark - 把脚本+消息桥装进 WebView 配置
static void KK_Auth_InjectInto(WKWebViewConfiguration* cfg) {
    if (!cfg || !cfg.userContentController) return;
    WKUserContentController* uc = cfg.userContentController;
    @try {
        [uc addScriptMessageHandler:KK_SharedBridge() name:KK_CAPTURE_HANDLER];
    } @catch (NSException* e) {
        // 重复添加会抛异常，忽略
    }
    NSString* user = KK_EscapeJS(KK_Account());
    NSString* pass = KK_EscapeJS(KK_Password());
    NSString* autoFlag = (KK_AutoEnabled() && user.length) ? @"1" : @"0";
    NSString* js = [NSString stringWithFormat:KK_Auth_JS_Format, user, pass, autoFlag];
    WKUserScript* script =
        [[WKUserScript alloc] initWithSource:js
                                injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                             forMainFrameOnly:NO];
    [uc addUserScript:script];
    NSLog(@"[KKGameAutoLogin] injected auto-login into WKWebView config (auto=%s)",
          autoFlag.boolValue ? "YES" : "NO");
}

#pragma mark - WKWebView 分类（钩子方法）
@interface WKWebView (KKGameAutoLogin)
- (instancetype)kkauth_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration*)configuration;
- (instancetype)kkauth_initWithCoder:(NSCoder*)coder;
@end

@implementation WKWebView (KKGameAutoLogin)

- (instancetype)kkauth_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration*)configuration {
    WKWebView* w = [self kkauth_initWithFrame:frame configuration:configuration];
    if (KK_AutoEnabled()) KK_Auth_InjectInto(configuration);
    return w;
}

- (instancetype)kkauth_initWithCoder:(NSCoder*)coder {
    WKWebView* w = [self kkauth_initWithCoder:coder];
    if (KK_AutoEnabled()) KK_Auth_InjectInto([self configuration]);
    return w;
}

@end

#pragma mark - dyld 回调式 swizzle
static void KK_Auth_DoSwizzle(void) {
    Class cls = NSClassFromString(@"WKWebView");
    if (!cls) return;
    static BOOL done = NO;
    if (done) return;
    Method m1 = class_getInstanceMethod(cls, @selector(initWithFrame:configuration:));
    Method s1 = class_getInstanceMethod(cls, @selector(kkauth_initWithFrame:configuration:));
    if (m1 && s1) method_exchangeImplementations(m1, s1);
    Method m2 = class_getInstanceMethod(cls, @selector(initWithCoder:));
    Method s2 = class_getInstanceMethod(cls, @selector(kkauth_initWithCoder:));
    if (m2 && s2) method_exchangeImplementations(m2, s2);
    done = YES;
    NSLog(@"[KKGameAutoLogin] WKWebView swizzled OK");
}

static void KK_Auth_ImageCallback(const struct mach_header* mh, intptr_t vmaddr_slide) {
    if (NSClassFromString(@"WKWebView")) KK_Auth_DoSwizzle();
}

%ctor {
    _dyld_register_func_for_add_image(KK_Auth_ImageCallback);
    KK_Auth_DoSwizzle();
    NSLog(@"[KKGameAutoLogin] dylib loaded. creds are stored in the game's own sandbox NSUserDefaults (KKAccount/KKPassword).");
}