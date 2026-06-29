import SwiftUI
import UIKit

// M9: register for remote notifications so CKQuerySubscription silent pushes
// are delivered to the app. This is optional — the HomeView 1s poll loop
// guarantees convergence even when push is unavailable (no APNs token,
// Low Power Mode, background throttling). APNs only trims latency.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ app: UIApplication,
        didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        app.registerForRemoteNotifications()
        return true
    }
}

@main
struct MetamorphiaRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
