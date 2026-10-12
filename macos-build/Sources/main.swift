//
//  main.swift
//  铁牛社区 · macOS 桌面版客户端
//
//  纯代码启动（不用 Storyboard / xib）：文件名就叫 main.swift，Swift 会把它当**顶层入口**，
//  这样连 `@main` 属性都不用写。
//
//  ⚠️ delegate 必须用顶层 `let` 持有：`NSApplication.delegate` 是 **weak**，
//     写成 `app.delegate = AppDelegate()` 会被当场释放，表现为「启动后什么都没发生」。
//

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)      // 有 Dock 图标、能进菜单栏的普通 App
app.run()
