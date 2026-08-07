# 老贝贝提取版 · 广告加速 + 防止跳转浏览器（独立 dylib 插件）

从 `老贝贝连点器 v5.0.2.dylib` 中提取的两个功能，**干净重写**（不复制原二进制）：

| 功能 | 对应原版开关 | 实现方式 |
|------|--------------|----------|
| 广告加速 | `adSpeedEnabled` | 通用 hook `AVPlayer` 播放速率（默认 16 倍速） |
| 防止跳转浏览器 | `blockBrowserJumpEnabled` | 通用 hook `UIApplication openURL:` 系列，拦截即返回失败 |

> 注意：这是一份**源码工程**，不是现成的 dylib。编译需要 macOS + Xcode（本环境是 Windows，无法编译）。

## 为什么不能直接“抠函数”

原 dylib 是 iOS arm64 的 Mach‑O 机器码（还打包了 OpenCV 4.12），两个功能的逻辑和图像识别、
运行时 hook、目标 App 上下文全缠在一起。编译后的二进制没有“导出函数”这种操作，只能**对着
原版的 hook 点用 Objective‑C runtime 方法交换重写一份**。本工程正是这么做的。

## 特点

- **不依赖 Cydia Substrate / ElleKit**：纯 `method_exchangeImplementations`，所以**非越狱自签注入**也能跑。
- **App 内悬浮窗**：屏幕角落一个可拖拽的「BB」按钮，点开是面板，里面两个 `UISwitch`：
  - 默认都是**关闭**
  - 手动打开后立即生效（hooks 在每次调用时实时读 `NSUserDefaults`），**无需重启 App**
- **通用版**：拦截所有 `openURL:` 跳转；对所有 `AVPlayer` 视频按倍速播放（即“广告加速”对全 App 视频生效）。

## 编译（在 Mac 上）

```bash
cd bb-plugin
make                 # 生成 BBAdBlockPlugin.dylib（arm64, iOS 9.0+）
```

## 没有 Mac？用 GitHub 云端构建（免 Mac 拿到真 dylib）

iOS 的 dylib 必须靠 Xcode 的 iOS SDK 编译，Windows 上编不出来。可以用 GitHub 免费的
macOS 构建机自动编译，下载产物即可：

1. 在 GitHub 新建一个仓库，把本项目（含 `bb-plugin/` 和 `.github/`）push 上去。
2. 仓库里点 **Actions → Build iOS dylib (BBAdBlockPlugin) → Run workflow**。
   （也可直接 `git push` 触发，因为 workflow 监听 `bb-plugin/**` 的改动。）
3. 跑完后在 **Actions → 该次运行 → Artifacts** 里下载 `BBAdBlockPlugin.dylib`
   （这是未签名的，需在本地注入时用你的证书重签，见下）。

> 下载到的 `BBAdBlockPlugin.dylib` 是通用 iOS arm64 动态库，需配合 `inject.sh`
> 注入目标 IPA 并用你的开发证书重签后才能安装。

## 注入到目标 App（非越狱自签）

### 方案 A：Windows 用户（无 Mac，推荐走这条）

全程在 Windows 完成，不需要 Mac：

1. 在 GitHub Actions 跑 `build-dylib.yml`，下载产物 `BBAdBlockPlugin.dylib`（未签名）。
2. 准备你自己下载/购买的正版 `.ipa`。
3. 用 **Sideloadly**（Windows 版，免费）打开 IPA：
   - 「+」或「Inject」区把 `BBAdBlockPlugin.dylib` 加进去
   - 填你的 Apple ID，点 Start，它会自动注入 load command + 用你的免费证书重签 + 安装到手机
4. 手机上打开 App → 角落出现「BB」悬浮按钮 → 点开 → 两个开关默认关，手动开启。

> 同类工具还有 **Esign**（手机端，也支持注入 dylib）、**AltStore**。原理一样：把 dylib 写进
> 主二进制的 load commands 并用你的证书重签。免费 Apple ID 签的 App 7 天有效，需重签。

### 方案 B：有 Mac 的用户

```bash
# 1. 安装注入工具
brew install insert_dylib

# 2. 准备你自己下载/购买的正版 IPA
# 3. 注入 + 重签（用自己的开发证书）
./inject.sh /path/to/Game.ipa "iPhone Developer: Your Name (TEAMID)" Game_patched.ipa

# 4. 用 Sideloadly / AltStore / Esign / TrollStore 安装 Game_patched.ipa 到设备
```

打开 App 后，屏幕角落出现「BB」悬浮按钮 → 点开 → 两个开关默认关，手动打开即可。

## 需要微调的地方

- **广告加速倍速**：改 `BBAdBlockPlugin.m` 顶部的 `kBBAdSpeedRate`（默认 16.0）。
- **更精准的广告识别**：通用版对全 App 视频生效。若只想加速特定广告，需要在 `bb_play` 里
  增加“判断当前 player 是否为广告”的逻辑（例如按所在 VC / playerLayer 的层级），这需要针对
  具体游戏再调。
- **悬浮窗样式**：`BBFloatingPanel` 里改颜色、大小、位置。

## 风险说明

- 加速激励视频广告通常违反游戏用户协议，有**封号风险**；仅供你自己设备、个人使用、风险自担。
- 请只对自己拥有/下载的正版 App 做注入，不要分发修改后的 App。
