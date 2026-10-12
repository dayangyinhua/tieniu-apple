# 铁牛社区 · macOS 桌面版（TieniuForumMac）

> 仓库总说明、怎么推、怎么点、怎么分发 → 见 **上一级 `../README.md`**。
> 这里只讲 macOS 这一端自己的东西。

第五个客户端：Windows exe（`client/`）、飞牛远程版 FPK（`fnos-client-remote/`）、
安卓 apk（`apk-build/`）、iOS（`ios-build/`）、**macOS 桌面版（这里）**。
和 iOS 一样**没有独立的界面代码** —— 就是把服务端下发的 `client/web/index.html`
装进 `WKWebView`，并伪造出与安卓**逐位一致**的 `TieniuApp` 桥。

> **以后改界面只改 `client/web/index.html` + 重打服务端 FPK，Mac 端自动跟着变，
> 不用重新出包。** 只有「原生能力」变了才需要重新出包。

---

## 1. 与 iOS 端的关键差异（**不是抄错**）

| 点 | iOS | macOS |
| --- | --- | --- |
| UI 框架 | UIKit（`UIViewController` / `UIWindow`） | AppKit（`NSViewController` / `NSWindow` / `NSMenu`） |
| 入口 | `@main AppDelegate` | `main.swift` **顶层代码**（文件名即入口，连 `@main` 都不用） |
| 签名 | 默认**完全不签**（装的时候再签） | 🔴 **必须 ad-hoc**（`CODE_SIGN_IDENTITY = "-"`），否则 Apple Silicon 上被系统秒杀 |
| 产物 | `.app` → `Payload` → zip 成 **ipa** | `.app` → **dmg**（`hdiutil`）/ **zip**（`ditto`） |
| 图标 | 实心方形、**不能有 alpha**（colortype 2） | 圆角方形 + 四周透明、**必须有 alpha**（colortype 6） |
| 剪贴板读取 | 回前台 / 页面获焦时**预取一次**（16+ 会弹授权） | 1 秒定时器盯 `NSPasteboard.changeCount`（macOS 读剪贴板**不弹授权**） |
| 下载 | 下完弹**系统分享面板**让用户选存哪儿 | 先弹 **`NSSavePanel`** 让用户挑路径，进度显示在窗口标题上 |
| 更新配置 | `update/version-ios.json` | `update/version-macos.json` |
| 页面缩放 | 无 | ⌘+ / ⌘- / ⌘0（`webView.pageZoom` 夹在 0.5~3.0） |

---

## 2. 目录与文件

```
macos-build/
├── project.yml                  ← 🔴 工程的唯一真源（别去改 .xcodeproj，它不提交也不该手改）
├── Sources/
│   ├── main.swift               ← 顶层入口。⚠️ `let delegate = AppDelegate()` 必须被顶层持有
│   ├── AppDelegate.swift        ← 🔴 菜单栏（见第 3 节，这是必需品不是装饰）
│   └── WebViewController.swift  ← 🔴 核心：WKWebView + 与 iOS 逐字节相同的 jsShim + TieniuApp 桥
├── Resources/Assets.xcassets/
│   ├── Contents.json                ← 🔴 少了它 actool 会**整包忽略**图标
│   └── AppIcon.appiconset/
│       ├── Contents.json            ← 10 个尺寸的清单（16 / 32 / 128 / 256 / 512，各含 @1x @2x）
│       └── icon_*.png               ← 全部 RGBA（圆角 + 透明边）
└── README.md
```

图标来源：仓库根的 `tools/icon-source-1024.png` → 跑
`<venv>/python.exe tools/make_app_icons.py --platform macos` → 重生成这 10 张。
**别手改 `icon_*.png`**。macOS 图标按 Big Sur 官方网格比例生成：
画布 1024、图形本体 **824×824 居中**、圆角半径 **≈185** —— 不按这个比例做，
Dock 里会比系统图标「大一圈 / 小一圈」。

---

## 3. 「编辑」菜单是必需品，不是装饰

🔴 macOS 上 **⌘C / ⌘V / ⌘A / ⌘Z 全部走「菜单 → 响应链」**：快捷键把 `copy:` / `paste:`
发给**第一响应者**，而不是直接发给 WebView。**不建这个菜单，快捷键按了完全没反应，而且不报错**
—— 排查起来极其费时间。

菜单结构（`AppDelegate.buildMainMenu()`）：

| 菜单 | 项 |
| --- | --- |
| 铁牛社区 | 关于（复用网页里的「关于程序」弹层）/ 隐藏 ⌘H / 隐藏其他 ⌥⌘H / 显示全部 / 退出 ⌘Q |
| **编辑** | 撤销 ⌘Z / 重做 ⇧⌘Z / 剪切 ⌘X / **拷贝 ⌘C / 粘贴 ⌘V** / 全选 ⌘A（target 留 `nil` 走响应链） |
| 显示 | 重新载入 ⌘R / 放大 ⌘+ / 缩小 ⌘- / 实际大小 ⌘0 / 进入全屏幕 ⌃⌘F |
| 窗口 | 最小化 ⌘M / 缩放 / 前置全部窗口 |
| 帮助 | 复制社区地址 |

窗口：`1280×840`、最小 `760×560`、`setFrameAutosaveName("TieniuMainWindow")`（记住位置大小）、
关闭最后一个窗口即退出；点 Dock 图标会重开窗口。

---

## 4. 桥契约（改动前必读）

网页层是**同步调用**桥的，而 WKWebView 的 `postMessage` **只能异步、无返回值**
⇒ 所以 `WebViewController.swift` 里用了「**注入 JS 垫片 + 原生主动 push**」：

| 网页层怎么调 | 语义 | macOS 侧怎么实现 |
| --- | --- | --- |
| `TieniuApp.openExternal(url)` | 点火即忘 | `NSWorkspace.shared.open` |
| `TieniuApp.download(url, name)` | 返回 `true` = 已受理 | `NSSavePanel` 选路径 → `URLSession` 下载 → 访达里定位文件 |
| `TieniuApp.copyImage(absUrl)` | 返回 `true` = 已受理 | `NSImage(data:)` → `NSPasteboard.writeObjects`（同时留一份 URL 文本） |
| `TieniuApp.copyText(t)` | 要 `=== true` | 写 `NSPasteboard.string` |
| `TieniuApp.getClipText()` | **同步要字符串** | 垫片读缓存；1 秒定时器盯 `changeCount` 主动 push |
| `TieniuApp.getAboutInfo()` | **同步要 JSON** | 垫片读缓存；原生 push（版本来自 `Bundle`，说明来自 `version-macos.json`） |
| `TieniuApp.checkUpdateNow()` | 点火即忘 | 重新抓一次 `<下载base>/update/version-macos.json` |

**少一个方法，网页层就会整体降级**：`appShellState()` 变成 `"old"`、「关于程序」看不到
App 版本、附件下载直接失败。

上行通道 6 个（垫片 `call("Xxx"…)` ↔ 原生 `tieniuXxx` handler ↔ `didReceive` 的 `switch`）：
`OpenExternal` / `Download` / `CopyImage` / `CopyText` / `GetClipText` / `CheckUpdate`。
下行只有两个入口：`window.__tieniuResolve(id,val)`（Promise 回填）、
`window.__tieniuSetClip(v)` / `window.__tieniuSetAbout(json)`（同步读用的缓存）。

🔴 **这份 `jsShim` 和 iOS 那份必须逐字节相同**（跨端硬约束，校验脚本直接比对）。

---

## 5. 已知行为 / 注意

- **服务器地址不硬编码**：走 DoH TXT 解析 `tieniu.ebaymall.cn` → `host:port` → 探活 → 加载。
  下载/更新基址同理解析 `download.ebaymall.cn`。
- **明文 http 需要 ATS 例外**：`project.yml` 里已开 `NSAllowsArbitraryLoads` +
  `NSAllowsLocalNetworking`，否则 WKWebView 直接被拦。
- **沙盒与加固运行期都关掉**（`ENABLE_APP_SANDBOX: NO` / `ENABLE_HARDENED_RUNTIME: NO`）：
  不走 App Store 分发，没必要为它扛 entitlements 的复杂度。
- **通用二进制**：`ARCHS: $(ARCHS_STANDARD)` + `ONLY_ACTIVE_ARCH: NO`，
  Intel 与 Apple Silicon 都能跑（CI 里显式给 `ARCHS="arm64 x86_64"`，构建后可 `lipo -archs` 验证）。
- **底色跟随网页主题**：`syncAppBg()` 读 CSS 变量 `--app-bg`，
  只改**本窗口**的 `appearance`（暗色时标题栏变深），**不动 `NSApp.appearance`**
  —— 动它会连菜单栏一起翻色，太扎眼。
- **不做自升级**：发现新版本只弹一次 `NSAlert` + 给个「前往下载」按钮，
  用户自己下 dmg 覆盖安装（Mac 上没有安卓那种静默安装）。
- **首次打开会被 Gatekeeper 拦**：ad-hoc 签名 + 未公证 ⇒ 必须**右键 →「打开」**，
  或 `xattr -dr com.apple.quarantine "/Applications/铁牛社区.app"`。想彻底不弹要 $99 账号做公证。
- **文件上传**：`<input type="file">` 必须实现 `runOpenPanelWith`（这里用 `NSOpenPanel`，
  `allowsOtherFileTypes = true` 不做类型过滤 —— `WKOpenPanelParameters` 的公开 API 里没有 `accept`），
  否则点附件毫无反应。
- **免登录**：服务端下发的 30 天 `tl_token` Cookie 存在 WKWebView 默认数据仓里，跨启动保留。

---

## 6. 版本号

`project.yml` 里的 `MARKETING_VERSION`（顺手把 `CURRENT_PROJECT_VERSION` +1）。
也可以在 Run workflow 时用 `version` 输入临时覆盖。macOS 客户端独立编号，从 `1.0.0` 起步 ——
与「服务端 4.6.x」「安卓 1.1.x」「exe 4.6.x」「iOS 1.0.x」各走各的。

---

## 7. 改完怎么验

```bash
cd E:/deepseek/论坛-本地模型/forum-project
D:/Python313/python.exe _tools/verify_apple_clients.py
```

> ⚠️ 这个校验脚本**故意不住在这里**：它最关键的一组断言是「网页层调用的
> `TieniuApp.*` 方法 ↔ 垫片里实现了没有」，要拿 `client/web/index.html` 对 ——
> 那份文件只存在于主项目。
