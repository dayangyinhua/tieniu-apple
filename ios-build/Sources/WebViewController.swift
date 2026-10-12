//
//  WebViewController.swift
//  铁牛NAS共享社区 · iOS 客户端
//
//  ======================== 这份文件在干什么 ========================
//
//  一句话：**把网页版原封不动装进 WKWebView，同时在页面里伪造出安卓那套 `TieniuApp` 桥。**
//
//  为什么不是「照着 Android 的 MainActivity 重写一遍原生界面」？
//    因为服务端下发的 `client/web/index.html` 就是手机端的**唯一界面源码**
//    （飞牛网页版、安卓 App、Windows 客户端共用同一份），所有手机端 UI/行为都已经
//    在里面了。重写原生界面 = 从此每改一次界面就要改两遍，必然跑偏。
//
//  ======================== 桥契约（🔴 必须与安卓逐位一致） ========================
//
//  网页层是**同步调用**桥的（见 index.html）：
//      b.getClipText()        → 直接要一个 String（同步）
//      b.copyText(t) === true → 要立刻拿到布尔值
//      b.copyImage(abs)       → 只表示「请求已受理」（原生自己弹提示）
//      b.download(u, name)    → 同上，返回 true 之后原生自己接管
//      b.getAboutInfo()       → 直接要一个 JSON 字符串（同步）
//      b.openExternal(u) / b.checkUpdateNow() → 点火即忘
//
//  而 WKWebView 的 `postMessage` **只能异步、无返回值**。
//  ⇒ 唯一不改网页层的办法：**注入 JS 垫片**（下面的 JS_SHIM）
//      · 垫片在 documentStart 就注册好 `window.TieniuApp`，方法名/签名与安卓一模一样；
//      · 需要返回值的（getClipText / getAboutInfo）由**原生主动 push** 到垫片的缓存里，
//        垫片同步读缓存返回 —— 这就是「同步桥」在 WKWebView 上的实现方式；
//      · 需要「点火即忘」的直接 postMessage 上行，原生干完活自己弹提示。
//
//  ⚠️ 桥方法**少一个**，网页层就会整体降级（例如 `appShellState()` 变成 "old"、
//     「关于程序」看不到 App 版本、附件下载直接失败）。改动前先看 index.html 的调用点。
//
//  ======================== 服务地址发现（与安卓同一套） ========================
//
//  飞牛的图标 URL 写不进 IP/域名（铁律 88）⇒ **不能硬编码服务器地址**。
//  统一走 DoH TXT：`dns.alidns.com` 解析 `tieniu.ebaymall.cn` → `host:port` → 探活 → 加载。
//  下载资源基址同理，解析 `download.ebaymall.cn`。
//

import UIKit
import WebKit
import UniformTypeIdentifiers
import PhotosUI

final class WebViewController: UIViewController {

    // MARK: - 常量（与 apk-build/.../MainActivity.java 对齐）

    /// 论坛服务器地址（DoH TXT）
    private static let dohForumURL = "https://dns.alidns.com/resolve?name=tieniu.ebaymall.cn&type=TXT"
    /// 下载 / 更新资源基础地址（DoH TXT）
    private static let dohDownloadURL = "https://dns.alidns.com/resolve?name=download.ebaymall.cn&type=TXT"
    /// 更新配置候选：优先 iOS 专用 json，回落通用 json（逐条尝试，取第一个能解析的）
    private static let updateCfgPaths = ["/update/version-ios.json", "/update/version-luntan.json"]
    /// 探活超时（秒）
    private static let probeTimeout: TimeInterval = 3.5
    /// 桥的 6 个上行通道名（垫片里 postMessage 用的名字 = "tieniu" + Cmd）
    private static let handlerNames = [
        "tieniuOpenExternal", "tieniuDownload", "tieniuCopyImage",
        "tieniuCopyText", "tieniuGetClipText", "tieniuCheckUpdate",
    ]
    /// 兜底底色 = 网页默认主题的 `--app-bg`（安卓那边也是写死这个值）。
    /// ⚠️ 网页主题是**用户可切换**的（`--app-bg` 由 applyTheme 按 hue/sat 重算），
    ///    所以这里只是「页面还没告诉我们之前」的兜底，真正的值靠 syncAppBg() 从页面读。
    private static let fallbackBg = UIColor(red: 4 / 255.0, green: 6 / 255.0, blue: 12 / 255.0, alpha: 1)
    private static let accentCyan = UIColor(red: 0.216, green: 0.741, blue: 0.973, alpha: 1)   // #38bdf8

    // MARK: - 状态

    private var webView: WKWebView!
    private let downloader = Downloader()

    /// 剪贴板镜像：垫片里的 `getClipText()` 同步读它（WKWebView 没有同步桥，只能预取）
    private var cachedClip: String?
    /// version-ios.json 的**原文**（「关于程序」要原样展示 release_notes）
    private var cfgBody: String?
    /// 本次用到的下载资源基址（形如 http://host:port，用来把 json 里的文件名拼成完整地址）
    private var downloadBase: String?
    /// 正在抓配置 ⇒ 页面来问要答 `pending`，否则会拿上一次的旧说明充当这一次
    private var cfgFetching = false
    /// 已经弹过「发现新版本」的版本号（每个版本只打扰一次）
    private var notifiedVersion: String?

    // MARK: 遮罩（连接中 / 出错重试）

    private let mask = UIView()
    private let maskLabel = UILabel()
    private let maskSpinner = UIActivityIndicatorView(style: .medium)
    private let maskRetry = UIButton(type: .system)

    private var currentBase: String?
    private var isLoadingPage = false
    /// 启动后的自动更新检查只做一次（放在页面加载完之后，免得弹窗压在「正在连接」遮罩上）
    private var didStartupUpdateCheck = false
    /// 当前原生底色是不是深色（决定状态栏文字用白还是黑）
    private var isDarkChrome = true

    // 文件选择（runOpenPanelWith）
    private var filePickerCompletion: (([URL]?) -> Void)?

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.fallbackBg
        downloader.owner = self
        setupWebView()
        setupMask()
        startDiscovery()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        isDarkChrome ? .lightContent : .darkContent
    }

    // MARK: - 原生底色跟随网页主题
    //
    // 网页是可换主题的（`--app-bg` 由 applyTheme 重算），而 iOS 的「安全区条 + 启动白闪」
    // 露的是**原生**背景色。写死一个色号的话，用户切成浅色主题就会上下各挂一条深色带。
    // 所以：页面加载完 / 回到前台时，**从页面把当前的 --app-bg 读回来**。
    // （只读不写，读失败就保持上一个值 —— 不会因为网页改版把客户端搞崩。）

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
        view.backgroundColor = c
        webView?.backgroundColor = c
        webView?.scrollView.backgroundColor = c
        mask.backgroundColor = c
        maskLabel.textColor = dark ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.32, alpha: 1)
        maskRetry.tintColor = dark ? Self.accentCyan : UIColor(red: 0.10, green: 0.36, blue: 0.80, alpha: 1)
        if dark != isDarkChrome {
            isDarkChrome = dark
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    /// "#0a0b0c" / "0a0b0c" / "#abc" → UIColor
    private static func parseHexColor(_ s: String) -> UIColor? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("#") { t.removeFirst() }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }     // #abc → #aabbcc
        guard t.count == 6, t.allSatisfy({ $0.isHexDigit }), let v = UInt32(t, radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0,
                       alpha: 1)
    }

    /// sRGB 近似相对亮度 —— 判断该配白字还是黑字
    private static func isDarkColor(_ c: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.5
    }

    // MARK: - WebView 构建

    private func setupWebView() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        // UA 尾巴带上 TieniuApp/1.0.0 —— 网页层的 appShellState() 会拿它兜底识别
        // （主判据仍是 getAboutInfo 是否存在，这里只是双保险）
        cfg.applicationNameForUserAgent = "TieniuApp/\(appVersion)"
        cfg.userContentController.addUserScript(makeShimScript())

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.backgroundColor = Self.fallbackBg
        wv.scrollView.backgroundColor = Self.fallbackBg
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView = wv

        for name in Self.handlerNames {
            cfg.userContentController.add(WeakMessageHandler(self), name: name)
        }

        // 一次性的剪贴板预取时机：回到前台 / 页面重新获得焦点。
        // （iOS 16+ 读系统剪贴板会弹一次「允许粘贴？」—— 只在用户「刚切回来、多半是要粘贴」
        //   的时刻读，比在任何时候都读要合理得多。）
        NotificationCenter.default.addObserver(
            self, selector: #selector(onForeground),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        // ⚠️ 更新检查**不在这里**做：此时页面还没加载完，pushAbout 会 push 进一个即将被
        //    导航销毁的旧文档里（白推），弹「发现新版本」也会压在「正在连接」遮罩上。
        //    挪到 didFinish（见 didStartupUpdateCheck）。
    }

    @objc private func onForeground() {
        primeClipboard()
        syncAppBg()                                  // 用户可能在别处切了主题
        // 卡在「连不上」的遮罩上就自动重试一次 —— 用户锁屏解锁、切 Wi-Fi 后不用手动点
        if !mask.isHidden && !maskRetry.isHidden { startDiscovery() }
    }

    // MARK: - JS 垫片（🔴 与安卓同名同签名，网页层一行都不用改）

    private func makeShimScript() -> WKUserScript {
        let js = Self.jsShim.replacingOccurrences(of: "__TIENIU_APP_VER__", with: appVersion)
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// ⚠️ 改动这里等于改桥契约 —— 方法名必须与安卓 `TieniuApp` 完全一致。
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
        guard let b = currentBase, let url = URL(string: b + "/") else { return }
        isLoadingPage = true
        _ = webView.load(URLRequest(url: url))
    }

    private func retryTapped() {
        hideMask()
        startDiscovery()
    }

    // MARK: - 网络小工具（DoH / 探活 / GET）

    /// DoH 解析 TXT，取第一条含 ":" 的值，返回 "host:port"
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

    /// 探活：能拿到 2xx~4xx 就算活（4xx 也说明服务器在）
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

    /// 把一个 Swift 值写成 JS 字面量（字符串走 JSON 编码，避免引号/换行/中文出问题）
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

    private func pushClip(_ s: String) {
        cachedClip = s
        evalJS("window.__tieniuSetClip && window.__tieniuSetClip(\(jsLiteral(s)));")
    }

    private func pushAbout() {
        var o: [String: Any] = ["app_version": appVersion, "shell": "ok"]
        if cfgFetching || cfgBody == nil {
            o["pending"] = true
        }
        if let body = cfgBody,
           let d = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
            o["latest_version"] = d["latest_version"] ?? ""
            o["release_notes"] = d["release_notes"] ?? ""
            o["published_at"] = d["published_at"] ?? ""
            o["ios_url"] = d["ios_url"] ?? d["download_url"] ?? ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: data, encoding: .utf8) else { return }
        evalJS("window.__tieniuSetAbout && window.__tieniuSetAbout(\(jsLiteral(json)));")
    }

    // MARK: - 剪贴板

    /// 预取系统剪贴板到缓存（垫片的 `getClipText()` 同步读它）。
    /// ⚠️ iOS 16+ 首次读取会弹「允许粘贴？」—— 只在「回到前台 / 页面重新获得焦点」时调，
    ///    这个时机正好是用户「刚从别的 App 复制完内容回来」的时刻。
    private func primeClipboard() {
        let pb = UIPasteboard.general
        guard pb.hasStrings else { pushClip(""); return }
        let s = pb.string ?? ""
        if cachedClip == s { return }
        pushClip(s)
    }

    private func copyTextToClipboard(_ t: String) {
        UIPasteboard.general.string = t
        pushClip(t)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        toast("已复制到剪贴板")
    }

    /// 「复制图片」：下载 → 写进系统剪贴板（同时留一份图片 URL 文本，
    /// 这样粘贴端即使只读文本也能还原 —— 与网页层 copyImageToClipboard 的设计一致）
    private func copyImageToClipboard(_ absUrl: String) {
        guard let u = URL(string: absUrl) else { toast("图片地址无效", ok: false); return }
        toast("正在复制图片…")
        URLSession.shared.dataTask(with: u) { [weak self] data, _, err in
            guard let self = self else { return }
            guard err == nil, let d = data, let img = UIImage(data: d),
                  let png = img.pngData() else {
                DispatchQueue.main.async { self.toast("复制图片失败（图片取不到）", ok: false) }
                return
            }
            DispatchQueue.main.async {
                var item: [String: Any] = [:]
                item[UTType.png.identifier] = png
                item[UTType.utf8PlainText.identifier] = absUrl
                UIPasteboard.general.items = [item]
                self.pushClip(absUrl)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.toast("图片已复制到剪贴板")
            }
        }.resume()
    }

    // MARK: - 更新配置（version-ios.json）

    private func resolveDownloadBase() -> String? {
        guard let v = dohTxt(Self.dohDownloadURL), !v.isEmpty else { return nil }
        var s = v.lowercased().hasPrefix("http") ? v : "http://" + v
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 抓 `<下载base>/update/` 下的更新配置原文 + 顺带把这次的下载基址带回来。
    /// 只在后台线程调用。
    /// 🔴 必须把 base 一起带出来：`version-ios.json` 里的 `ios_url` 只是**文件名**，
    ///    要拼成能打开的完整地址就得知道 base —— 而 base 是走 DoH 拿的（阻塞），
    ///    绝不能在主线程再解析一次。
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

    /// `notify: true` = 启动时的自动检查（发现新版本会弹一次原生提示）；
    /// `notify: false` = 用户点了「关于程序」触发的（页面自己会渲染，不再打扰）。
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
        var urlStr = (d["ios_url"] as? String) ?? (d["download_url"] as? String) ?? ""
        urlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        // json 里的 ios_url 只是文件名 ⇒ 补上 <下载base>/update/ 前缀才能真的打开
        if !urlStr.isEmpty, !urlStr.lowercased().hasPrefix("http"), let b = downloadBase {
            urlStr = b + "/update/" + urlStr
        }
        let alert = UIAlertController(
            title: "发现新版本 V\(latest)",
            message: notes.isEmpty ? "当前 V\(appVersion)，建议更新。" : "当前 V\(appVersion)\n\n\(notes)",
            preferredStyle: .alert)
        if !urlStr.isEmpty, let u = URL(string: urlStr) {
            alert.addAction(UIAlertAction(title: "前往下载", style: .default) { _ in
                _ = UIApplication.shared.open(u)
            })
        }
        alert.addAction(UIAlertAction(title: "以后再说", style: .cancel))
        topPresenter()?.present(alert, animated: true)
    }

    // MARK: - 附件下载（走原生 URLSession，绕开 WebView 的下载限制）

    private func startDownload(_ urlStr: String, name: String) {
        guard let u = URL(string: urlStr) else { toast("下载地址无效", ok: false); return }
        downloader.start(u, name: name)
    }

    fileprivate func downloadDidStart(taskId: Int, name: String) {
        let n = name.isEmpty ? "附件" : name
        showHUD("正在下载 \(n)…", progress: 0)
    }

    fileprivate func downloadProgress(taskId: Int, progress: Float) {
        updateHUD(progress)
    }

    fileprivate func downloadDidFinish(taskId: Int, fileURL: URL) {
        hideHUD()
        toast("下载完成，请选择保存位置")
        presentShareSheet(for: fileURL)
    }

    fileprivate func downloadDidFail(taskId: Int, message: String) {
        hideHUD()
        toast("下载失败：\(message)", ok: false)
    }

    /// 分享面板：系统会给出「存储到文件 / 存储到照片 / 分享到…」—— 这是 iOS 上唯一
    /// 让用户自己决定存哪儿、且随时能再找到的方式（对应安卓那边的「下载记录」列表）。
    /// 正在弹别的面板时（比如刚下完的那一下有 Toast/弹窗在）退避重试几次，别把结果吞掉。
    private func presentShareSheet(for fileURL: URL, attempt: Int = 0) {
        guard let top = topPresenter() else { return }
        if top.presentedViewController != nil && attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.presentShareSheet(for: fileURL, attempt: attempt + 1)
            }
            return
        }
        let av = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true)
    }

    private func topPresenter() -> UIViewController? {
        var vc: UIViewController? = self
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    // MARK: - 遮罩（连接中 / 出错重试）

    private func setupMask() {
        mask.backgroundColor = Self.fallbackBg
        mask.translatesAutoresizingMaskIntoConstraints = false
        mask.isHidden = true

        maskSpinner.translatesAutoresizingMaskIntoConstraints = false
        maskSpinner.color = UIColor(white: 0.72, alpha: 1)
        maskSpinner.startAnimating()

        maskLabel.translatesAutoresizingMaskIntoConstraints = false
        maskLabel.numberOfLines = 0
        maskLabel.textAlignment = .center
        maskLabel.font = .systemFont(ofSize: 15)
        maskLabel.textColor = UIColor(white: 0.72, alpha: 1)
        maskLabel.text = "正在连接社区服务器…"

        maskRetry.translatesAutoresizingMaskIntoConstraints = false
        maskRetry.setTitle("重试", for: .normal)
        maskRetry.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        maskRetry.tintColor = Self.accentCyan
        maskRetry.isHidden = true
        maskRetry.addTarget(self, action: #selector(maskRetryTapped), for: .touchUpInside)

        view.addSubview(mask)
        mask.addSubview(maskSpinner)
        mask.addSubview(maskLabel)
        mask.addSubview(maskRetry)

        NSLayoutConstraint.activate([
            mask.topAnchor.constraint(equalTo: view.topAnchor),
            mask.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mask.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mask.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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
        maskLabel.text = text
        maskRetry.isHidden = !retry
        if retry { maskSpinner.stopAnimating() } else { maskSpinner.startAnimating() }
        mask.isHidden = false
        mask.superview?.bringSubviewToFront(mask)
        view.bringSubviewToFront(mask)
    }

    private func hideMask() {
        mask.isHidden = true
    }

    @objc private func maskRetryTapped() { retryTapped() }

    // MARK: - Toast / HUD

    private var toastView: UIView?

    private func toast(_ msg: String, ok: Bool = true) {
        let run = { [weak self] in
            guard let self = self else { return }
            self.toastView?.removeFromSuperview()
            let box = UIView()
            // 固定深色胶囊 + 白字：不跟随系统浅色/深色 —— 深色浮在深色页 / 浅色页上都清楚
            box.backgroundColor = ok ? UIColor(white: 0.13, alpha: 0.94)
                                     : UIColor.systemRed.withAlphaComponent(0.94)
            box.layer.cornerRadius = 10
            box.translatesAutoresizingMaskIntoConstraints = false
            box.alpha = 0

            let lb = UILabel()
            lb.text = msg
            lb.textColor = .white
            lb.font = .systemFont(ofSize: 14)
            lb.numberOfLines = 0
            lb.textAlignment = .center
            lb.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(lb)
            self.view.addSubview(box)

            NSLayoutConstraint.activate([
                lb.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
                lb.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
                lb.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
                lb.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
                box.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                box.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -70),
                box.widthAnchor.constraint(lessThanOrEqualTo: self.view.widthAnchor, multiplier: 0.86),
            ])
            self.toastView = box
            UIView.animate(withDuration: 0.15) { box.alpha = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
                UIView.animate(withDuration: 0.25, animations: { box.alpha = 0 }) { _ in
                    box.removeFromSuperview()
                    if self.toastView === box { self.toastView = nil }
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    private var hudView: UIView?
    private var hudBar: UIView?
    private var hudBarWidth: NSLayoutConstraint?
    private var hudLabel: UILabel?
    private var hudTitle = "正在下载"
    /// HUD 进度条的轨道内宽（= 面板宽 240 − 左右各 16 的间距）。用固定值而不是
    /// 读 `bounds.width`：进度的第一帧往往早于布局完成，读出来是 0，进度条就不动了。
    private static let hudTrackWidth: CGFloat = 208

    private func showHUD(_ text: String, progress: Float) {
        hideHUD()
        hudTitle = text
        let box = UIView()
        box.backgroundColor = UIColor(white: 0.13, alpha: 0.94)
        box.layer.cornerRadius = 12
        box.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(box)

        let lb = UILabel()
        lb.text = text
        lb.textColor = .white
        lb.font = .systemFont(ofSize: 13, weight: .medium)
        lb.numberOfLines = 2
        lb.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(lb)

        let track = UIView()
        track.backgroundColor = UIColor(white: 1, alpha: 0.25)
        track.layer.cornerRadius = 2
        track.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(track)

        let bar = UIView()
        bar.backgroundColor = Self.accentCyan
        bar.layer.cornerRadius = 2
        bar.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(bar)

        let barW = bar.widthAnchor.constraint(equalToConstant: 2)
        NSLayoutConstraint.activate([
            lb.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            lb.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            lb.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),

            track.topAnchor.constraint(equalTo: lb.bottomAnchor, constant: 10),
            track.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            track.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            track.heightAnchor.constraint(equalToConstant: 4),
            track.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),

            bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            bar.topAnchor.constraint(equalTo: track.topAnchor),
            bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            barW,

            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 240),
        ])
        hudView = box; hudBar = bar; hudBarWidth = barW; hudLabel = lb
        updateHUD(progress)
    }

    private func updateHUD(_ p: Float) {
        guard let hudBarWidth = hudBarWidth else { return }
        let clamped = CGFloat(min(max(p, 0), 1))
        hudBarWidth.constant = max(2, Self.hudTrackWidth * clamped)
        hudLabel?.text = hudTitle + (p > 0 ? String(format: " · %d%%", Int(clamped * 100)) : "")
    }

    private func hideHUD() {
        hudView?.removeFromSuperview()
        hudView = nil; hudBar = nil; hudBarWidth = nil; hudLabel = nil
    }
}

// MARK: - 上行消息分发

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
            UIApplication.shared.open(u)

        case "Download":
            guard let s = args.first as? String, let u = URL(string: s) else { resolve(id, false); return }
            let name = (args.count > 1 ? (args[1] as? String) : nil) ?? ""
            resolve(id, true)                      // 先答「已受理」，与安卓同语义
            startDownload(u.absoluteString, name: name)

        case "CopyImage":
            guard let s = args.first as? String else { resolve(id, false); return }
            resolve(id, true)                      // 同上：真正的成败由原生 Toast 告知
            copyImageToClipboard(s)

        case "CopyText":
            let t = (args.first as? String) ?? ""
            copyTextToClipboard(t)
            resolve(id, true)

        case "GetClipText":
            primeClipboard()
            resolve(id, cachedClip ?? "")

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
        pushAbout()
        primeClipboard()
        syncAppBg()
        // applyTheme() 是页面启动时才跑的 ⇒ 隔一会儿再读一次，把第一次可能读到的兜底值纠正过来
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.syncAppBg() }
        // 页面就绪了才做启动时的更新检查（顺带保证 pushAbout 的接收方已经存在）
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
        // 🔴 必须放过 NSURLErrorCancelled(-999)：decidePolicyFor 里主动取消一次导航
        //    （外链交系统浏览器、target=_blank）也会走到这里 —— 不放过就会在页面上
        //    平白弹出一个「无法打开社区页面」的遮罩，看着像服务器挂了。
        if (error as NSError).code == NSURLErrorCancelled { return }
        showMask("无法打开社区页面：\(error.localizedDescription)", retry: true)
    }

    /// 外链 / 非 http(s) 协议一律交系统处理，站内导航放行。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = (url.scheme ?? "").lowercased()
        if ["http", "https"].contains(scheme) {
            if navigationAction.targetFrame == nil {         // target="_blank"
                _ = UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            // 主框架要跳到**别的站**（不是我们的服务器）⇒ 交系统浏览器，别把 WebView
            // 带走（带走之后就是个没有返回键的空白页，用户只能杀进程）。
            let isMain = navigationAction.targetFrame?.isMainFrame ?? false
            let pageHost = (currentBase.flatMap { URL(string: $0)?.host }) ?? ""
            let toHost = url.host ?? ""
            if isMain, !pageHost.isEmpty, !toHost.isEmpty,
               toHost.caseInsensitiveCompare(pageHost) != .orderedSame {
                _ = UIApplication.shared.open(url)
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
        _ = UIApplication.shared.open(url)                   // tel: / mailto: / 自定义协议
        decisionHandler(.cancel)
    }

    /// `window.open()` —— WebView 里开不了新窗口，交系统浏览器。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { UIApplication.shared.open(u) }
        return nil
    }

    /// `<input type="file">` —— WKWebView 必须实现这个，否则点附件/头像/上传图片**毫无反应**。
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        // 上一次面板被「点空白处」收掉时，它的 completion 可能还挂着没被调 —— 先把它
        // 以 nil 结束掉（等于取消那个 input），否则挂着的那个会让下一次上传永远拿不到回调，
        // 表现就是「第二次点上传毫无反应」。
        if let stale = filePickerCompletion {
            filePickerCompletion = nil
            stale(nil)
        }
        filePickerCompletion = completionHandler

        let sheet = UIAlertController(title: "选择文件", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "照片图库", style: .default) { [weak self] _ in
            self?.pickFromPhotoLibrary(multiple: parameters.allowsMultipleSelection)
        })
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(title: "拍照", style: .default) { [weak self] _ in
                self?.pickFromCamera()
            })
        }
        sheet.addAction(UIAlertAction(title: "浏览文件", style: .default) { [weak self] _ in
            self?.pickFromFiles(multiple: parameters.allowsMultipleSelection)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.finishFilePick(nil)
        })
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        topPresenter()?.present(sheet, animated: true)
    }

    private func finishFilePick(_ urls: [URL]?) {
        let cb = filePickerCompletion
        filePickerCompletion = nil
        cb?(urls)
    }

    // MARK: 三个取文件来源

    /// 照片图库：PHPicker **不需要相册权限**（系统进程代选），所以不会弹权限框。
    private func pickFromPhotoLibrary(multiple: Bool) {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = multiple ? 0 : 1
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = self
        topPresenter()?.present(picker, animated: true)
    }

    private func pickFromCamera() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        topPresenter()?.present(picker, animated: true)
    }

    private func pickFromFiles(multiple: Bool) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.delegate = self
        topPresenter()?.present(picker, animated: true)
    }

    /// 把任意来源的图片/文件复制成本 App 临时目录里的文件，再交给 WebView 上传
    /// （WKWebView 只接受 file URL，且必须是它能读到的路径）
    fileprivate func stash(_ src: URL, ext: String?) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tieniu-upload", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = src.lastPathComponent
        if ext != nil && !name.lowercased().hasSuffix(ext!.lowercased()) { name += ext! }
        if name.isEmpty { name = "upload-\(Int(Date().timeIntervalSince1970))" }
        let dst = dir.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch {
            return nil
        }
    }
}

// MARK: - PHPickerViewController

extension WebViewController: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { finishFilePick(nil); return }
        let group = DispatchGroup()
        var out: [URL] = []
        let lock = NSLock()
        for (idx, r) in results.enumerated() {
            let provider = r.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
                defer { group.leave() }
                guard let self = self, let src = url else { return }
                var ext: String? = "." + src.pathExtension
                if src.pathExtension.isEmpty {
                    // PHPicker 给的临时文件常带真实扩展名；真没有就转成 JPEG
                    if let data = try? Data(contentsOf: src), let img = UIImage(data: data),
                       let jpg = img.jpegData(compressionQuality: 0.92) {
                        let dir = FileManager.default.temporaryDirectory
                            .appendingPathComponent("tieniu-upload", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        // 用 enumerate 拿到的 idx 做文件名 —— 别在读 out.count（另一个线程在写它）
                        let dst = dir.appendingPathComponent(
                            "photo-\(Int(Date().timeIntervalSince1970))-\(idx).jpg")
                        if (try? jpg.write(to: dst)) != nil {
                            lock.lock(); out.append(dst); lock.unlock()
                        }
                        return
                    }
                    // 转不出 JPEG ⇒ 别硬套个 .jpg 后缀（会把坏文件传给服务端），
                    // 保持原名、交给服务端按白名单扩展名去判断
                    ext = nil
                }
                if let dst = self.stash(src, ext: ext) {
                    lock.lock(); out.append(dst); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.finishFilePick(out.isEmpty ? nil : out)
        }
    }
}

// MARK: - UIImagePickerController（拍照）+ UIDocumentPicker

extension WebViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {

    func imagePickerController(_ picker: UIImagePickerController,
                              didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let img = info[.originalImage] as? UIImage, let jpg = img.jpegData(compressionQuality: 0.92) else {
            finishFilePick(nil); return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tieniu-upload", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("camera-\(Int(Date().timeIntervalSince1970)).jpg")
        try? jpg.write(to: dst)
        finishFilePick(FileManager.default.fileExists(atPath: dst.path) ? [dst] : nil)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        finishFilePick(nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // asCopy:true ⇒ 这些是已经拷进沙盒的副本，可直接给 WebView 用
        finishFilePick(urls.isEmpty ? nil : urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishFilePick(nil)
    }
}

// MARK: - 下载器

/// 独立的下载器：`URLSession` 会**强引用** delegate，若让 WebViewController 直接当 delegate
/// 就成了 self → session → self 的保留环（VC 永不释放）。所以拆成一个单独的类，用 weak 回指。
private final class Downloader: NSObject, URLSessionDownloadDelegate {

    weak var owner: WebViewController?
    private var session: URLSession!
    private var names: [Int: String] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 1800
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func start(_ url: URL, name: String) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.downloadTask(with: req)
        let tid = task.taskIdentifier          // 先把 id 取出来：闭包延迟执行时 task 可能已结束
        lock.lock(); names[tid] = name; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.owner?.downloadDidStart(taskId: tid, name: name)
        }
        task.resume()
    }

    private func name(for id: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return names[id] ?? ""
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Float(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let id = downloadTask.taskIdentifier
        DispatchQueue.main.async { [weak self] in self?.owner?.downloadProgress(taskId: id, progress: p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        var n = name(for: id)
        if n.isEmpty { n = downloadTask.response?.suggestedFilename ?? "attachment" }
        let dst = Downloader.tempDestination(for: n)
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
            try FileManager.default.moveItem(at: location, to: dst)
            DispatchQueue.main.async { [weak self] in self?.owner?.downloadDidFinish(taskId: id, fileURL: dst) }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.owner?.downloadDidFail(taskId: id, message: "文件保存失败")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock(); names.removeValue(forKey: id); lock.unlock()
        guard let error = error else { return }
        DispatchQueue.main.async { [weak self] in
            self?.owner?.downloadDidFail(taskId: id, message: error.localizedDescription)
        }
    }

    /// 落盘文件名：与网页层/服务端同一套「先 \→/ 再取 basename」的清理规则
    /// （Windows 上写 \\、Linux 上写 / 的差异踩过坑，见铁律 107）
    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "\\", with: "/")
        if let last = s.split(separator: "/").last { s = String(last) }
        s = s.replacingOccurrences(of: ":", with: "_")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "attachment" : s
    }

    static func tempDestination(for name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tieniu-dl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(sanitize(name))
    }
}

// MARK: - 弱引用消息处理器

/// `WKUserContentController` 会**强引用** handler ⇒ 直接用 self 会造成
/// userContentController → self → webView → configuration → userContentController 的保留环。
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
