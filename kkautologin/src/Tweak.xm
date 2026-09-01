// KKGameAutoLogin.xm — 游戏授权页「秒验证」自动登录插件（账号密码由设置面板配置）
// 注入方式：TrollFools / TweakInject / Relaxin 通用。
//          纯 Objective-C 运行时 swizzle(method_exchangeImplementations) + dyld 镜像回调，
//          规避“dylib 加载早于 WebKit 导致 hook 不生效”的时机问题。
// 目标：com.hortor.mwdl.ios / com.hortor.yqzd，授权页 login.php
// 平台：arm64 / iOS16
// 凭据来源：NSUserDefaults suite=com.yzdmm.kkgameautologin（设置面板「游戏免登录」里配）
//          键：account / password / autoLoginEnabled。代码中不硬编码任何账号密码。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKUserScript.h>
#import <WebKit/WKNavigation.h>

static NSString* KK_PrefsSuite = @"com.yzdmm.kkgameautologin";

// 注入脚本模板：%1$@=用户名，%2$@=密码（构建 JS 时注入当前设置值）
// 只在 login.php 生效；填号 + 勾选记住 + 自动提交。
// forMainFrameOnly=NO 覆盖子 iframe；MutationObserver+定时器兼容延迟渲染/SPA。
// window 标志去重；sessionStorage 计数防失败无限重试(最多 5 次)。
static NSString* const KK_Auth_JS_Format =
    @"(function(){"
     "var USER='%1$@',PASS='%2$@';"
     "function isLogin(){return (location.pathname+location.search).indexOf('login.php')!==-1;}"
     "function setVal(el,val){"
       "try{var setter=Object.getOwnPropertyDescriptor((el.tagName==='TEXTAREA'?HTMLTextAreaElement:HTMLInputElement).prototype,'value').set;setter.call(el,val);}catch(e){el.value=val;}"
       "el.dispatchEvent(new Event('input',{bubbles:true}));"
       "el.dispatchEvent(new Event('change',{bubbles:true}));"
     "}"
     "function fire(f){"
       "if(!f)return;"
       "var btn=f.querySelector('button[type=submit],input[type=submit],.btn-login,button.login,#loginBtn,#btnLogin,#submit')"
           "||document.querySelector('button[type=submit],input[type=submit],.btn-login,button.login,#loginBtn,#btnLogin,#submit');"
       "if(btn){try{btn.click();return;}catch(e){}}"
       "try{f.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));return;}catch(e){}"
       "try{f.submit();return;}catch(e){}"
     "}"
     "function go(){"
       "try{"
       "if(!isLogin())return;"
       "var u=document.getElementById('username')||document.querySelector('input[name=username],input[type=text][name=user],input[autocomplete=username],input[name=account],input[name=loginName],input[name=tel]');"
       "var p=document.getElementById('password')||document.querySelector('input[type=password],input[name=passwd],input[name=pwd]');"
       "if(!u||!p)return;"
       "if(!USER&&!PASS){document.title='KK:no-cred';return;}"
       "var n=parseInt(sessionStorage.getItem('kk_a')||'0',10);"
       "if(n>=5)return;"
       "sessionStorage.setItem('kk_a',String(n+1));"
       "setVal(u,USER);setVal(p,PASS);"
       "var r=document.getElementById('remember-me')||document.querySelector('input[name=remember],input[type=checkbox]');"
       "if(r&&!r.checked){r.checked=true;r.dispatchEvent(new Event('change',{bubbles:true}));}"
       "fire(u.form||document.querySelector('form'));"
       "}catch(e){}"
     "}"
     "go();"
     "new MutationObserver(go).observe(document.documentElement||document.body,{childList:true,subtree:true,attributes:true});"
     "setInterval(go,300);"
     "})();";

// 转义，使任意用户输入都能嵌入单引号字符串
static NSString* KK_EscapeJS(NSString* s) {
    if (!s) return @"";
    NSMutableString* m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'" withString:@"\\'" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\r" withString:@"" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

// 候选偏好文件路径：设置面板会把配置写入这些位置（roothide 也兼容）
static NSArray* KK_PrefPaths(void) {
    return @[
        @"/var/mobile/Library/Preferences/com.yzdmm.kkgameautologin.plist",
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.kkgameautologin.plist",
        [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Preferences/com.yzdmm.kkgameautologin.plist"],
    ];
}
static NSDictionary* KK_ReadFileDict(void) {
    for (NSString* p in KK_PrefPaths()) {
        NSDictionary* d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d && d.count > 0) return d;
    }
    return nil;
}
static NSString* KK_ReadPref(NSString* key) {
    NSDictionary* d = KK_ReadFileDict();
    id v = d ? [d objectForKey:key] : nil;
    if (v) return [[NSString stringWithFormat:@"%@", v] copy];
    // 回退：NSUserDefaults suite（兼容无跨进程隔离的注入方式）
    NSUserDefaults* ud = [[NSUserDefaults alloc] initWithSuiteName:KK_PrefsSuite];
    return [[ud stringForKey:key] ?: @"" copy];
}

static BOOL KK_AutoEnabled(void) {
    NSDictionary* d = KK_ReadFileDict();
    id v = d ? [d objectForKey:@"autoLoginEnabled"] : nil;
    if (v) return [v boolValue];
    NSUserDefaults* ud = [[NSUserDefaults alloc] initWithSuiteName:KK_PrefsSuite];
    id x = [ud objectForKey:@"autoLoginEnabled"];
    return (x == nil) ? YES : [x boolValue];
}

static void KK_Auth_InjectInto(WKWebViewConfiguration* cfg) {
    if (!cfg || !cfg.userContentController) return;
    NSString* user = KK_EscapeJS(KK_ReadPref(@"account"));
    NSString* pass = KK_EscapeJS(KK_ReadPref(@"password"));
    NSString* js = [NSString stringWithFormat:KK_Auth_JS_Format, user, pass];
    WKUserScript* script =
        [[WKUserScript alloc] initWithSource:js
                                injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                             forMainFrameOnly:NO];   // 覆盖子 iframe
    [cfg.userContentController addUserScript:script];
    NSLog(@"[KKGameAutoLogin] injected WKUserScript (autoLogin=%d) into a WKWebView config",
          KK_AutoEnabled());
}

#pragma mark - WKWebView 分类(钩子方法)
@interface WKWebView (KKGameAutoLogin)
- (instancetype)kkauth_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration*)configuration;
- (instancetype)kkauth_initWithCoder:(NSCoder*)coder;
@end

@implementation WKWebView (KKGameAutoLogin)

- (instancetype)kkauth_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration*)configuration {
    // 交换后此 selector 实际调用原始 initWithFrame:configuration:
    WKWebView* w = [self kkauth_initWithFrame:frame configuration:configuration];
    NSLog(@"[KKGameAutoLogin] WKWebView created frame=%.0fx%.0f", frame.size.width, frame.size.height);
    if (KK_AutoEnabled()) KK_Auth_InjectInto(configuration);
    return w;
}

- (instancetype)kkauth_initWithCoder:(NSCoder*)coder {
    WKWebView* w = [self kkauth_initWithCoder:coder];
    if (KK_AutoEnabled()) KK_Auth_InjectInto([self configuration]);
    return w;
}

@end

#pragma mark - dyld 回调式 swizzle(解决 dylib 早于 WebKit 加载导致没 hook 上)
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
    NSLog(@"[KKGameAutoLogin] WKWebView swizzled OK (initWithFrame / initWithCoder)");
}

static void KK_Auth_ImageCallback(const struct mach_header* mh, intptr_t vmaddr_slide) {
    // 每当新镜像加载，若此时已有 WKWebView 类，立即补一次 swizzle
    if (NSClassFromString(@"WKWebView")) KK_Auth_DoSwizzle();
}

%ctor {
    _dyld_register_func_for_add_image(KK_Auth_ImageCallback);
    KK_Auth_DoSwizzle();
    NSLog(@"[KKGameAutoLogin] dylib loaded. creds come from settings panel(com.yzdmm.kkgameautologin).");
}