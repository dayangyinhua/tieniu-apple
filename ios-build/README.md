# 铁牛NAS共享社区 · iOS 客户端（TieniuForum）

> 仓库总说明、怎么推、怎么点、怎么分发 → 见 **上一级 `../README.md`**。
> 这里只讲 iOS 这一端自己的东西。

第四个客户端。前面三个是：Windows exe（`client/`）、飞牛远程版 FPK（`fnos-client-remote/`）、
安卓 apk（`apk-build/`）。iOS 这边**没有独立的界面代码** —— 它就是把服务端下发的
`client/web/index.html` 装进 `WKWebView`，并伪造出与安卓**逐位一致**的 `TieniuApp` 桥。

> **以后改界面只改 `client/web/index.html` + 重打服务端 FPK，iOS 端自动跟着变，
> 不用重新出 ipa。** 只有「原生能力」变了（新增桥方法、改权限）才需要重新出包。

---

## 1. 目录与文件

```
ios-build/
├── project.yml                  ← 🔴 工程的唯一真源（别去改 .xcodeproj，它不提交也不该手改）
├── Sources/
│   ├── AppDelegate.swift        ← 纯代码建 UIWindow（不用 Storyboard，少一个会坏的东西）
│   └── WebViewController.swift  ← 🔴 核心：WKWebView + 与安卓同名同签名的 TieniuApp 桥
├── Resources/Assets.xcassets/
│   ├── Contents.json                ← 🔴 少了它 actool 会**整包忽略**图标（只在真机上看得出来）
│   └── AppIcon.appiconset/
│       ├── Contents.json            ← 18 个尺寸的清单
│       └── icon-*.png               ← 全部 RGB 无 alpha（1024 那张是 App Store 用的）
└── README.md
```

⚠️ `tools/`、`release_notes-ios.txt`、`.gitignore`、`.github/` 都**上提到仓库根**了 ——
两端共用一份，不各留一套。

图标来源：仓库根的 `tools/icon-source-1024.png` → 跑
`<venv>/python.exe tools/make_app_icons.py --platform ios` → 重生成这 18 张。
**别手改 `icon-*.png`**，改了下次跑脚本就被覆盖。

---

## 2. 桥契约（改动前必读）

网页层是**同步调用**桥的，而 WKWebView 的 `postMessage` **只能异步、无返回值**
⇒ 所以 `WebViewController.swift` 里用了「**注入 JS 垫片 + 原生主动 push**」：

| 网页层怎么调 | 语义 | iOS 侧怎么实现 |
| --- | --- | --- |
| `TieniuApp.openExternal(url)` | 点火即忘 | `UIApplication.shared.open` |
| `TieniuApp.download(url, name)` | 返回 `true` = 已受理 | `URLSession` 下载 → 系统分享面板（存文件/存相册/分享） |
| `TieniuApp.copyImage(absUrl)` | 返回 `true` = 已受理 | 下载图片 → 写 `UIPasteboard`（同时留一份 URL 文本） |
| `TieniuApp.copyText(t)` | 要 `=== true` | 写 `UIPasteboard.string` |
| `TieniuApp.getClipText()` | **同步要字符串** | 垫片读缓存；原生在「回前台 / 页面获得焦点」时**预取**剪贴板 |
| `TieniuApp.getAboutInfo()` | **同步要 JSON** | 垫片读缓存；原生 push（版本来自 `Bundle`，说明来自 `version-ios.json`） |
| `TieniuApp.checkUpdateNow()` | 点火即忘 | 重新抓一次 `<下载base>/update/version-ios.json` |

**少一个方法，网页层就会整体降级**：`appShellState()` 变成 `"old"`、「关于程序」看不到
App 版本、附件下载直接失败。

上行通道 6 个（垫片 `call("Xxx"…)` ↔ 原生 `tieniuXxx` handler ↔ `didReceive` 的 `switch`）：
`OpenExternal` / `Download` / `CopyImage` / `CopyText` / `GetClipText` / `CheckUpdate`。
下行只有两个入口：`window.__tieniuResolve(id,val)`（Promise 回填）、
`window.__tieniuSetClip(v)` / `window.__tieniuSetAbout(json)`（同步读用的缓存）。

🔴 **这份垫片和 macOS 那份必须逐字节相同**（跨端硬约束，校验脚本直接比对）。

---

## 3. 已知行为 / 注意

- **服务器地址不硬编码**：走 DoH TXT 解析 `tieniu.ebaymall.cn` → `host:port` → 探活 → 加载。
  下载/更新基址同理解析 `download.ebaymall.cn`（与安卓、Windows 客户端同一套）。
- **明文 http 需要 ATS 例外**：`project.yml` 里已开 `NSAllowsArbitraryLoads` +
  `NSAllowsLocalNetworking`，否则 WKWebView 会被系统直接拦掉。
- **iOS 16+ 读剪贴板会弹「允许粘贴？」**：这是系统行为（安卓没有这个限制）。
  我们只在「回到前台 / 页面重新获得焦点」时读一次 —— 也就是用户「刚从别的 App 复制完
  回来」的时刻，此时弹窗最合理。用户点一次「允许」后，一段时间内不会再弹。
- **相册权限是故意不申请的**：选图走 `PHPickerViewController`（系统进程代选，不需要权限），
  存图走系统分享面板 ⇒ `Info.plist` 里**没有** `NSPhotoLibraryUsageDescription`。
  只有「拍照」需要 `NSCameraUsageDescription`。
- **iOS 上不能自升级**：发现新版本只会弹一次提示 + 给个「前往下载」按钮
  （安卓那边能直接下 apk 覆盖安装，iOS 不允许）。
- **文件上传**：`<input type="file">` 必须实现 `runOpenPanelWith`，否则点附件毫无反应 ——
  已实现（照片图库 / 拍照 / 浏览文件三选一）。
- **免登录**：服务端下发的 30 天 `tl_token` Cookie 存在 WKWebView 默认数据仓里，
  跨启动保留（对应主项目铁律 87）。

---

## 4. 版本号

`project.yml` 里的 `MARKETING_VERSION`（顺手把 `CURRENT_PROJECT_VERSION` +1）。
也可以在 Run workflow 时用 `version` 输入临时覆盖。iOS 客户端独立编号，从 `1.0.0` 起步 ——
与「服务端 4.6.x」「安卓 1.1.x」「exe 4.6.x」各走各的。

---

## 5. 改完怎么验

```bash
cd E:/deepseek/论坛-本地模型/forum-project
D:/Python313/python.exe _tools/verify_apple_clients.py
```

> ⚠️ 这个校验脚本**故意不住在这里**：它最关键的一组断言是「网页层调用的
> `TieniuApp.*` 方法 ↔ 垫片里实现了没有」，要拿 `client/web/index.html` 对 ——
> 那份文件只存在于主项目。所以它是「跨端契约校验」，放在一起才说得通。
