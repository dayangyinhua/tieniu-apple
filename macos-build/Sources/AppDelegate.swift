//
//  AppDelegate.swift
//  铁牛社区 · macOS 桌面版客户端
//
//  职责很窄：建菜单栏、开一个窗口、把 WebViewController 装进去。
//  真正的活儿（WKWebView + TieniuApp 桥）在 WebViewController.swift。
//
//  🔴🔴 **菜单栏里的「编辑」菜单不是装饰，是必需品**：
//     macOS 的 Cmd+C / Cmd+V / Cmd+A / Cmd+Z 全都是**走菜单 → 响应链**
//     （`copy:` / `paste:` 这些 action 发给第一响应者）。
//     不建这个菜单，用户在帖子里**根本没法用快捷键复制粘贴** ——
//     而且不会报任何错，只是「按了没反应」，最难查的那种。
//

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var controller: WebViewController!
    private var windowMenu: NSMenu!

    private let appName = "铁牛社区"

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        controller = WebViewController()

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        w.contentViewController = controller
        w.title = appName
        w.minSize = NSSize(width: 760, height: 560)
        // 记住上次的窗口大小和位置（下次打开还是原来的样子）
        w.setFrameAutosaveName("TieniuMainWindow")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w

        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关掉最后一个窗口就退出（不是「留在 Dock 里空转」）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// 点 Dock 图标且窗口已关时，重新开一个
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: - 菜单

    @objc private func aboutTapped() {
        controller?.showAboutDialog()
    }

    @objc private func reloadTapped() {
        controller?.reload()
    }

    @objc private func zoomInTapped()  { controller?.zoom(delta: 0.1) }
    @objc private func zoomOutTapped() { controller?.zoom(delta: -0.1) }
    @objc private func zoomResetTapped() { controller?.zoom(delta: 0) }
    @objc private func copyAddressTapped() { controller?.copyServerAddress() }

    private func buildMainMenu() {
        let main = NSMenu()

        // ---- 应用菜单（第一个菜单项的名字由系统用 CFBundleName 顶替，这里给什么都无所谓）
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(aboutTapped), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: "隐藏 \(appName)",
                                       action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        let showAll = appMenu.addItem(withTitle: "显示全部",
                                      action: #selector(NSApplication.unhideAllApplications(_:)),
                                      keyEquivalent: "")
        showAll.target = NSApp
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "退出 \(appName)",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        // ---- 编辑菜单（🔴 见文件头：Cmd+C/V/A/Z 全靠它，target 留 nil = 走响应链）
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // ---- 显示菜单
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "显示")
        viewItem.submenu = view
        let reload = view.addItem(withTitle: "重新载入", action: #selector(reloadTapped), keyEquivalent: "r")
        reload.target = self
        view.addItem(.separator())
        let zin = view.addItem(withTitle: "放大", action: #selector(zoomInTapped), keyEquivalent: "+")
        zin.target = self
        let zout = view.addItem(withTitle: "缩小", action: #selector(zoomOutTapped), keyEquivalent: "-")
        zout.target = self
        let zreset = view.addItem(withTitle: "实际大小", action: #selector(zoomResetTapped), keyEquivalent: "0")
        zreset.target = self
        view.addItem(.separator())
        let full = view.addItem(withTitle: "进入全屏幕",
                                action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        full.target = nil

        // ---- 窗口菜单（设成 NSApp.windowsMenu，系统会自动往里塞窗口列表）
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "窗口")
        winItem.submenu = win
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        let front = win.addItem(withTitle: "前置全部窗口",
                                action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        front.target = NSApp
        windowMenu = win

        // ---- 帮助菜单（「复制社区地址」：成员之间互发地址用得上）
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let help = NSMenu(title: "帮助")
        helpItem.submenu = help
        let copyAddr = help.addItem(withTitle: "复制社区地址",
                                    action: #selector(copyAddressTapped), keyEquivalent: "")
        copyAddr.target = self

        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
}
