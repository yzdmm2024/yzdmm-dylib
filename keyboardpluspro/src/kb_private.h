// kb_private.h — 私有 UIKit 键盘类补全声明
//
// iOS SDK 不含这些类的完整接口，theos 的 logos 处理器为 %hook 目标
// （UIKeyboardImpl / UIKeyboardLayout / UIKeyboard 等）只生成 @class 前向声明。
// 这会导致生成的 hook 代码把 self(私有类*) 当 UIView* 传参/调实例方法时
// 报“不完整类型 / forward declaration”硬错误。
//
// 这里仅做编译期补全（声明成正确的父类），运行时仍是系统真实类，无副作用。
#import <UIKit/UIKit.h>

@interface UIKeyboardImpl : UIResponder @end
@interface UIKeyboard : UIView @end
@interface UIKeyboardLayout : UIView @end
@interface UIKBKeyView : UIView @end
@interface UIKBTreeKey : UIKBKeyView @end
@interface UIKBKey : NSObject @end
@interface UIKBKeyplaneView : UIView @end
@interface UIKeyboardCandidate : NSObject @end
