//
//  WebViewController.swift
//  铁牛社区 · macOS 桌面版客户端
//
//  ======================== 这份文件在干什么 ========================
//
//  一句话：**把网页版原封不动装进 WKWebView，同时在页面里伪造出安卓那套 `TieniuApp` 桥。**
//  （与 ios-build/Sources/WebViewController.swift 是同一套思路、同一份桥契约，
//    差别只在「外壳」：UIKit → AppKit，UIPasteboard → NSPasteboard，
//    分享面板 → NSSavePanel 另存为。）
//
//  🔴🔴 **下面的 JS 垫片必须与 iOS 那份逐字节相同** —— 它是跨端契约，
//      两边一旦漂移，就会出现「iOS 能复制、macOS 复制没反应」这种最难查的问题。
//      `_tools/verify_apple_clients.py` 里有一条断言专门比对两份垫片。
//
//  ======================== 桥契约（🔴 与安卓/iOS 逐位一致） ========================
//
//  网页层是**同步调用**桥的（见 index.html）：
//      b.getClipText() → 直接要 String ／ b.copyText(t) === true ／ b.getAboutInfo() → 直接要 JSON 串
//  而 WKWebView 的 `postMessage` **只能异步、无返回值**（macOS 上也没有同步桥）。
//  ⇒ 同一个解法：**注入 JS 垫片 + 原生主动把值 push 进垫片缓存**。
//
//  ✅ macOS 比 iOS 舒服的一点：**读系统剪贴板不会弹任何授权框**（iOS 16+ 会弹「允许粘贴？」），
//     所以这里可以挂一个 1 秒的定时器盯着 `NSPasteboard.changeCount`，
//     剪贴板一变就推给垫片 —— 缓存永远是新鲜的。
//
//  ======================== 服务地址发现（与安卓/iOS 同一套） ========================
//  飞牛的图标 URL 写不进 IP/域名（铁律 88）⇒ **不能硬编码服务器地址**。
//  DoH TXT：`dns.alidns.com` 解析 `tieniu.ebaymall.cn` → `host:port` → 探活 → 加载；
//  下载/更新资源基址同理解析 `download.ebaymall.cn`。
//

import Cocoa
import WebKit

final class WebViewController: NSViewController {

    // MARK: - 常量（与 apk-build/MainActivity.java · ios-build/WebViewController.swift 对齐）

    private static let dohForumURL = "https://dns.alidns.com/resolve?name=tieniu.ebaymall.cn&type=TXT"
    private static let dohDownloadURL = "https://dns.alidns.com/resolve?name=download.ebaymall.cn&type=TXT"
    /// 更新配置候选：优先 macOS 专用 json，回落通用 json（逐条尝试，取第一个能解析的）
    private static let updateCfgPaths = ["/update/version-macos.json", "/update/version-luntan.json"]
    private static let probeTimeout: TimeInterval = 3.5
    private static let handlerNames = [
        "tieniuOpenExternal", "tieniuDownload", "tieniuCopyImage",
        "tieniuCopyText", "tieniuGetClipText", "tieniuCheckUpdate",
    ]
    /// 兜底底色 = 网页默认主题的 `--app-bg`（安卓/ iOS 同值）。
    /// 真正的值靠 syncAppBg() 从页面读（网页主题用户可切换）。
    private static let fallbackBg = NSColor(srgbRed: 4 / 255.0, green: 6 / 255.0, blue: 12 / 255.0, alpha: 1)
    private static let accentCyan = NSColor(srgbRed: 0.216, green: 0.741, blue: 0.973, alpha: 1)   // #38bdf8

    // MARK: - 状态

    private var webView: WKWebView!
    private let downloader = Downloader()

    private var cachedClip = ""
    private var clipChangeCount = -1
    private var clipTimer: Timer?

    private var cfgBody: String?
    private var downloadBase: String?
    private var cfgFetching = false
    private var notifiedVersion: String?

    private var currentBase: String?
    private var isLoadingPage = false
    private var didStartupUpdateCheck = false
    private var isDarkChrome = true

    // 遮罩（连接中 / 出错重试）
    private let mask = NSView()
    private let maskLabel = NSTextField(labelWithString: "正在连接社区服务器…")
    private let maskSpinner = NSProgressIndicator()
    private let maskRetry = NSButton()

    // 文件选择
    private var filePickerCompletion: (([URL]?) -> Void)?

    /// 显示用的 App 版本（= CFBundleShortVersionString，由 xcodegen 从 MARKETING_VERSION 注入）
    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: - 视图构建

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 840))
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.fallbackBg.cgColor
        view = root

        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        // UA 尾巴带上 TieniuApp/1.0.0 —— 网页层的 appShellState() 拿它兜底识别
        cfg.applicationNameForUserAgent = "TieniuApp/\(appVersion)"
        cfg.userContentController.addUserScript(makeShimScript())

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true     // 双指左右滑 = 前进/后退
        wv.allowsMagnification = true                     // 触控板捏合缩放
        wv.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: root.topAnchor),
            wv.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        webView = wv

        for name in Self.handlerNames {
            cfg.userContentController.add(WeakMessageHandler(self), name: name)
        }
        setupMask(in: root)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 剪贴板：macOS 读剪贴板**不会弹授权** ⇒ 挂个 1 秒定时器盯 changeCount，缓存永远新鲜
        clipTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.primeClipboard()
        }
        if let t = clipTimer { RunLoop.main.add(t, forMode: .common) }

        NotificationCenter.default.addObserver(
            self, selector: #selector(onAppActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWindowKey),
            name: NSWindow.didBecomeKeyNotification, object: nil)

        startDiscovery()
    }

    deinit {
        clipTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onAppActive() {
        primeClipboard()
        syncAppBg()
    }

    @objc private func onWindowKey() {
        primeClipboard()
        if !isLoadingPage && mask.isHidden { syncAppBg() }
        // 卡在「连不上」的遮罩上 ⇒ 重新点一下窗口就自动重试一次
        if !mask.isHidden && !maskRetry.isHidden { startDiscovery() }
    }

    // MARK: - 对外（菜单栏用）

    func reload() {
        if webView.url == nil && currentBase == nil { startDiscovery(); return }
        webView.reload()
    }

    func zoom(delta: CGFloat) {
        if delta == 0 { webView.pageZoom = 1.0; return }
        webView.pageZoom = min(max(webView.pageZoom + delta, 0.5), 3.0)
    }

    func copyServerAddress() {
        guard let base = currentBase else { toast("还没连上服务器", ok: false); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(base + "/", forType: .string)
        clipChangeCount = -1
        primeClipboard()
        toast("已复制社区地址：\(base)")
    }

    /// 菜单「关于铁牛社区」：**直接复用网页里那个「关于程序」弹层** ——
    /// 一份实现、四端一致（版本号、更新说明、NEW 标记的逻辑都在网页层里）。
    func showAboutDialog() {
        if webView.url == nil {
            let a = NSAlert()
            a.messageText = "正在连接社区服务器…"
            a.informativeText = "页面还没加载完，稍后再试一次。"
            a.addButton(withTitle: "好")
            a.runModal()
            return
        }
        webView.evaluateJavaScript("(window.showAboutDialog && window.showAboutDialog(), 0)") { _, _ in }
    }

    // MARK: - JS 垫片（🔴 必须与 ios-build/Sources/WebViewController.swift 里的逐字节相同）

    private func makeShimScript() -> WKUserScript {
        let js = Self.jsShim.replacingOccurrences(of: "__TIENIU_APP_VER__", with: appVersion)
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static let jsShim = #"""
    (function () {
      if (window.TieniuApp) { return; }         // 已经有了就别覆盖（幂等）

      var seq = 0, pending = {};
      // 原生下行回填的唯一入口
      window.__tieniuResolve = function (id, val) {
        var f = pending[id];
        if (f) { delete pending[id]; try { f(val); } catch (e) {} }
      };
      function call(cmd, args, timeoutMs) {
        return new Promise(function (res) {
          var id = "t" + (++seq);
          pending[id] = res;
          try {
            window.webkit.messageHandlers["tieniu" + cmd].postMessage({ id: id, args: args || [] });
          } catch (e) { delete pending[id]; res(null); return; }
          setTimeout(function () {
            if (pending[id]) { delete pending[id]; res(null); }
          }, timeoutMs || 4000);
        });
      }

      var APP_VER = "__TIENIU_APP_VER__";

      // ① 剪贴板文本：网页层是**同步**要的 ⇒ 原生预取后 push 到这里，垫片同步读缓存。
      //    初始 null ⇒ getClipText() 返回 "" （= 读到了但为空），与安卓语义一致。
      var clip = "";
      window.__tieniuSetClip = function (v) { clip = (typeof v === "string") ? v : ""; };

      // ② 「关于程序」信息：同上，同步要 ⇒ 原生 push JSON 原文到这里。
      var about = "";
      window.__tieniuSetAbout = function (j) { if (typeof j === "string" && j) { about = j; } };

      var bridge = {
        openExternal: function (url) {
          call("OpenExternal", [String(url == null ? "" : url)], 1000);
        },
        // 返回 true = 「请求已受理，原生接管」（与安卓同语义：网页层据此不再自己弹提示）
        download: function (url, name) {
          call("Download", [String(url == null ? "" : url), String(name == null ? "" : name)], 2000);
          return true;
        },
        copyImage: function (absUrl) {
          call("CopyImage", [String(absUrl == null ? "" : absUrl)], 2000);
          return true;
        },
        copyText: function (t) {
          call("CopyText", [String(t == null ? "" : t)], 1500);
          return true;
        },
        checkUpdateNow: function () { call("CheckUpdate", [], 1000); },
        getClipText: function () { return clip; },
        getAboutInfo: function () {
          return about || JSON.stringify({ app_version: APP_VER, shell: "ok", pending: true });
        }
      };

      // 预取剪贴板：切回前台 / 页面重新获得焦点时各来一次
      function primeClip() { call("GetClipText", [], 2000).then(function (v) { if (typeof v === "string") { clip = v; } }); }
      document.addEventListener("visibilitychange", function () {
        if (document.visibilityState === "visible") { primeClip(); }
      }, true);
      window.addEventListener("focus", primeClip, true);
      window.addEventListener("pageshow", primeClip, true);

      window.TieniuApp = bridge;
    })();
    """#

    // MARK: - 原生底色跟随网页主题

    private func syncAppBg() {
        let js = "(function(){try{var v=getComputedStyle(document.documentElement)"
               + ".getPropertyValue('--app-bg');return (v||'').trim();}catch(e){return '';}})()"
        webView.evaluateJavaScript(js) { [weak self] v, _ in
            guard let self = self, let s = v as? String else { return }
            self.applyAppBg(s)
        }
    }

    private func applyAppBg(_ hex: String) {
        guard let c = Self.parseHexColor(hex) else { return }      // 读不到/格式变了 ⇒ 保持现状
        let dark = Self.isDarkColor(c)
        view.layer?.backgroundColor = c.cgColor
        mask.layer?.backgroundColor = c.cgColor
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = c }
        maskLabel.textColor = dark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.32, alpha: 1)
        maskRetry.contentTintColor = dark ? Self.accentCyan : NSColor(srgbRed: 0.10, green: 0.36, blue: 0.80, alpha: 1)
        // 让标题栏也跟着变。⚠️ 只改**本窗口**的 appearance，不动 NSApp.appearance ——
        // 改 NSApp 会连菜单栏一起翻成深色，跟系统其它 App 不一致，太扎眼。
        if dark != isDarkChrome {
            isDarkChrome = dark
            view.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }

    /// "#0a0b0c" / "0a0b0c" / "#abc" → NSColor
    static func parseHexColor(_ s: String) -> NSColor? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("#") { t.removeFirst() }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6, t.allSatisfy({ $0.isHexDigit }), let v = UInt32(t, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0,
                       alpha: 1)
    }

    /// sRGB 近似相对亮度 —— 判断该配白字还是黑字
    static func isDarkColor(_ c: NSColor) -> Bool {
        guard let rgb = c.usingColorSpace(.sRGB) else { return true }
        return (0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent) < 0.5
    }

    // MARK: - 服务地址发现 + 加载

    private func startDiscovery() {
        showMask("正在连接社区服务器…", retry: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let host = self.dohTxt(Self.dohForumURL)
            var base: String?
            if let h = host, !h.isEmpty {
                let cand = h.lowercased().hasPrefix("http") ? h : "http://" + h
                let trimmed = cand.hasSuffix("/") ? String(cand.dropLast()) : cand
                if self.probe(trimmed) { base = trimmed }
            }
            DispatchQueue.main.async {
                guard let b = base else {
                    self.showMask("无法连接社区服务器，请检查网络（或 NAS 是否开机）后重试。", retry: true)
                    return
                }
                self.currentBase = b
                self.loadBase()
            }
        }
    }

    private func loadBase() {
        guard let b = currentBase, let u = URL(string: b + "/") else { return }
        isLoadingPage = true
        webView.load(URLRequest(url: u))
    }

    // MARK: - 网络小工具

    private func dohTxt(_ dohURL: String) -> String? {
        guard let body = httpGet(dohURL, timeout: 8),
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = obj["Answer"] as? [[String: Any]] else { return nil }
        for a in answers {
            guard let t = a["type"] as? Int, t == 16 else { continue }
            var d = (a["data"] as? String ?? "")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let eq = d.firstIndex(of: "=") {                 // 兼容 "key=host:port"
                d = String(d[d.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if d.contains(":") { return d }
        }
        return nil
    }

    /// 同步 GET（只在后台线程调用）
    private func httpGet(_ urlStr: String, timeout: TimeInterval) -> String? {
        guard let u = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let sem = DispatchSemaphore(value: 0)
        var out: String?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data { out = String(data: d, encoding: .utf8) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return out
    }

    private func probe(_ base: String) -> Bool {
        guard let u = URL(string: base + "/") else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = Self.probeTimeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if err == nil, let h = resp as? HTTPURLResponse { ok = (h.statusCode >= 200 && h.statusCode < 500) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + Self.probeTimeout + 1.5)
        return ok
    }

    private func resolveDownloadBase() -> String? {
        guard let v = dohTxt(Self.dohDownloadURL), !v.isEmpty else { return nil }
        var s = v.lowercased().hasPrefix("http") ? v : "http://" + v
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: - 下行：把值填回垫片

    private func evalJS(_ js: String) {
        if Thread.isMainThread {
            webView.evaluateJavaScript(js) { _, err in
                if let err = err { NSLog("[tieniu] evalJS 失败: %@", "\(err)") }
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.evalJS(js) }
        }
    }

    private func resolve(_ id: String?, _ value: Any?) {
        guard let id = id, !id.isEmpty else { return }
        evalJS("window.__tieniuResolve(\(jsLiteral(id)), \(jsLiteral(value)));")
    }

    private func jsLiteral(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "null" }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if let s = v as? String {
            if let d = try? JSONSerialization.data(withJSONObject: [s]),
               let arr = String(data: d, encoding: .utf8), arr.count >= 2 {
                return String(arr.dropFirst().dropLast())
            }
            return "\"\""
        }
        return "null"
    }

    private func pushClip(_ s: String, force: Bool = false) {
        let changed = (cachedClip != s)
        cachedClip = s
        guard force || changed else { return }
        evalJS("window.__tieniuSetClip && window.__tieniuSetClip(\(jsLiteral(s)));")
    }

    private func pushAbout() {
        var o: [String: Any] = ["app_version": appVersion, "shell": "ok"]
        if cfgFetching || cfgBody == nil { o["pending"] = true }
        if let body = cfgBody,
           let d = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            o["latest_version"] = d["latest_version"] ?? ""
            o["release_notes"] = d["release_notes"] ?? ""
            o["published_at"] = d["published_at"] ?? ""
            o["macos_url"] = d["macos_url"] ?? d["download_url"] ?? ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: data, encoding: .utf8) else { return }
        evalJS("window.__tieniuSetAbout && window.__tieniuSetAbout(\(jsLiteral(json)));")
    }

    // MARK: - 剪贴板（NSPasteboard）

    /// 剪贴板一变就推给垫片。macOS **没有** iOS 那个「允许粘贴？」授权框 ⇒ 可以随便读。
    private func primeClipboard() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        if cc == clipChangeCount { return }
        clipChangeCount = cc
        pushClip(pb.string(forType: .string) ?? "")
    }

    private func copyTextToClipboard(_ t: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t, forType: .string)
        clipChangeCount = pb.changeCount
        pushClip(t, force: true)
        toast("已复制到剪贴板")
    }

    /// 「复制图片」：下载 → 写进系统剪贴板（同时留一份图片 URL 文本，粘端只读文本也能还原）
    private func copyImageToClipboard(_ absUrl: String) {
        guard let u = URL(string: absUrl) else { toast("图片地址无效", ok: false); return }
        toast("正在复制图片…")
        URLSession.shared.dataTask(with: u) { [weak self] data, _, err in
            guard let self = self else { return }
            guard err == nil, let d = data, let img = NSImage(data: d) else {
                DispatchQueue.main.async { self.toast("复制图片失败（图片取不到）", ok: false) }
                return
            }
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([img])
                pb.setString(absUrl, forType: .string)          // 兜底：文本形式也留一份
                self.clipChangeCount = pb.changeCount
                self.pushClip(absUrl, force: true)
                self.toast("图片已复制到剪贴板")
            }
        }.resume()
    }

    // MARK: - 附件下载（选了存哪儿 → 原生下载 → 进度显示在窗口标题上）

    private func startDownload(_ urlStr: String, name: String) {
        guard let u = URL(string: urlStr) else { toast("下载地址无效", ok: false); return }
        let panel = NSSavePanel()
        panel.title = "保存附件"
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Downloader.sanitize(name.isEmpty ? "attachment" : name)
        if let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = dl
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            // 用户在「保存」面板点了取消 ⇒ 静默，什么都不说（与 Windows 客户端一致）
            guard resp == .OK, let dest = panel.url else { return }
            self?.downloader.start(u, dest: dest)
        }
        if let win = view.window {
            panel.beginSheetModal(for: win, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    fileprivate func downloadDidStart(dest: URL) {
        view.window?.title = "正在下载 → \(dest.lastPathComponent)"
    }

    fileprivate func downloadProgress(_ p: Float) {
        // 用窗口标题显示进度：这是 macOS 的原生习惯（Safari 也这么干），不用另画一套 UI
        view.window?.title = String(format: "正在下载 %d%%", Int(p * 100))
    }

    fileprivate func downloadDidFinish(dest: URL) {
        view.window?.title = "铁牛社区"
        toast("已保存：\(dest.lastPathComponent)")
        // 在访达里选中刚下载的文件，用户一眼就知道存哪了
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }

    fileprivate func downloadDidFail(message: String) {
        view.window?.title = "铁牛社区"
        toast("下载失败：\(message)", ok: false)
    }

    // MARK: - 更新配置（version-macos.json）

    private func fetchUpdate() -> (body: String?, base: String?) {
        guard let base = resolveDownloadBase() else { return (nil, nil) }
        for p in Self.updateCfgPaths {
            guard let raw = httpGet(base + p, timeout: 8) else { continue }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("{") else { continue }
            guard (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil else { continue }
            return (t, base)
        }
        return (nil, base)
    }

    private func refreshUpdateConfig(notify: Bool) {
        if cfgFetching { return }
        cfgFetching = true
        pushAbout()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let r = self.fetchUpdate()
            DispatchQueue.main.async {
                self.cfgBody = r.body
                self.downloadBase = r.base
                self.cfgFetching = false
                self.pushAbout()
                if notify { self.notifyIfNewer() }
            }
        }
    }

    private func notifyIfNewer() {
        guard let body = cfgBody,
              let d = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let latest = (d["latest_version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !latest.isEmpty, latest != appVersion else { return }
        if notifiedVersion == latest { return }
        notifiedVersion = latest
        let notes = (d["release_notes"] as? String) ?? ""
        var urlStr = (d["macos_url"] as? String) ?? (d["download_url"] as? String) ?? ""
        urlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        // json 里只是**文件名** ⇒ 补上 <下载base>/update/ 才能真的打开
        if !urlStr.isEmpty, !urlStr.lowercased().hasPrefix("http"), let b = downloadBase {
            urlStr = b + "/update/" + urlStr
        }
        let a = NSAlert()
        a.messageText = "发现新版本 V\(latest)"
        a.informativeText = notes.isEmpty ? "当前 V\(appVersion)，建议更新。" : "当前 V\(appVersion)\n\n\(notes)"
        if !urlStr.isEmpty, let u = URL(string: urlStr) { a.addButton(withTitle: "前往下载") }
        a.addButton(withTitle: "以后再说")
        let resp = a.runModal()
        if resp == .alertFirstButtonReturn, let u = URL(string: urlStr) {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: - 遮罩

    private func setupMask(in root: NSView) {
        mask.wantsLayer = true
        mask.layer?.backgroundColor = Self.fallbackBg.cgColor
        mask.translatesAutoresizingMaskIntoConstraints = false
        mask.isHidden = true

        maskSpinner.style = .spinning
        maskSpinner.controlSize = .regular
        maskSpinner.isDisplayedWhenStopped = false
        maskSpinner.translatesAutoresizingMaskIntoConstraints = false
        maskSpinner.startAnimation(nil)

        maskLabel.font = .systemFont(ofSize: 15)
        maskLabel.textColor = NSColor(white: 0.72, alpha: 1)
        maskLabel.alignment = .center
        maskLabel.lineBreakMode = .byWordWrapping
        maskLabel.maximumNumberOfLines = 0
        maskLabel.translatesAutoresizingMaskIntoConstraints = false

        maskRetry.title = "重试"
        maskRetry.bezelStyle = .rounded
        maskRetry.target = self
        maskRetry.action = #selector(maskRetryTapped)
        maskRetry.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(mask)
        mask.addSubview(maskSpinner)
        mask.addSubview(maskLabel)
        mask.addSubview(maskRetry)

        NSLayoutConstraint.activate([
            mask.topAnchor.constraint(equalTo: root.topAnchor),
            mask.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mask.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mask.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            maskSpinner.centerXAnchor.constraint(equalTo: mask.centerXAnchor),
            maskSpinner.centerYAnchor.constraint(equalTo: mask.centerYAnchor, constant: -34),

            maskLabel.topAnchor.constraint(equalTo: maskSpinner.bottomAnchor, constant: 16),
            maskLabel.leadingAnchor.constraint(equalTo: mask.leadingAnchor, constant: 36),
            maskLabel.trailingAnchor.constraint(equalTo: mask.trailingAnchor, constant: -36),

            maskRetry.topAnchor.constraint(equalTo: maskLabel.bottomAnchor, constant: 20),
            maskRetry.centerXAnchor.constraint(equalTo: mask.centerXAnchor),
        ])
    }

    private func showMask(_ text: String, retry: Bool) {
        maskLabel.stringValue = text
        maskRetry.isHidden = !retry
        if retry { maskSpinner.stopAnimation(nil) } else { maskSpinner.startAnimation(nil) }
        mask.isHidden = false
    }

    @objc private func maskRetryTapped() { hideMask(); startDiscovery() }

    private func hideMask() { mask.isHidden = true }

    // MARK: - Toast

    private var toastView: NSView?

    private func toast(_ msg: String, ok: Bool = true) {
        let run = { [weak self] in
            guard let self = self else { return }
            self.toastView?.removeFromSuperview()
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 10
            box.layer?.backgroundColor = (ok ? NSColor(white: 0.13, alpha: 0.94)
                                             : NSColor.systemRed.withAlphaComponent(0.94)).cgColor
            box.translatesAutoresizingMaskIntoConstraints = false
            box.alphaValue = 0

            let lb = NSTextField(labelWithString: msg)
            lb.textColor = .white
            lb.font = .systemFont(ofSize: 13)
            lb.alignment = .center
            lb.lineBreakMode = .byWordWrapping
            lb.maximumNumberOfLines = 0
            lb.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(lb)
            self.view.addSubview(box)

            NSLayoutConstraint.activate([
                lb.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
                lb.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
                lb.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                lb.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
                box.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                box.bottomAnchor.constraint(equalTo: self.view.bottomAnchor, constant: -70),
                box.widthAnchor.constraint(lessThanOrEqualTo: self.view.widthAnchor, multiplier: 0.86),
            ])
            self.toastView = box
            box.animator().alphaValue = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    box.animator().alphaValue = 0
                }) {
                    box.removeFromSuperview()
                    if self.toastView === box { self.toastView = nil }
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }
}

// MARK: - 上行消息分发（与 iOS 完全相同的一套）

extension WebViewController: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        let id = body?["id"] as? String
        let args = (body?["args"] as? [Any]) ?? []
        let cmd = message.name.replacingOccurrences(of: "tieniu", with: "")

        switch cmd {
        case "OpenExternal":
            guard let s = args.first as? String, let u = URL(string: s) else { return }
            NSWorkspace.shared.open(u)

        case "Download":
            guard let s = args.first as? String, let u = URL(string: s) else { resolve(id, false); return }
            let name = (args.count > 1 ? (args[1] as? String) : nil) ?? ""
            resolve(id, true)                      // 先答「已受理」，与安卓/iOS 同语义
            startDownload(u.absoluteString, name: name)

        case "CopyImage":
            guard let s = args.first as? String else { resolve(id, false); return }
            resolve(id, true)
            copyImageToClipboard(s)

        case "CopyText":
            let t = (args.first as? String) ?? ""
            copyTextToClipboard(t)
            resolve(id, true)

        case "GetClipText":
            primeClipboard()
            resolve(id, cachedClip)

        case "CheckUpdate":
            refreshUpdateConfig(notify: false)

        default:
            break
        }
    }
}

// MARK: - 导航 / UI 代理

extension WebViewController: WKNavigationDelegate, WKUIDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoadingPage = false
        hideMask()
        clipChangeCount = -1                       // 页面重载后垫片缓存是空的 ⇒ 强制重推
        pushAbout()
        primeClipboard()
        syncAppBg()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.syncAppBg() }
        if !didStartupUpdateCheck {
            didStartupUpdateCheck = true
            refreshUpdateConfig(notify: true)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoadingPage = false
        if (error as NSError).code == NSURLErrorCancelled { return }
        showMask("页面加载失败：\(error.localizedDescription)", retry: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoadingPage = false
        // 🔴 放过 NSURLErrorCancelled(-999)：decidePolicyFor 里主动取消一次导航
        //    （外链交系统浏览器、target=_blank）也会走到这里 —— 不放过就会平白弹出
        //    「无法打开社区页面」遮罩，看着像服务器挂了。
        if (error as NSError).code == NSURLErrorCancelled { return }
        showMask("无法打开社区页面：\(error.localizedDescription)", retry: true)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = (url.scheme ?? "").lowercased()
        if ["http", "https"].contains(scheme) {
            if navigationAction.targetFrame == nil {         // target="_blank"
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // 主框架要跳到别的站 ⇒ 交系统浏览器，别把 WebView 带走（带走 = 没有返回按钮）
            let isMain = navigationAction.targetFrame?.isMainFrame ?? false
            let pageHost = (currentBase.flatMap { URL(string: $0)?.host }) ?? ""
            let toHost = url.host ?? ""
            if isMain, !pageHost.isEmpty, !toHost.isEmpty,
               toHost.caseInsensitiveCompare(pageHost) != .orderedSame {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }
        if ["about", "data", "blob", "file"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        NSWorkspace.shared.open(url)                        // tel: / mailto: / 自定义协议
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { NSWorkspace.shared.open(u) }
        return nil
    }

    /// `<input type="file">` —— WKWebView 必须实现这个，否则点附件/头像/上传图片**毫无反应**。
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        // 上一次面板没被正常收掉时，先把挂着的 completion 以 nil 结束掉，
        // 否则它会让下一次上传永远拿不到回调（「第二次点上传没反应」）。
        if let stale = filePickerCompletion {
            filePickerCompletion = nil
            stale(nil)
        }
        filePickerCompletion = completionHandler

        let panel = NSOpenPanel()
        panel.title = "选择要上传的图片 / 文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.allowsOtherFileTypes = true
        // 网页上的 accept 属性拿不到（WKOpenPanelParameters 公开 API 里没有），
        // 所以不做类型过滤 —— 让用户自己挑，服务端有白名单兜底。
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            let cb = self?.filePickerCompletion
            self?.filePickerCompletion = nil
            guard resp == .OK else { cb?(nil); return }
            cb?(panel.urls.isEmpty ? nil : panel.urls)
        }
        if let win = view.window {
            panel.beginSheetModal(for: win, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }
}

// MARK: - 下载器

/// 独立的下载器：`URLSession` 会**强引用** delegate，若让 WebViewController 直接当 delegate
/// 就成了保留环（VC 永不释放）。所以拆成一个单独的类，用 weak 回指。
private final class Downloader: NSObject, URLSessionDownloadDelegate {

    weak var owner: WebViewController?
    private var session: URLSession!
    private var jobs: [Int: URL] = [:]                  // taskIdentifier → 用户选的保存路径
    private let lock = NSLock()

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 1800
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func start(_ url: URL, dest: URL) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.downloadTask(with: req)
        let tid = task.taskIdentifier                  // 先取出 id：闭包延迟执行时 task 可能已结束
        lock.lock(); jobs[tid] = dest; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.owner?.downloadDidStart(dest: dest) }
        task.resume()
    }

    private func dest(for id: Int) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Float(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        DispatchQueue.main.async { [weak self] in self?.owner?.downloadProgress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        guard let dst = dest(for: id) else { return }
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
            try FileManager.default.moveItem(at: location, to: dst)
            DispatchQueue.main.async { [weak self] in self?.owner?.downloadDidFinish(dest: dst) }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.owner?.downloadDidFail(message: "写文件失败（\(dst.lastPathComponent)）")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock(); jobs.removeValue(forKey: id); lock.unlock()
        guard let error = error else { return }
        DispatchQueue.main.async { [weak self] in
            self?.owner?.downloadDidFail(message: error.localizedDescription)
        }
    }

    /// 落盘文件名：与网页层/服务端同一套「先 \→/ 再取 basename」的清理规则（铁律 107）
    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "\\", with: "/")
        if let last = s.split(separator: "/").last { s = String(last) }
        s = s.replacingOccurrences(of: ":", with: "_")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "attachment" : s
    }
}

// MARK: - 弱引用消息处理器

/// `WKUserContentController` 会**强引用** handler ⇒ 直接用 self 会造成保留环。
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
