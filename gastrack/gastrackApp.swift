import SwiftUI
import MapKit

// AppDelegate exists solely to pre-warm MapKit before any SwiftUI view renders.
// Metal/MapKit initialization only fires when MKMapView enters a *visible* window
// hierarchy — creating it alone is not enough. We use a tiny near-invisible window
// to trigger the full GPU pipeline during the system's own launch sequence.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var prewarmWindow: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let screen = UIScreen.main.bounds
        let map = MKMapView(frame: screen)

        let vc = UIViewController()
        vc.view.frame = screen
        vc.view.addSubview(map)

        let window = UIWindow(frame: screen)
        window.rootViewController = vc
        window.windowLevel = UIWindow.Level(rawValue: -1)
        window.alpha = 0.01   // > 0 so Metal renders; imperceptible to users
        window.isHidden = false

        prewarmWindow = window
        NativeMapView.prewarmedView = map
        return true
    }

    // Called from NativeMapView.makeUIView once the map is consumed.
    func teardownPrewarmWindow() {
        prewarmWindow?.isHidden = true
        prewarmWindow = nil
    }
}

@main
struct gastrackApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var api = APIClient.shared
    @StateObject private var eia = EIAService.shared
    @StateObject private var store = StationStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(api)
                .environmentObject(eia)
                .environmentObject(store)
                .task { await eia.load(api: api) }
        }
    }
}
