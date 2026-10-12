# 铁牛社区 · Apple 双端（iOS + macOS）

一个**仓库**、**两个产物**：iPhone/iPad 的 `ipa` 和 Mac 的 `dmg/zip`。
推一次代码，在 Actions 里点一次 **Run workflow**，两个平台一起出包。

> 🔴 这里**没有界面代码**。两个客户端都是把服务端下发的 `client/web/index.html`
> 装进 `WKWebView`，再伪造出与安卓**逐位一致**的 `TieniuApp` 桥。
>
> **所以：以后改界面只改 `client/web/index.html` + 重打服务端 FPK，两端自动跟着变，
> 不用重新出包。** 只有「原生能力」变了（新增桥方法、改权限、改菜单）才需要重新出包。

---

## 1. 为什么必须走 GitHub Actions

| 路线 | 结论 |
| --- | --- |
| 在开发这台 Windows 上编译 | ❌ 不可能 —— Xcode 只有 macOS 版，连 `swiftc` 都没有 |
| 豆包云电脑（Ubuntu 沙箱） | ❌ 解决不了 —— 给不了 macOS / Xcode，且无 root 装不了东西 |
| 国内公有云 | ❌ 没有 macOS 实例可租 |
| **GitHub Actions 的 macOS runner** | ✅ **公开仓库完全免费**，编完把产物变成可下载文件 |
| 自己的黑苹果 | ✅ 也行，但得先装好（另开一条线） |

⇒ 本机只负责「**静态校验 + 生成图标 / 更新配置**」，编译交给云端。

---

## 2. 一次性准备：把 `apple-build/` 推成一个 GitHub 仓库

🔴 **仓库的「根」就是 `apple-build/` 这个目录本身** —— GitHub 只认**仓库根**下的
`.github/workflows/`。把 `ios-build/` 当成根是**错的**（那 workflow 永远不触发）。

```bash
cd E:/deepseek/论坛-本地模型/forum-project/apple-build
git init -b main
git add .
git commit -m "Apple 双端：iOS + macOS 客户端工程与云端打包流程"
git remote add origin https://github.com/<你的账号>/<仓库名>.git
git push -u origin main
```

> ⚠️ 证书、描述文件（`*.p12` / `*.mobileprovision` / `*.p8`）**绝对不能提交**。
> `.gitignore` 已把生成物和证书全挡住；签名材料一律走仓库的 **Secrets**。

---

## 3. 点一次，出两个产物

1. 打开仓库 → 上方 **Actions** → 左侧 **铁牛社区 Apple 双端构建** → 右侧 **Run workflow**；
2. `version` 留空（用工程里的 `MARKETING_VERSION`），也可临时填 `1.0.1` 覆盖；
   `notes` 留空即可（会用 `release_notes-ios.txt` / `release_notes-macos.txt`）；
3. 点绿色 **Run workflow**。四个作业依次跑：

| 作业 | 干什么 | 大约耗时 |
| --- | --- | --- |
| `preflight` | 算有没有签名材料、解析版本号 | 10 秒 |
| `ios` | 出**未签名 ipa** + `version-ios.json` | 3~5 分钟 |
| `macos` | 出 **dmg + zip**（ad-hoc 签名）+ `version-macos.json` | 4~7 分钟 |
| `signed` | 有 4 个签名 Secrets 才跑，出**已签名 ipa** | 3~5 分钟 |

- 前三个作业**互不依赖**（`ios` / `macos` 并行跑），一个挂了不影响另一个；
- 进这次运行 → 页面底部 **Artifacts** 下载：

```
tieniu-ios-<版本>.zip        →  TieniuForum-1.0.0-unsigned.ipa + version-ios.json
tieniu-macos-<版本>.zip      →  TieniuForum-1.0.0.dmg  TieniuForum-1.0.0-mac.zip + version-macos.json
```

### 发出去

**包和 json 必须一起发**（只发包，客户端「关于程序」看到的还是上一版说明 —— 对应主项目铁律 94）。
放到下载服务器的 `<下载base>/update/` 目录（与 exe 更新包、安卓包同目录）即可，
客户端会自动发现新版本。

---

## 4. iOS：怎么把 ipa 装进手机（三条路，按「要不要花钱」分）

| 方式 | 花钱 | 成员要做什么 | 上限 | 说明 |
| --- | --- | --- | --- | --- |
| **未签名 ipa + 自签工具** | 免费 | 用电脑上的 **Sideloadly / AltStore** 装一次；免费 Apple ID 签的名 **7 天过期**，到期要用电脑重签 | 每台各自签 | 零成本，但成员得会用电脑，7 天一次很烦 |
| **Ad Hoc（推荐发社区）** | **$99/年** | 用电脑 / AltStore 装一次，**签一次管 1 年** | 100 台设备/年 | 要先收集每台设备的 **UDID**（成员装个描述文件就能发给你），加进账号后用 Ad Hoc 重签 |
| **TestFlight** | **$99/年** | App Store 装个 TestFlight，点邀请链接就装好了，**不用电脑** | 10000 人 | 最省事；但每个构建只有 **90 天**有效期，首次对外还要过 Apple 的 Beta 审核 |

> 🔴 **TestFlight 有个真实风险**：Apple 审核指南 4.2 明确不喜欢「纯网页壳」的 App
> （"minimum functionality"）。我们这个本质就是 WebView + 桥，**有被拒的可能**。
> ⇒ 先走免费路线，真要长期分发给所有成员再上 $99。
>
> 安卓能随便发 apk 是因为安卓允许侧载；iOS 从设计上就不允许 —— 这不是我们的技术问题。

### 4.1（可选）配 5 个 Secrets，云端直接出「已签名 ipa」

仓库 **Settings → Secrets and variables → Actions → New repository secret**：

| Secret 名 | 必需 | 内容 | 怎么拿 |
| --- | --- | --- | --- |
| `IOS_CERT_P12_BASE64` | ✅ | `.p12` 证书的 base64 | 钥匙串访问 → 导出证书为 .p12 → `base64 -i cert.p12 \| pbcopy` |
| `IOS_CERT_PASSWORD` | ✅ | 导出 .p12 时设的密码 | — |
| `IOS_PROVISION_BASE64` | ✅ | `.mobileprovision` 的 base64 | 开发者后台下载 Ad Hoc 描述文件后同样 base64 |
| `IOS_TEAM_ID` | ✅ | 10 位团队 ID | 开发者后台 Membership 页 |
| `IOS_PROFILE_NAME` | ⬜ | 描述文件的 **Name**（不是文件名） | `security cms -D -i x.mobileprovision \| grep -A1 '<key>Name'` |

**前 4 个少配一个 → `signed` 作业整体跳过（不是失败）**，未签名 ipa 照常产出。
`ExportOptions.plist` 里默认写 `method = ad-hoc`（发成员）；要上 TestFlight 改成
`app-store`，并把 `CODE_SIGN_IDENTITY` 换成你的 **Apple Distribution** 证书名。

---

## 5. macOS：怎么把 dmg 装进 Mac

1. 双击 `TieniuForum-1.0.0.dmg`，把 **铁牛社区** 拖进「应用程序」；
2. **首次打开会被 Gatekeeper 拦**（提示「无法验证开发者」/「已损坏」）——
   因为在 $99 账号下**做了公证（notarization）**，只是 ad-hoc 签名的包一定会被拦：

   - 简单办法：在应用上**右键 →「打开」→ 再点「打开」**（只需一次，之后正常双击）；
   - 或者终端执行：`xattr -dr com.apple.quarantine "/Applications/铁牛社区.app"`；
3. 之后双击即用。想让它**彻底不弹警告**，需要 $99 账号做 **Developer ID 签名 + 公证**（见 5.1）。

### 5.1（可选）彻底摆脱警告：Developer ID 签名 + 公证

需要 $99 账号。要做三件事：`Developer ID Application` 证书签名 → 用 `notarytool` 提交公证 →
`stapler staple` 把票据钉进包。公证材料是 App Store Connect 的 **API Key（.p8）**，
和 iOS 那套 Secrets 不通用，所以本仓库**没实现**（避免给没账号的人增加噪音）。

### 5.2 为什么 macOS 不能「完全不签名」

🔴 Apple Silicon 上**未签名的二进制会被系统直接杀掉**（不是弹警告，是秒退）。
所以 macOS 没有 iOS 那条「先出未签名包、装的时候再签」的路 —— 必须 **ad-hoc**
（`CODE_SIGN_IDENTITY = "-"`，即 Xcode 里的 "Sign to Run Locally"）。

---

## 6. 本地（有 macOS 的机器）编译

```bash
brew install xcodegen

# iOS
cd apple-build/ios-build
xcodegen generate && open TieniuForum.xcodeproj

# macOS
cd apple-build/macos-build
xcodegen generate && open TieniuForumMac.xcodeproj
```

命令行出包（与 CI 里跑的是同一套）：

```bash
# iOS：未签名 ipa
cd ios-build
xcodebuild archive -project TieniuForum.xcodeproj -scheme TieniuForum \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/TF.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" SKIP_INSTALL=NO
mkdir -p /tmp/ipa/Payload
cp -R /tmp/TF.xcarchive/Products/Applications/TieniuForum.app /tmp/ipa/Payload/
cd /tmp/ipa && zip -qry TieniuForum-1.0.0-unsigned.ipa Payload

# macOS：dmg + zip
cd macos-build
xcodebuild -project TieniuForumMac.xcodeproj -scheme TieniuForumMac \
  -configuration Release -derivedDataPath /tmp/dd ARCHS="arm64 x86_64" build
APP=/tmp/dd/Build/Products/Release/TieniuForum.app
codesign --force --sign - "$APP"
hdiutil create -volname "铁牛社区" -srcfolder "$APP" -ov -format UDZO TieniuForum-1.0.0.dmg
ditto -c -k --sequesterRsrc --keepParent "$APP" TieniuForum-1.0.0-mac.zip

# 各自的更新配置（也能在 Windows 上跑）
cd .. && python3 tools/make_version_json.py --platform ios   --file <ipa> --version 1.0.0
          python3 tools/make_version_json.py --platform macos --file <dmg> --version 1.0.0
```

---

## 7. 目录与文件

```
apple-build/                       ← 🔴 仓库根（.github/ 必须在这一层）
├── .github/workflows/apple.yml    ← 云端打包流程（一个文件出两端）
├── tools/
│   ├── make_app_icons.py          ← 一张 1024 源图 → iOS(18张,RGB) / macOS(10张,RGBA) 两套图标
│   ├── make_version_json.py       ← 生成 version-ios.json / version-macos.json
│   └── icon-source-1024.png       ← 🔴 图标唯一真源（改了 logo 就换这张再跑脚本）
├── release_notes-ios.txt          ← iOS 更新说明（--notes 留空时读它）
├── release_notes-macos.txt        ← macOS 更新说明
├── ios-build/                     ← iOS 工程（见 ios-build/README.md）
│   ├── project.yml / Sources/ / Resources/
│   └── README.md
└── macos-build/                   ← macOS 工程（见 macos-build/README.md）
    ├── project.yml / Sources/ / Resources/
    └── README.md
```

---

## 8. 两端共用的一件东西：`TieniuApp` 桥契约

两份 `WebViewController.swift` 里的 **JS 垫片 `jsShim` 是逐字节相同的** —— 这是硬约束，
校验脚本会直接比对，改了一边没改另一边就报 FAIL。桥方法 7 个：

| 网页层怎么调 | 语义 | iOS | macOS |
| --- | --- | --- | --- |
| `openExternal(url)` | 点火即忘 | `UIApplication.shared.open` | `NSWorkspace.shared.open` |
| `download(url, name)` | 返回 `true`=已受理 | `URLSession` 下载 → 系统分享面板 | `URLSession` 下载 → `NSSavePanel` 另存为 |
| `copyImage(absUrl)` | 返回 `true`=已受理 | `UIPasteboard` | `NSPasteboard` |
| `copyText(t)` | 要 `=== true` | 写 `UIPasteboard.string` | 写 `NSPasteboard.string` |
| `getClipText()` | **同步要字符串** | 垫片读缓存，回前台预取 | 垫片读缓存，1 秒轮询 `changeCount` |
| `getAboutInfo()` | **同步要 JSON** | 垫片读缓存，原生 push | 同左 |
| `checkUpdateNow()` | 点火即忘 | 重抓 `update/version-ios.json` | 重抓 `update/version-macos.json` |

**少一个方法，网页层就整体降级**：`appShellState()` 变 `"old"`、「关于程序」看不到 App 版本、
附件下载直接失败。文件上传必须实现 `runOpenPanelWith`，否则点附件毫无反应（两端都已实现）。

---

## 9. 改完怎么验

```bash
cd E:/deepseek/论坛-本地模型/forum-project
D:/Python313/python.exe _tools/verify_apple_clients.py
```

它把**能在 Windows 上验的都验掉**：两份工程描述的关键字段、**两份 Swift 结构**、
**桥契约双向对齐**、**两份 `jsShim` 逐字节相同**、图标尺寸与色彩模式（iOS 要 RGB 无 alpha /
macOS 要 RGBA）、workflow 结构、`.gitignore` 挡住证书、**真跑一遍** `make_version_json.py`
两个平台、三份 README 的覆盖度。剩下的编译只能靠云端。

> 校验脚本**故意不住在 `apple-build/` 里**：最关键的一组断言要拿 `client/web/index.html`
> 对（网页层调用的 `TieniuApp.*` ↔ 垫片实现了没有），那份文件只存在于主项目。

---

## 10. 版本号约定

- **两端各自独立编号**，都从 `1.0.0` 起步 —— 与「服务端 4.6.x」「安卓 1.1.x」「exe 4.6.x」
  各走各的（同主项目「谁真改了才升谁的号」）。
- 改版本号：对应 `project.yml` 里的 `MARKETING_VERSION`（顺手把 `CURRENT_PROJECT_VERSION` +1）。
- 也可以在 Run workflow 时用 `version` 输入临时覆盖（不必改文件、不必重新提交）。
- 出包后 `version-ios.json` / `version-macos.json` 的 `latest_version` 自动跟上，
  网页层的 `hasNew` 逻辑会给它渲染一个红 **NEW** 胶囊。

---

## 11. 三个「跑一次废一个 run」的坑（都已固化进 workflow，**别删**）

首次云端出包连着踩了三次，症状全都长得很像「代码写错了」，其实都是**环境/平台版本**问题。
三层防护现在都在 `apple.yml` 里，改 workflow 时**千万别顺手删掉**：

### 11.1 `objectVersion 77` —— Xcode 工程格式太新

- **症状**：job 20 秒就红，报错只在 `xcodebuild` 那一步：
  `Unable to read project … it is in a future Xcode project file format (77)`。
- **根因**：新版 **XcodeGen（2.46）默认生成 Xcode 16 的工程格式**（`objectVersion = 77`），
  而 runner 上的老 Xcode 读不了。
- **防护**：① 三个 macOS 作业统一 `runs-on: macos-15`（自带 Xcode 16+）；
  ② 「生成 Xcode 工程（并确保当前 Xcode 读得懂）」步骤里**先试读一次**
  （`xcodebuild -list`），读不了就 `sed` 把 `objectVersion` 降到 **56**，并删掉
  `preferredProjectObjectVersion` / `minimizedProjectReferenceProxies` 再试读。
  XcodeGen 产出的是传统 PBXGroup 结构、没有 77 专属对象 ⇒ 降级是安全的。

### 11.2 `WKOpenPanelParameters` —— iOS 部署目标太低

- **症状**：编译报
  `error: 'WKOpenPanelParameters' is only available in iOS 18.4 or newer`
  （注意是 **error 不是 warning**，直接编译失败）。
- **根因**：自定义 `<input type="file">` 上传面板的代理方法
  `webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`
  与它带的 `WKOpenPanelParameters` **都是 iOS 18.4 才公开的新 API**，
  而本工程 `deploymentTarget.iOS = 14.0`。
- **修法**：给那个方法标 **`@available(iOS 18.4, *)`**（不要为了它抬高部署目标！）。
  老系统上**功能不缺失** —— Apple 官方文档原话：
  *"By default on iOS, file uploads are enabled if you don't implement this method."*
  即 iOS < 18.4 时 WebKit 会自己弹内置的 `WKFileUploadPanel`（照片图库 / 拍照 / 浏览文件），
  只是文案跟随系统语言。⇒ **18.4+ 用我们这份中文面板，更低版本自动回落系统面板。**
- 同类风险 API：`WKWebView.isInspectable`(16.4+)、`callAsyncJavaScript`(14.3+)、
  `WKDownload`(14.5+)、`underPageBackgroundColor`(15+)、`UIFindInteraction`(16+)……
  **该文件目前一个都没用**，将来要用记得照 11.2 的办法处理。

### 11.3 `hdiutil: attach failed - Resource temporarily unavailable` —— CI 偶发

- **症状**：dmg **已经成功生成**（`created: …dmg` 都打出来了），
  紧接着「挂载 dmg 验一遍」那句偶发失败，把整个 job 判红。
- **根因**：macOS runner 上 `diskimages-help` 助手进程与其他任务抢资源，
  与被测 dmg 好坏**毫无关系**（同一份 dmg 上一轮挂得上、这一轮挂不上）。
- **防护**：挂载验证改成 **重试 3 次**（每次间隔 3 秒、加 `-noverify`）；
  三次都不行只发 `::warning::`，**不判红**。
  真正的坏包检测交给后面「`version-macos.json` ↔ 实际下载文件」的 **md5/size 交叉复核**。

### 附：CI 产物**不是**逐字节可复现的

同一个 commit 跑两次，ipa/dmg 的 **md5 不同**（zip/dmg 里存了文件 mtime）。
所以「校验」永远要拿**同一次 run** 生成的 `version-*.json` 去对**同一次 run 下载的包**，
不能拿上一轮的 json 去对下一轮的包。
