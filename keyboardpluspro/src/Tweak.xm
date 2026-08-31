// KeyboardPlusPro.xm - iOS 16 原生键盘增强 Tweak
#import "kb_private.h"
// 目标：iPhone 12 Pro / iOS 16.6.1 / Relaxin (rootless, ElleKit TweakInject)
// 工具链：theos (macos-14 原生 clang/ld) → 真 FAT arm64+arm64e，见 yzdmm-dylib build-kbp.yml
//
// 功能模块：
//   1. 增强光标 & 文本选择 (4 方向移动、滑动选词、点击空白定位)
//   2. 剪贴板历史面板 (全局监听、固定条目、条数限制)
//   3. 自定义符号栏 (顶部常驻栏、快捷文本模板)
//   4. 键盘布局 & 尺寸自定义 (高度、按键大小、间距、单手模式)
//   5. 手势操作 (滑动退格整词、撤销删除、上滑符号)
//   6. CapsLock 真正大写锁定 (双击 shift 永久锁定)
//   7. 键盘主题引擎 (圆角、透明度、背景色、按键颜色)
//   8. 触觉反馈精细调节 (每按键强度可调)
//   9. 快捷动作按键 (全选/复制/剪切/粘贴/撤销/重做)
//  10. 输入增强 (长按句号省略号、网址后缀快速输入)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

// ============================================================================
// UIButton + ActionName (关联对象)
// ============================================================================
@interface UIButton (KBActionName)
@property (nonatomic, strong) NSString *actionName;
@end

@implementation UIButton (KBActionName)

- (NSString *)actionName {
    return objc_getAssociatedObject(self, @selector(actionName));
}

- (void)setActionName:(NSString *)actionName {
    objc_setAssociatedObject(self, @selector(actionName), actionName, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

// ============================================================================
// 通用定义 & 配置
// ============================================================================
#define KB_VERSION @"1.0.0"
#define KB_PREFS_PATH "/var/mobile/Library/Preferences/com.yzdmm.keyboardpluspro.plist"
#define KB_CLIPBOARD_FILE "/var/mobile/Library/KeyboardPlusPro/clipboard.plist"
#define KB_CLIPBOARD_MAX_DEFAULT 50
#define KB_SYMBOL_BAR_HEIGHT 40.0

typedef NS_ENUM(NSInteger, KBCursorDirection) {
    KBCursorDirectionLeft  = 0,
    KBCursorDirectionRight = 1,
    KBCursorDirectionUp    = 2,
    KBCursorDirectionDown  = 3,
};

typedef NS_ENUM(NSInteger, KBGestureType) {
    KBGestureTypeNone           = 0,
    KBGestureTypeSwipeLeftDeleteWord = 1,
    KBGestureTypeSwipeRightUndoDelete = 2,
    KBGestureTypeSwipeUpSymbol  = 3,
};

// ============================================================================
// 偏好设置管理
// ============================================================================
@interface KBPreferences : NSObject
+ (instancetype)shared;
- (id)objectForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)setObject:(id)obj forKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)defaultValue;
- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)defaultValue;
- (void)synchronize;
@end

static KBPreferences *g_KBPrefs = nil;

@implementation KBPreferences
{
    NSMutableDictionary *_cache;
    BOOL _dirty;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_KBPrefs = [[self alloc] init];
    });
    return g_KBPrefs;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSMutableDictionary dictionary];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:@KB_PREFS_PATH];
        if (dict) [_cache addEntriesFromDictionary:dict];
        // 注册默认值
        NSDictionary *defaults = @{
            @"cursorEnabled": @YES,
            @"cursorSensitivity": @1.0,
            @"cursorFourDirection": @YES,
            @"clipboardEnabled": @YES,
            @"clipboardMaxCount": @(KB_CLIPBOARD_MAX_DEFAULT),
            @"symbolBarEnabled": @YES,
            @"symbolBarCustom": @",.?!@#$/:-_()[]{}'\"",
            @"layoutHeightRatio": @1.0,
            @"layoutKeyGap": @0.0,
            @"layoutKeySizeRatio": @1.0,
            @"layoutOneHandMode": @NO,
            @"layoutOneHandOffset": @0.0f,
            @"gestureSwipeLeftDeleteWord": @YES,
            @"gestureSwipeRightUndo": @YES,
            @"gestureSwipeUpSymbol": @YES,
            @"capsLockDoubleTap": @YES,
            @"themeEnabled": @NO,
            @"themeKeyRadius": @5.0,
            @"themeKeyAlpha": @1.0,
            @"themeKeyBgColor": @"",
            @"themeKeyTextColor": @"",
            @"themeKeyboardAlpha": @1.0,
            @"hapticEnabled": @YES,
            @"hapticIntensity": @0.5,
            @"hapticPerKeyCustom": @NO,
            @"actionBarEnabled": @YES,
            @"actionButtons": @"selectAll,copy,cut,paste,undo,redo",
            @"inputQuickEllipsis": @YES,
            @"inputUrlSuffix": @YES,
            @"autoNumberPadForPassword": @YES,
            @"disableAutoCapitalize": @NO,
            @"disableAutoPeriod": @NO,
        };
        for (NSString *key in defaults) {
            if (_cache[key] == nil) _cache[key] = defaults[key];
        }
    }
    return self;
}

- (id)objectForKey:(NSString *)key defaultValue:(id)defaultValue {
    id val = _cache[key];
    return val ?: defaultValue;
}

- (void)setObject:(id)obj forKey:(NSString *)key {
    if (obj) _cache[key] = obj;
    else [_cache removeObjectForKey:key];
    _dirty = YES;
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id val = _cache[key];
    if ([val isKindOfClass:[NSNumber class]]) return [val boolValue];
    return defaultValue;
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    _cache[key] = @(value);
    _dirty = YES;
}

- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)defaultValue {
    id val = _cache[key];
    if ([val isKindOfClass:[NSNumber class]]) return [val floatValue];
    return defaultValue;
}

- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)defaultValue {
    id val = _cache[key];
    if ([val isKindOfClass:[NSNumber class]]) return [val integerValue];
    return defaultValue;
}

- (void)synchronize {
    if (_dirty) {
        [_cache writeToFile:@KB_PREFS_PATH atomically:YES];
        _dirty = NO;
    }
}

@end

// ============================================================================
// 工具方法
// ============================================================================
@interface KBUtils : NSObject
+ (UIResponder<UITextInput> *)currentTextInput;
+ (id)keyboardImpl;
+ (void)triggerHapticWithIntensity:(CGFloat)intensity;
+ (BOOL)isPasswordField;
+ (NSString *)applicationBundleID;
@end

@implementation KBUtils

+ (UIResponder<UITextInput> *)currentTextInput {
    // 通过 UIKeyboardImpl 获取当前活跃的 text input
    id impl = [self keyboardImpl];
    if (!impl) return nil;
    // 尝试获取 input delegate 或 text document
    if ([impl respondsToSelector:@selector(inputDelegate)]) {
        id delegate = [impl performSelector:@selector(inputDelegate)];
        if ([delegate conformsToProtocol:@protocol(UITextInput)]) return delegate;
    }
    if ([impl respondsToSelector:@selector(textDocumentProxy)]) {
        id proxy = [impl performSelector:@selector(textDocumentProxy)];
        if ([proxy conformsToProtocol:@protocol(UITextInput)]) return proxy;
    }
    return nil;
}

+ (id)keyboardImpl {
    // UIKeyboardImpl 是单例，通过 +sharedInstance 或 +activeInstance 获取
    Class cls = NSClassFromString(@"UIKeyboardImpl");
    if (!cls) return nil;
    if ([cls respondsToSelector:@selector(activeInstance)]) {
        return [cls performSelector:@selector(activeInstance)];
    }
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        return [cls performSelector:@selector(sharedInstance)];
    }
    return nil;
}

+ (void)triggerHapticWithIntensity:(CGFloat)intensity {
    // 根据强度触发触觉反馈
    if (![[KBPreferences shared] boolForKey:@"hapticEnabled" defaultValue:YES]) return;
    CGFloat storedIntensity = [[KBPreferences shared] floatForKey:@"hapticIntensity" defaultValue:0.5];
    CGFloat finalIntensity = intensity * storedIntensity;
    // 使用 UIImpactFeedbackGenerator 或 UISelectionFeedbackGenerator
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen prepare];
    // 通过延迟变相模拟强度，iOS 原生不支持直接调强度
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(finalIntensity * 0.01 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [gen impactOccurred];
    });
}

+ (BOOL)isPasswordField {
    // 检查当前输入框是否为密码框
    UIResponder *firstResponder = nil;
    UIResponder *current = [UIApplication sharedApplication].keyWindow;
    if ([current respondsToSelector:@selector(firstResponder)]) {
        // 安全方式获取 first responder
    }
    id textInput = [self currentTextInput];
    if (!textInput) return NO;
    if ([textInput respondsToSelector:@selector(secureTextEntry)]) {
        return [[textInput performSelector:@selector(secureTextEntry)] boolValue];
    }
    // 检查 UITextInputTraits
    if ([textInput respondsToSelector:@selector(isSecureTextEntry)]) {
        return [textInput isSecureTextEntry];
    }
    return NO;
}

+ (NSString *)applicationBundleID {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
}

@end

// ============================================================================
// 模块1：增强光标 & 文本选择
// ============================================================================
@interface KBEnhancedCursorManager : NSObject
+ (instancetype)shared;
- (void)moveCursor:(KBCursorDirection)direction;
- (void)moveCursorByAmount:(NSInteger)amount direction:(KBCursorDirection)direction;
- (void)selectTextWithDirection:(KBCursorDirection)direction;
- (void)handleSpaceBarDrag:(UIPanGestureRecognizer *)gesture;
- (void)handleTapBlankArea:(UITapGestureRecognizer *)gesture;
@end

@implementation KBEnhancedCursorManager
{
    CGPoint _spaceDragStart;
    BOOL _spaceDragActive;
    UIPanGestureRecognizer *_spacePanGesture;
    UITapGestureRecognizer *_blankTapGesture;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)moveCursor:(KBCursorDirection)direction {
    [self moveCursorByAmount:1 direction:direction];
}

- (void)moveCursorByAmount:(NSInteger)amount direction:(KBCursorDirection)direction {
    if (![[KBPreferences shared] boolForKey:@"cursorEnabled" defaultValue:YES]) return;
    id impl = [KBUtils keyboardImpl];
    if (!impl) return;
    // 获取 text input 并移动光标
    id textInput = [KBUtils currentTextInput];
    if (!textInput || ![textInput conformsToProtocol:@protocol(UITextInput)]) return;
    
    id<UITextInput> input = (id<UITextInput>)textInput;
    UITextPosition *pos = [input selectedTextRange].start;
    if (!pos) return;
    
    UITextPosition *newPos = nil;
    switch (direction) {
        case KBCursorDirectionLeft:
            newPos = [input positionFromPosition:pos offset:-amount];
            break;
        case KBCursorDirectionRight:
            newPos = [input positionFromPosition:pos offset:amount];
            break;
        case KBCursorDirectionUp:
            // 上移：先拿到当前行，找上一行同位置
            if ([input respondsToSelector:@selector(positionFromPosition:inDirection:offset:)]) {
                NSMethodSignature *sig = [(id)input methodSignatureForSelector:@selector(positionFromPosition:inDirection:offset:)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(positionFromPosition:inDirection:offset:)];
                [inv setTarget:input];
                [inv setArgument:&pos atIndex:2];
                UITextLayoutDirection dir = UITextLayoutDirectionUp;
                [inv setArgument:&dir atIndex:3];
                [inv setArgument:&amount atIndex:4];
                [inv invoke];
                UITextPosition *__unsafe_unretained tmp = nil;
                [inv getReturnValue:&tmp];
                newPos = tmp;
            }
            break;
        case KBCursorDirectionDown:
            if ([input respondsToSelector:@selector(positionFromPosition:inDirection:offset:)]) {
                NSMethodSignature *sig = [(id)input methodSignatureForSelector:@selector(positionFromPosition:inDirection:offset:)];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(positionFromPosition:inDirection:offset:)];
                [inv setTarget:input];
                [inv setArgument:&pos atIndex:2];
                UITextLayoutDirection dir = UITextLayoutDirectionDown;
                [inv setArgument:&dir atIndex:3];
                [inv setArgument:&amount atIndex:4];
                [inv invoke];
                UITextPosition *__unsafe_unretained tmp = nil;
                [inv getReturnValue:&tmp];
                newPos = tmp;
            }
            break;
    }
    if (newPos) {
        UITextRange *newRange = [input textRangeFromPosition:newPos toPosition:newPos];
        [input setSelectedTextRange:newRange];
    }
    [KBUtils triggerHapticWithIntensity:0.3];
}

- (void)selectTextWithDirection:(KBCursorDirection)direction {
    id impl = [KBUtils keyboardImpl];
    if (!impl) return;
    id textInput = [KBUtils currentTextInput];
    if (!textInput || ![textInput conformsToProtocol:@protocol(UITextInput)]) return;
    
    id<UITextInput> input = (id<UITextInput>)textInput;
    UITextRange *selectedRange = [input selectedTextRange];
    if (!selectedRange) return;
    
    UITextPosition *newEnd = nil;
    NSInteger offset = 1;
    switch (direction) {
        case KBCursorDirectionLeft:
            newEnd = [input positionFromPosition:selectedRange.start offset:-offset];
            if (newEnd) {
            UITextRange *newRange = [input textRangeFromPosition:newEnd toPosition:selectedRange.end];
            [input setSelectedTextRange:newRange];
            }
            break;
        case KBCursorDirectionRight:
            newEnd = [input positionFromPosition:selectedRange.end offset:offset];
            if (newEnd) {
            UITextRange *newRange = [input textRangeFromPosition:selectedRange.start toPosition:newEnd];
            [input setSelectedTextRange:newRange];
            }
            break;
        default:
            break;
    }
    [KBUtils triggerHapticWithIntensity:0.3];
}

- (void)handleSpaceBarDrag:(UIPanGestureRecognizer *)gesture {
    if (![[KBPreferences shared] boolForKey:@"cursorEnabled" defaultValue:YES]) return;
    CGFloat sensitivity = [[KBPreferences shared] floatForKey:@"cursorSensitivity" defaultValue:1.0];
    UIView *kbView = gesture.view.superview;
    
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            _spaceDragStart = [gesture locationInView:kbView];
            _spaceDragActive = YES;
            [KBUtils triggerHapticWithIntensity:0.2];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint current = [gesture locationInView:kbView];
            CGFloat dx = (current.x - _spaceDragStart.x) * sensitivity;
            CGFloat dy = (current.y - _spaceDragStart.y) * sensitivity;
            
            // 每 15px 触发一次移动
            static CGFloat accumulatedX = 0, accumulatedY = 0;
            accumulatedX += dx;
            accumulatedY += dy;
            
            BOOL fourDirection = [[KBPreferences shared] boolForKey:@"cursorFourDirection" defaultValue:YES];
            
            if (fourDirection) {
                // 4 方向移动：先判断主方向
                if (fabs(accumulatedX) > 15) {
                    KBCursorDirection dir = (accumulatedX > 0) ? KBCursorDirectionRight : KBCursorDirectionLeft;
                    [self moveCursor:dir];
                    accumulatedX = 0;
                }
                if (fabs(accumulatedY) > 15) {
                    KBCursorDirection dir = (accumulatedY > 0) ? KBCursorDirectionDown : KBCursorDirectionUp;
                    [self moveCursor:dir];
                    accumulatedY = 0;
                }
            } else {
                // 传统左右移动
                if (fabs(accumulatedX) > 15) {
                    KBCursorDirection dir = (accumulatedX > 0) ? KBCursorDirectionRight : KBCursorDirectionLeft;
                    [self moveCursor:dir];
                    accumulatedX = 0;
                }
            }
            _spaceDragStart = current;
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            _spaceDragActive = NO;
            break;
        }
        default:
            break;
    }
}

- (void)handleTapBlankArea:(UITapGestureRecognizer *)gesture {
    // 点击键盘空白区域快速定位光标到触摸位置
    // 简化实现：获取触摸点对应文本位置
    CGPoint tapPoint = [gesture locationInView:gesture.view];
    id textInput = [KBUtils currentTextInput];
    if (!textInput || ![textInput conformsToProtocol:@protocol(UITextInput)]) return;
    
    id<UITextInput> input = (id<UITextInput>)textInput;
    // 尝试将屏幕坐标转换为文本位置
    if ([input respondsToSelector:@selector(closestPositionToPoint:)]) {
        UITextPosition *pos = [input performSelector:@selector(closestPositionToPoint:)
                                          withObject:[NSValue valueWithCGPoint:tapPoint]];
        if (pos) {
            UITextRange *newRange = [input textRangeFromPosition:pos toPosition:pos];
            [input setSelectedTextRange:newRange];
        }
    }
}

@end

// ============================================================================
// 模块2：剪贴板历史面板
// ============================================================================
@interface KBClipboardManager : NSObject
+ (instancetype)shared;
- (void)addEntry:(NSString *)text;
- (NSArray *)allEntries;
- (void)removeEntryAtIndex:(NSInteger)index;
- (void)pinEntryAtIndex:(NSInteger)index;
- (void)clearAll;
- (void)pasteEntryAtIndex:(NSInteger)index;
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, strong) NSMutableSet *pinnedIndices;
@end

@implementation KBClipboardManager

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _entries = [NSMutableArray array];
        _pinnedIndices = [NSMutableSet set];
        [self loadFromDisk];
        // 注册 UIPasteboard 变更通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(pasteboardChanged:)
                                                     name:UIPasteboardChangedNotification
                                                   object:nil];
        // 定期检查剪贴板变化（原生监听有时不够可靠）
        [NSTimer scheduledTimerWithTimeInterval:2.0
                                         target:self
                                       selector:@selector(checkPasteboard)
                                       userInfo:nil
                                        repeats:YES];
    }
    return self;
}

- (NSString *)storagePath {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *dir = @"/var/mobile/Library/KeyboardPlusPro";
        // 确保目录存在
        if ([[NSFileManager defaultManager] fileExistsAtPath:dir] == NO) {
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }
        path = [dir stringByAppendingPathComponent:@"clipboard.plist"];
    });
    return path;
}

- (void)loadFromDisk {
    NSArray *saved = [NSArray arrayWithContentsOfFile:[self storagePath]];
    if (saved) {
        _entries = [saved mutableCopy];
    }
}

- (void)saveToDisk {
    [self.entries writeToFile:[self storagePath] atomically:YES];
}

- (void)addEntry:(NSString *)text {
    if (!text || text.length == 0) return;
    if (![[KBPreferences shared] boolForKey:@"clipboardEnabled" defaultValue:YES]) return;
    
    // 检查是否已存在相同内容，若有则移到最前
    NSInteger existingIndex = [self.entries indexOfObject:text];
    if (existingIndex != NSNotFound) {
        [self.entries removeObjectAtIndex:existingIndex];
    }
    
    // 插入到最前面
    [self.entries insertObject:text atIndex:0];
    
    // 超过最大条数，移除末尾非固定条目
    NSInteger maxCount = [[KBPreferences shared] integerForKey:@"clipboardMaxCount" defaultValue:KB_CLIPBOARD_MAX_DEFAULT];
    while (self.entries.count > maxCount) {
        [self.entries removeLastObject];
    }
    
    [self saveToDisk];
}

- (NSArray *)allEntries {
    return [self.entries copy];
}

- (void)removeEntryAtIndex:(NSInteger)index {
    if (index >= 0 && index < self.entries.count) {
        [self.entries removeObjectAtIndex:index];
        [self saveToDisk];
    }
}

- (void)pinEntryAtIndex:(NSInteger)index {
    // 固定/取消固定条目
    // 固定条目通过特殊标记实现，这里简化：将条目移到最前并标记
    if (index >= 0 && index < self.entries.count) {
        NSString *entry = self.entries[index];
        [self.entries removeObjectAtIndex:index];
        [self.entries insertObject:entry atIndex:0];
        [self saveToDisk];
    }
}

- (void)clearAll {
    [self.entries removeAllObjects];
    [self saveToDisk];
}

- (void)pasteEntryAtIndex:(NSInteger)index {
    if (index >= 0 && index < self.entries.count) {
        NSString *text = self.entries[index];
        id impl = [KBUtils keyboardImpl];
        if (impl && [impl respondsToSelector:@selector(insertText:)]) {
            [impl performSelector:@selector(insertText:) withObject:text];
        }
    }
}

- (NSString *)lastPasteboardString {
    // 缓存上次检测到的剪贴板内容，避免重复保存
    static NSString *s_lastPasteboardString = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_lastPasteboardString = [UIPasteboard generalPasteboard].string ?: @"";
    });
    return s_lastPasteboardString;
}

- (void)setLastPasteboardString:(NSString *)str {
    // 使用关联对象或静态变量
}

- (void)pasteboardChanged:(NSNotification *)note {
    // 剪贴板变了，保存新内容
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *text = pb.string;
    if (text && text.length > 0) {
        [self addEntry:text];
    }
}

- (void)checkPasteboard {
    // 定期检查，避免遗漏
    if (![[KBPreferences shared] boolForKey:@"clipboardEnabled" defaultValue:YES]) return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *currentText = pb.string;
    static NSString *lastText = nil;
    if (!lastText) lastText = @"";
    if (currentText && ![currentText isEqualToString:lastText]) {
        lastText = [currentText copy];
        [self addEntry:currentText];
    }
}

@end

// ============================================================================
// 模块3：自定义符号栏 (键盘顶部条)
// ============================================================================
@interface KBSymbolBarManager : NSObject
+ (instancetype)shared;
- (UIView *)symbolBarForKeyboard:(UIView *)keyboardView;
- (void)reloadSymbols;
@end

@implementation KBSymbolBarManager
{
    UIView *_currentSymbolBar;
    NSArray *_currentSymbols;
    NSArray *_quickTextTemplates;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self reloadSymbols];
    }
    return self;
}

- (void)reloadSymbols {
    NSString *customStr = [[KBPreferences shared] objectForKey:@"symbolBarCustom"
                                                     defaultValue:@",.?!@#$/:-_()[]{}'\""];
    if (customStr.length > 0) {
        NSMutableArray *arr = [NSMutableArray array];
        for (NSUInteger i = 0; i < customStr.length; i++) {
            NSString *charStr = [customStr substringWithRange:NSMakeRange(i, 1)];
            [arr addObject:charStr];
        }
        _currentSymbols = arr;
    } else {
        _currentSymbols = @[@",", @".", @"?", @"!", @"@", @"#", @"$", @"/", @":", @"-", @"_",
                            @"(", @")", @"[", @"]", @"{", @"}", @"'", @"\""];
    }
    // 快捷文本模板（可扩展）
    _quickTextTemplates = @[
        @{@"label": @"@", @"text": @"@"},
        @{@"label": @".com", @"text": @".com"},
        @{@"label": @"邮箱", @"text": @"@gmail.com"},
    ];
}

- (UIView *)symbolBarForKeyboard:(UIView *)keyboardView {
    if (![[KBPreferences shared] boolForKey:@"symbolBarEnabled" defaultValue:YES]) return nil;
    
    if (_currentSymbolBar) {
        [_currentSymbolBar removeFromSuperview];
        _currentSymbolBar = nil;
    }
    
    // 创建符号栏（背景透明，附着在键盘顶部）
    CGRect barFrame = CGRectMake(0, -KB_SYMBOL_BAR_HEIGHT - 4,
                                 keyboardView.frame.size.width, KB_SYMBOL_BAR_HEIGHT);
    UIView *bar = [[UIView alloc] initWithFrame:barFrame];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.backgroundColor = [UIColor clearColor];
    bar.tag = 0xDBB0; // 标记符号栏
    
    // 添加符号按钮
    CGFloat btnWidth = barFrame.size.width / MAX(_currentSymbols.count, 1);
    CGFloat btnHeight = barFrame.size.height;
    
    [_currentSymbols enumerateObjectsUsingBlock:^(NSString *symbol, NSUInteger idx, BOOL *stop) {
        CGRect btnFrame = CGRectMake(idx * btnWidth, 0, btnWidth, btnHeight);
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = btnFrame;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [btn setTitle:symbol forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor colorWithWhite:0.2 alpha:1] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:20];
        btn.backgroundColor = [UIColor clearColor];
        btn.tag = idx;
        [btn addTarget:self action:@selector(symbolTapped:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:btn];
    }];
    
    _currentSymbolBar = bar;
    return bar;
}

- (void)symbolTapped:(UIButton *)sender {
    NSString *symbol = _currentSymbols[sender.tag];
    id impl = [KBUtils keyboardImpl];
    if (impl && [impl respondsToSelector:@selector(insertText:)]) {
        [impl performSelector:@selector(insertText:) withObject:symbol];
    }
    [KBUtils triggerHapticWithIntensity:0.2];
}

@end

// ============================================================================
// 模块4：键盘布局 & 尺寸自定义
// ============================================================================
@interface KBLayoutManager : NSObject
+ (instancetype)shared;
- (void)applyLayoutCustomization:(UIView *)keyboardView;
- (void)applyOneHandMode:(UIView *)keyboardView offset:(CGFloat)offset;
@end

@implementation KBLayoutManager

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)applyLayoutCustomization:(UIView *)keyboardView {
    CGFloat heightRatio = [[KBPreferences shared] floatForKey:@"layoutHeightRatio" defaultValue:1.0];
    CGFloat keyGap = [[KBPreferences shared] floatForKey:@"layoutKeyGap" defaultValue:0.0];
    CGFloat keySizeRatio = [[KBPreferences shared] floatForKey:@"layoutKeySizeRatio" defaultValue:1.0];
    
    if (heightRatio != 1.0) {
        // 调整键盘高度
        CGRect frame = keyboardView.frame;
        CGFloat originalHeight = frame.size.height;
        CGFloat newHeight = originalHeight * heightRatio;
        frame.size.height = newHeight;
        keyboardView.frame = frame;
    }
    
    // 应用到子按键视图
    [self enumerateKeyViews:keyboardView block:^(UIView *keyView) {
        if (keySizeRatio != 1.0) {
            CGRect kf = keyView.frame;
            // 调整按键大小（保持中心不变）
            CGFloat newW = kf.size.width * keySizeRatio;
            CGFloat newH = kf.size.height * keySizeRatio;
            kf.origin.x += (kf.size.width - newW) / 2;
            kf.origin.y += (kf.size.height - newH) / 2;
            kf.size.width = newW;
            kf.size.height = newH;
            keyView.frame = kf;
        }
        if (keyGap > 0) {
            // 调整按键间距 — 通过修改布局约束
        }
    }];
}

- (void)applyOneHandMode:(UIView *)keyboardView offset:(CGFloat)offset {
    BOOL oneHand = [[KBPreferences shared] boolForKey:@"layoutOneHandMode" defaultValue:NO];
    if (!oneHand) {
        keyboardView.transform = CGAffineTransformIdentity;
        return;
    }
    // 单手模式：整体缩放并偏移到一侧
    CGFloat scale = 0.7;
    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);
    transform.tx = offset;
    keyboardView.transform = transform;
}

- (void)enumerateKeyViews:(UIView *)view block:(void(^)(UIView *keyView))block {
    // 递归查找按键视图（UIKeyboardLayout 内部有 UIKBKeyView 等）
    for (UIView *subview in view.subviews) {
        NSString *cls = NSStringFromClass([subview class]);
        if ([cls containsString:@"KeyView"] || [cls containsString:@"Keyplane"]) {
            if (block) block(subview);
        }
        [self enumerateKeyViews:subview block:block];
    }
}

@end

// ============================================================================
// 模块5：手势操作引擎
// ============================================================================
@interface KBGestureEngine : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)installGesturesOnKeyboard:(UIView *)keyboardView;
- (void)handleSwipeLeftDeleteWord:(UISwipeGestureRecognizer *)gesture;
- (void)handleSwipeRightUndoDelete:(UISwipeGestureRecognizer *)gesture;
- (void)handleSwipeUpSymbol:(UISwipeGestureRecognizer *)gesture;
@end

@implementation KBGestureEngine
{
    NSString *_lastDeletedWord;
    UITextRange *_lastDeletedRange;
    id<UITextInput> _lastTextInput;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)installGesturesOnKeyboard:(UIView *)keyboardView {
    // 向左滑动删除整词
    if ([[KBPreferences shared] boolForKey:@"gestureSwipeLeftDeleteWord" defaultValue:YES]) {
        UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc]
                                                initWithTarget:self action:@selector(handleSwipeLeftDeleteWord:)];
        swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
        swipeLeft.delegate = self;
        [keyboardView addGestureRecognizer:swipeLeft];
    }
    
    // 向右滑动撤销删除
    if ([[KBPreferences shared] boolForKey:@"gestureSwipeRightUndo" defaultValue:YES]) {
        UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc]
                                                 initWithTarget:self action:@selector(handleSwipeRightUndoDelete:)];
        swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
        swipeRight.delegate = self;
        [keyboardView addGestureRecognizer:swipeRight];
    }
    
    // 上滑输入符号
    if ([[KBPreferences shared] boolForKey:@"gestureSwipeUpSymbol" defaultValue:YES]) {
        UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc]
                                              initWithTarget:self action:@selector(handleSwipeUpSymbol:)];
        swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
        swipeUp.delegate = self;
        [keyboardView addGestureRecognizer:swipeUp];
    }
}

- (void)handleSwipeLeftDeleteWord:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    
    id textInput = [KBUtils currentTextInput];
    if (!textInput || ![textInput conformsToProtocol:@protocol(UITextInput)]) return;
    
    id<UITextInput> input = (id<UITextInput>)textInput;
    UITextRange *selectedRange = [input selectedTextRange];
    if (!selectedRange) return;
    
    UITextPosition *pos = selectedRange.start;
    UITextPosition *wordStart = pos;
    
    // 向前查找单词边界
    NSInteger maxChars = 100;
    for (NSInteger i = 0; i < maxChars; i++) {
        UITextPosition *prevPos = [input positionFromPosition:wordStart offset:-1];
        if (!prevPos) break;
        
        NSString *before = [input textInRange:[input textRangeFromPosition:prevPos toPosition:wordStart]];
        if (!before || before.length == 0) break;
        
        // 遇到空格或标点停止（单词边界）
        unichar c = [before characterAtIndex:0];
        if (c == ' ' || c == '\t' || c == '\n' || c == '.' || c == ',' ||
            c == '!' || c == '?' || c == ';' || c == ':') {
            // 如果是连续空格，继续跳过
            if (i == 0) { wordStart = prevPos; continue; }
            break;
        }
        wordStart = prevPos;
    }
    
    // 保存删除的文本以备撤销
    _lastDeletedRange = [input textRangeFromPosition:wordStart toPosition:pos];
    _lastDeletedWord = [input textInRange:_lastDeletedRange];
    _lastTextInput = input;
    
    // 执行删除
    if ([input respondsToSelector:@selector(setSelectedTextRange:)]) {
        [input setSelectedTextRange:_lastDeletedRange];
    }
    if ([input respondsToSelector:@selector(deleteBackward)]) {
        [input performSelector:@selector(deleteBackward)];
    }
    
    [KBUtils triggerHapticWithIntensity:0.5];
}

- (void)handleSwipeRightUndoDelete:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    if (!_lastDeletedWord || !_lastTextInput) return;
    
    // 在当前位置插入之前删除的文本
    if ([_lastTextInput respondsToSelector:@selector(insertText:)]) {
        [_lastTextInput performSelector:@selector(insertText:) withObject:_lastDeletedWord];
    }
    
    _lastDeletedWord = nil;
    _lastDeletedRange = nil;
    _lastTextInput = nil;
    
    [KBUtils triggerHapticWithIntensity:0.4];
}

- (void)handleSwipeUpSymbol:(UISwipeGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    // 上滑按键打出符号（简化为打开符号栏）
    // 实际实现需要检测滑动起点对应的按键，输出该按键对应的符号
    
    // 获取触摸点对应的按键
    CGPoint location = [gesture locationInView:gesture.view];
    UIView *touchedView = [gesture.view hitTest:location withEvent:nil];
    NSString *title = nil;
    if ([touchedView isKindOfClass:[UIButton class]]) {
        title = [(UIButton *)touchedView titleForState:UIControlStateNormal];
    }
    
    if (title && title.length == 1) {
        // 字母按键上滑输出对应符号映射
        NSDictionary *charMap = @{
            @"a": @"@", @"b": @"$", @"c": @"©", @"d": @"$", @"e": @"€",
            @"f": @"£", @"g": @"¥", @"h": @"#", @"i": @"*", @"j": @"*",
            @"k": @"&", @"l": @"%", @"m": @"?", @"n": @"!", @"o": @"•",
            @"p": @"%", @"q": @"@", @"r": @"®", @"s": @"$", @"t": @"™",
            @"u": @"_", @"v": @"^", @"w": @"~", @"x": @"»", @"y": @"«", @"z": @"≠",
        };
        NSString *low = [title lowercaseString];
        NSString *symbol = charMap[low];
        if (symbol) {
            id impl = [KBUtils keyboardImpl];
            if (impl && [impl respondsToSelector:@selector(insertText:)]) {
                [impl performSelector:@selector(insertText:) withObject:symbol];
            }
        }
    }
    
    [KBUtils triggerHapticWithIntensity:0.3];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES; // 允许与键盘原生手势共存
}

@end

// ============================================================================
// 模块6：CapsLock 真正大写锁定
// ============================================================================
@interface KBCapsLockManager : NSObject
+ (instancetype)shared;
- (void)handleShiftDoubleTap;
- (void)setCapsLock:(BOOL)locked;
- (BOOL)isCapsLocked;
@end

@implementation KBCapsLockManager
{
    BOOL _capsLockActive;
    NSTimeInterval _lastShiftTapTime;
    NSInteger _shiftTapCount;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _capsLockActive = NO;
        _lastShiftTapTime = 0;
        _shiftTapCount = 0;
    }
    return self;
}

- (void)handleShiftDoubleTap {
    if (![[KBPreferences shared] boolForKey:@"capsLockDoubleTap" defaultValue:YES]) return;
    
    NSTimeInterval now = [[NSProcessInfo processInfo] systemUptime];
    if (now - _lastShiftTapTime < 0.4) {
        _shiftTapCount++;
    } else {
        _shiftTapCount = 1;
    }
    _lastShiftTapTime = now;
    
    if (_shiftTapCount >= 2) {
        // 双击 shift：切换大写锁定
        [self setCapsLock:!_capsLockActive];
        _shiftTapCount = 0;
    }
}

- (void)setCapsLock:(BOOL)locked {
    _capsLockActive = locked;
    id impl = [KBUtils keyboardImpl];
    if (impl) {
        if ([impl respondsToSelector:@selector(setShift:)]) {
            // 设置 shift 状态，locked 表示永久大写
            [impl performSelector:@selector(setShift:) withObject:@(locked)];
        }
        // 更新键盘显示状态
        if ([impl respondsToSelector:@selector(updateLayout)]) {
            [impl performSelector:@selector(updateLayout)];
        }
    }
    // 更新 shift 按键外观
    id kbImpl = [KBUtils keyboardImpl];
    if (kbImpl && [kbImpl respondsToSelector:@selector(shiftLocked)]) {
        // 设置 shiftLocked 状态
        [kbImpl setValue:@(locked) forKey:@"shiftLocked"];
    }
    [KBUtils triggerHapticWithIntensity:0.5];
}

- (BOOL)isCapsLocked {
    return _capsLockActive;
}

@end

// ============================================================================
// 模块7：键盘主题引擎
// ============================================================================
@interface KBThemeEngine : NSObject
+ (instancetype)shared;
- (void)applyThemeToKeyboard:(UIView *)keyboardView;
- (void)applyThemeToKeyView:(UIView *)keyView;
@end

@implementation KBThemeEngine

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)applyThemeToKeyboard:(UIView *)keyboardView {
    if (![[KBPreferences shared] boolForKey:@"themeEnabled" defaultValue:NO]) return;
    
    CGFloat keyboardAlpha = [[KBPreferences shared] floatForKey:@"themeKeyboardAlpha" defaultValue:1.0];
    keyboardView.alpha = keyboardAlpha;
    
    // 遍历所有子视图应用主题
    [self enumerateAllKeyViews:keyboardView];
}

- (void)enumerateAllKeyViews:(UIView *)view {
    for (UIView *subview in view.subviews) {
        [self applyThemeToKeyView:subview];
        [self enumerateAllKeyViews:subview];
    }
}

- (void)applyThemeToKeyView:(UIView *)keyView {
    if (![[KBPreferences shared] boolForKey:@"themeEnabled" defaultValue:NO]) return;
    
    CGFloat keyRadius = [[KBPreferences shared] floatForKey:@"themeKeyRadius" defaultValue:5.0];
    CGFloat keyAlpha = [[KBPreferences shared] floatForKey:@"themeKeyAlpha" defaultValue:1.0];
    NSString *bgColorStr = [[KBPreferences shared] objectForKey:@"themeKeyBgColor" defaultValue:@""];
    NSString *textColorStr = [[KBPreferences shared] objectForKey:@"themeKeyTextColor" defaultValue:@""];
    
    // 设置圆角
    if (keyRadius >= 0) {
        keyView.layer.cornerRadius = keyRadius;
        keyView.layer.masksToBounds = YES;
    }
    
    // 设置透明度
    keyView.alpha = keyAlpha;
    
    // 设置背景色
    if (bgColorStr.length > 0) {
        UIColor *bgColor = [self colorFromHexString:bgColorStr];
        if (bgColor) {
            keyView.backgroundColor = [bgColor colorWithAlphaComponent:keyAlpha];
        }
    }
    
    // 设置文字颜色（如果是 UILabel 或 UIButton）
    if (textColorStr.length > 0) {
        UIColor *textColor = [self colorFromHexString:textColorStr];
        if ([keyView isKindOfClass:[UILabel class]]) {
            [(UILabel *)keyView setTextColor:textColor];
        } else if ([keyView isKindOfClass:[UIButton class]]) {
            [(UIButton *)keyView setTitleColor:textColor forState:UIControlStateNormal];
        }
    }
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *clean = [hexString stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"#"]) clean = [clean substringFromIndex:1];
    if (clean.length == 6) {
        unsigned int rgb = 0;
        NSScanner *scanner = [NSScanner scannerWithString:clean];
        [scanner scanHexInt:&rgb];
        return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:1.0];
    }
    return nil;
}

@end

// ============================================================================
// 模块8：触觉反馈精细调节
// ============================================================================
@interface KBHapticManager : NSObject
+ (instancetype)shared;
- (void)handleKeyPress:(NSString *)key;
- (void)setKeyHapticIntensity:(NSString *)key intensity:(CGFloat)intensity;
@end

@implementation KBHapticManager
{
    NSMutableDictionary *_perKeyIntensity;
}

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _perKeyIntensity = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)handleKeyPress:(NSString *)key {
    if (![[KBPreferences shared] boolForKey:@"hapticEnabled" defaultValue:YES]) return;
    
    CGFloat intensity = 0.3;
    if ([[KBPreferences shared] boolForKey:@"hapticPerKeyCustom" defaultValue:NO]) {
        NSNumber *stored = _perKeyIntensity[key];
        if (stored) {
            intensity = [stored floatValue];
        }
    } else {
        intensity = [[KBPreferences shared] floatForKey:@"hapticIntensity" defaultValue:0.5];
    }
    
    // 特殊按键不同强度
    if ([key isEqualToString:@"\n"]) {
        intensity *= 1.3; // 回车键强反馈
    } else if ([key isEqualToString:@"\b"]) {
        intensity *= 1.2; // 退格键稍强
    } else if ([key isEqualToString:@" "]) {
        intensity *= 0.8; // 空格键稍弱
    }
    
    [KBUtils triggerHapticWithIntensity:intensity];
}

- (void)setKeyHapticIntensity:(NSString *)key intensity:(CGFloat)intensity {
    _perKeyIntensity[key] = @(intensity);
}

@end

// ============================================================================
// 模块9：快捷动作按键
// ============================================================================
@interface KBActionButtonManager : NSObject
+ (instancetype)shared;
- (UIView *)actionBarForKeyboard:(UIView *)keyboardView;
- (void)performAction:(NSString *)actionName;
@end

@implementation KBActionButtonManager

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (UIView *)actionBarForKeyboard:(UIView *)keyboardView {
    if (![[KBPreferences shared] boolForKey:@"actionBarEnabled" defaultValue:YES]) return nil;
    
    NSString *actionStr = [[KBPreferences shared] objectForKey:@"actionButtons"
                                                    defaultValue:@"selectAll,copy,cut,paste,undo,redo"];
    NSArray *actions = [actionStr componentsSeparatedByString:@","];
    
    CGFloat barHeight = 36;
    CGFloat barY = -KB_SYMBOL_BAR_HEIGHT - 4 - barHeight - 4;
    CGRect barFrame = CGRectMake(0, barY, keyboardView.frame.size.width, barHeight);
    UIView *bar = [[UIView alloc] initWithFrame:barFrame];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1];
    bar.tag = 0xDBB1;
    
    // 动作名称映射到显示标题
    NSDictionary *actionLabels = @{
        @"selectAll": @"全选", @"copy": @"复制", @"cut": @"剪切",
        @"paste": @"粘贴", @"undo": @"撤销", @"redo": @"重做",
    };
    
    CGFloat btnWidth = barFrame.size.width / MAX(actions.count, 1);
    [actions enumerateObjectsUsingBlock:^(NSString *action, NSUInteger idx, BOOL *stop) {
        NSString *label = actionLabels[action] ?: action;
        CGRect btnFrame = CGRectMake(idx * btnWidth, 0, btnWidth, barHeight);
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = btnFrame;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [btn setTitle:label forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor colorWithWhite:0.2 alpha:1] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13];
        btn.backgroundColor = [UIColor clearColor];
        [btn addTarget:self action:@selector(actionButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        btn.actionName = action; // 使用关联属性
        [bar addSubview:btn];
    }];
    
    return bar;
}

- (void)actionButtonTapped:(UIButton *)sender {
    NSString *actionName = nil;
    if ([sender respondsToSelector:@selector(actionName)]) {
        actionName = [sender performSelector:@selector(actionName)];
    }
    if (!actionName) {
        // 通过标题反查
        NSDictionary *actionLabels = @{
            @"全选": @"selectAll", @"复制": @"copy", @"剪切": @"cut",
            @"粘贴": @"paste", @"撤销": @"undo", @"重做": @"redo",
        };
        actionName = actionLabels[[sender titleForState:UIControlStateNormal]];
    }
    [self performAction:actionName];
}

- (void)performAction:(NSString *)actionName {
    id impl = [KBUtils keyboardImpl];
    if (!impl) return;
    
    if ([actionName isEqualToString:@"selectAll"]) {
        if ([impl respondsToSelector:@selector(selectAll)]) {
            [impl performSelector:@selector(selectAll)];
        }
    } else if ([actionName isEqualToString:@"copy"]) {
        if ([impl respondsToSelector:@selector(copy)]) {
            ((id (*)(id, SEL))[impl methodForSelector:@selector(copy)])(impl, @selector(copy));
        }
    } else if ([actionName isEqualToString:@"cut"]) {
        if ([impl respondsToSelector:@selector(cut)]) {
            [impl performSelector:@selector(cut)];
        }
    } else if ([actionName isEqualToString:@"paste"]) {
        if ([impl respondsToSelector:@selector(paste)]) {
            [impl performSelector:@selector(paste)];
        }
    } else if ([actionName isEqualToString:@"undo"]) {
        if ([impl respondsToSelector:@selector(undo)]) {
            [impl performSelector:@selector(undo)];
        }
    } else if ([actionName isEqualToString:@"redo"]) {
        if ([impl respondsToSelector:@selector(redo)]) {
            [impl performSelector:@selector(redo)];
        }
    }
    [KBUtils triggerHapticWithIntensity:0.3];
}

@end

// ============================================================================
// 模块10：输入增强
// ============================================================================
@interface KBInputEnhancer : NSObject
+ (instancetype)shared;
- (NSString *)handleTextReplacement:(NSString *)text;
@end

@implementation KBInputEnhancer

+ (instancetype)shared {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (NSString *)handleTextReplacement:(NSString *)text {
    if (!text || text.length == 0) return text;
    
    // 长按句号 -> 省略号（在文本输入完成后处理）
    if ([[KBPreferences shared] boolForKey:@"inputQuickEllipsis" defaultValue:YES]) {
        if ([text isEqualToString:@"."]) {
            // 检查上下文：如果前面已经输入了连续两个句号，则替换为省略号
            id textInput = [KBUtils currentTextInput];
            if (textInput && [textInput conformsToProtocol:@protocol(UITextInput)]) {
                id<UITextInput> input = (id<UITextInput>)textInput;
                UITextPosition *pos = [input selectedTextRange].start;
                UITextPosition *prevPos = [input positionFromPosition:pos offset:-2];
                if (prevPos) {
                    UITextRange *range = [input textRangeFromPosition:prevPos toPosition:pos];
                    NSString *before = [input textInRange:range];
                    if ([before isEqualToString:@".."]) {
                        // 删除两个句号，插入省略号
                        [input setSelectedTextRange:range];
                        if ([input respondsToSelector:@selector(deleteBackward)]) {
                            [input performSelector:@selector(deleteBackward)];
                            [input performSelector:@selector(deleteBackward)];
                        }
                        return @"...";
                    }
                }
            }
        }
    }
    
    return text;
}

@end

// ============================================================================
// Logos 主钩子 - UIKeyboardImpl
// ============================================================================

%hook UIKeyboardImpl

// 键盘按键按下时
- (void)handleKeyEvent:(id)event {
    %orig;
    
    // 获取按键字符
    NSString *keyText = nil;
    if ([event respondsToSelector:@selector(keyString)]) {
        keyText = [event performSelector:@selector(keyString)];
    }
    
    // 触觉反馈
    if (keyText) {
        [[KBHapticManager shared] handleKeyPress:keyText];
    }
    
    // 文本替换增强
    if (keyText) {
        NSString *replaced = [[KBInputEnhancer shared] handleTextReplacement:keyText];
        if (![replaced isEqualToString:keyText]) {
            // 替换文本已由 enhancer 处理
        }
    }
}

// shift 按键处理 - 双击大写锁定
- (void)handleShift {
    %orig;
    [[KBCapsLockManager shared] handleShiftDoubleTap];
}

// 键盘布局即将显示时，应用自定义
- (void)updateLayout {
    %orig;
    
    // 应用布局自定义
    UIView *kbView = [self valueForKey:@"_keyboardView"];
    if (kbView) {
        [[KBLayoutManager shared] applyLayoutCustomization:kbView];
        [[KBThemeEngine shared] applyThemeToKeyboard:kbView];
    }
}

// 插入文本前拦截
- (void)insertText:(NSString *)text {
    NSString *processed = [[KBInputEnhancer shared] handleTextReplacement:text];
    if (![processed isEqualToString:text]) {
        %orig(processed);
    } else {
        %orig;
    }
}

// 如果启用了禁用自动大写，在键盘设置布局时强制清除自动大写
- (void)setAutocapitalizationType:(UITextAutocapitalizationType)type {
    if ([[KBPreferences shared] boolForKey:@"disableAutoCapitalize" defaultValue:NO]) {
        if (![KBUtils isPasswordField]) {
            type = UITextAutocapitalizationTypeNone;
        }
    }
    %orig(type);
}

// 禁用自动句号（通过预替换文本实现）
- (void)setEnablesReturnKeyAutomatically:(BOOL)enables {
    if ([[KBPreferences shared] boolForKey:@"disableAutoPeriod" defaultValue:NO]) {
        enables = YES;
    }
    %orig(enables);
}

%end

// ============================================================================
// Logos 钩子 - UIKeyboardLayout (键盘布局视图)
// ============================================================================

%hook UIKeyboardLayout

// 键盘布局已加载完成
- (void)layoutSubviews {
    %orig;
    
    // 安装自定义手势
    [[KBGestureEngine shared] installGesturesOnKeyboard:self];
    
    // 添加符号栏（如果已启用）
    UIView *symbolBar = [[KBSymbolBarManager shared] symbolBarForKeyboard:self];
    if (symbolBar && symbolBar.superview == nil) {
        [self addSubview:symbolBar];
    }
    
    // 添加快捷动作栏
    UIView *actionBar = [[KBActionButtonManager shared] actionBarForKeyboard:self];
    if (actionBar && actionBar.superview == nil) {
        [self addSubview:actionBar];
    }
    
    // 安装空格拖拽光标手势
    if ([[KBPreferences shared] boolForKey:@"cursorEnabled" defaultValue:YES]) {
        // 查找空格键并添加拖拽手势
        [self performSelector:@selector(findSpaceKeyAndAddGesture)];
    }
}

// 辅助：查找空格键添加手势
%new
- (void)findSpaceKeyAndAddGesture {
    UIView *kbSelf = (UIView *)self;
    // 遍历查找空格键视图
    for (UIView *subview in kbSelf.subviews) {
        if ([self performSelector:@selector(isSpaceKeyView:) withObject:subview]) {
            // 检查是否已添加手势
            BOOL hasGesture = NO;
            for (UIGestureRecognizer *gr in subview.gestureRecognizers) {
                if ([gr isKindOfClass:[UIPanGestureRecognizer class]] &&
                    gr.view == subview) {
                    hasGesture = YES;
                    break;
                }
            }
            if (!hasGesture) {
                // 添加空格拖拽手势，使用 KBEnhancedCursorManager 处理
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                                initWithTarget:[KBEnhancedCursorManager shared]
                                                        action:@selector(handleSpaceBarDrag:)];
                [subview addGestureRecognizer:pan];
            }
            break;
        }
    }
}

%new
- (BOOL)isSpaceKeyView:(UIView *)view {
    UIView *kbSelf = (UIView *)self;
    // 判断是否为空格键
    NSString *cls = NSStringFromClass([view class]);
    if ([cls containsString:@"KeyView"] || [cls containsString:@"Keyplane"]) {
        // 检查是否显示空格文字
        if ([view respondsToSelector:@selector(representation)]) {
            id rep = [view performSelector:@selector(representation)];
            if ([rep respondsToSelector:@selector(stringValue)]) {
                NSString *str = [rep performSelector:@selector(stringValue)];
                if ([str isEqualToString:@" "]) return YES;
            }
        }
        // 通过 frame 位置判断（空格键通常占据底部中间大块）
        if (view.frame.size.width > 100 && view.frame.origin.y > kbSelf.frame.size.height * 0.7) {
            return YES;
        }
    }
    return NO;
}

%end

// ============================================================================
// Logos 钩子 - UIKeyboard (键盘视图)
// ============================================================================

%hook UIKeyboard

// 键盘显示时
- (void)didMoveToWindow {
    %orig;
    UIView *kbView = (UIView *)self;
    if (kbView.window) {
        // 键盘已显示，应用主题和布局
        [[KBThemeEngine shared] applyThemeToKeyboard:self];
        
        // 对密码输入框自动切数字键盘
        if ([[KBPreferences shared] boolForKey:@"autoNumberPadForPassword" defaultValue:YES]) {
            if ([KBUtils isPasswordField]) {
                // 通知键盘切换到数字布局
                id impl = [KBUtils keyboardImpl];
                if (impl && [impl respondsToSelector:@selector(setKeyboardType:)]) {
                    [impl performSelector:@selector(setKeyboardType:) withObject:@(UIKeyboardTypeNumberPad)];
                }
            }
        }
    }
}

%end

// ============================================================================
// Darwin 通知回调 (跨进程通信，设置面板 → Tweak)
// ============================================================================
static void KBDarwinNotificationCallback(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object,
                                          CFDictionaryRef userInfo) {
    NSString *notifName = (__bridge NSString *)name;
    if ([notifName isEqualToString:@"com.yzdmm.keyboardplusprefs.changed"]) {
        [[KBPreferences shared] synchronize];
        [[KBSymbolBarManager shared] reloadSymbols];
        NSLog(@"[KeyboardPlusPro] Darwin 通知: 配置已重新加载");
    } else if ([notifName isEqualToString:@"com.yzdmm.keyboardpluspro.clipboardCleared"]) {
        // 剪贴板历史已清空，清空内存缓存
        [[KBClipboardManager shared] clearAll];
        NSLog(@"[KeyboardPlusPro] Darwin 通知: 剪贴板历史已清空");
    }
}

// ============================================================================
// 构造器：dylib 加载时初始化
// ============================================================================

%ctor {
    @autoreleasepool {
        NSLog(@"[KeyboardPlusPro] v%@ 加载成功 (arm64 / iOS 16)", KB_VERSION);
        NSLog(@"[KeyboardPlusPro] 设备: %@, App: %@",
              [UIDevice currentDevice].model ?: @"unknown",
              [KBUtils applicationBundleID]);
        
        // 初始化所有管理器
        [KBPreferences shared];
        [KBEnhancedCursorManager shared];
        [KBClipboardManager shared];
        [KBSymbolBarManager shared];
        [KBLayoutManager shared];
        [KBGestureEngine shared];
        [KBThemeEngine shared];
        [KBHapticManager shared];
        [KBCapsLockManager shared];
        [KBActionButtonManager shared];
        [KBInputEnhancer shared];
        
        // 注册偏好设置变更通知 (来自设置面板)
        [[NSNotificationCenter defaultCenter] addObserverForName:@"com.yzdmm.keyboardplusprefs.changed"
                                                          object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) {
            // 重新加载配置
            [[KBPreferences shared] synchronize];
            [[KBSymbolBarManager shared] reloadSymbols];
            NSLog(@"[KeyboardPlusPro] 配置已重新加载");
        }];
        
        // 注册 Darwin 通知 (设置面板跨进程通知)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        KBDarwinNotificationCallback,
                                        CFSTR("com.yzdmm.keyboardplusprefs.changed"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        KBDarwinNotificationCallback,
                                        CFSTR("com.yzdmm.keyboardpluspro.clipboardCleared"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        
        NSLog(@"[KeyboardPlusPro] 所有模块初始化完成");
    }
}