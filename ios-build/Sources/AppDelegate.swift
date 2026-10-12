import UIKit

/// 纯代码启动：不依赖 Storyboard / Scene，避免多一份容易写错的文件。
/// （不声明 UIApplicationSceneManifest 时，iOS 会走经典的 AppDelegate + window 路径。）
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)
        win.rootViewController = WebViewController()
        win.makeKeyAndVisible()
        window = win
        return true
    }
}
