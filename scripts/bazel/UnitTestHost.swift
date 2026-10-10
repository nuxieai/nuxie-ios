import UIKit

// Initialize UIKit and Metal without the runtime browser's SwiftUI scene.
// The authored unit suites create their own legacy UIWindow surfaces.
@main
final class BazelSDKUnitTestHost: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
