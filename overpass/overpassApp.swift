import SwiftUI
import MapKit

// AppDelegate exists solely to pre-warm MapKit before any SwiftUI view renders.
// Metal/MapKit initialization only fires when MKMapView enters a *visible* window
// hierarchy — creating it alone is not enough. We use a tiny near-invisible window
// to trigger the full GPU pipeline during the system's own launch sequence.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var prewarmWindow: UIWindow?
    private var sceneObserver: NSObjectProtocol?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Defer until the first window scene activates to use scene-based UIWindow(windowScene:).
        sceneObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let windowScene = notification.object as? UIWindowScene else { return }
            if let obs = sceneObserver { NotificationCenter.default.removeObserver(obs) }
            sceneObserver = nil
            setupPrewarm(windowScene: windowScene)
        }
        return true
    }

    private func setupPrewarm(windowScene: UIWindowScene) {
        let bounds = windowScene.screen.bounds
        let map = MKMapView(frame: bounds)
        let vc = UIViewController()
        vc.view.frame = bounds
        vc.view.addSubview(map)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = vc
        window.windowLevel = UIWindow.Level(rawValue: -1)
        window.alpha = 0.01
        window.isHidden = false
        prewarmWindow = window
        NativeMapView.prewarmedView = map
    }

    // Called from NativeMapView.makeUIView once the map is consumed.
    func teardownPrewarmWindow() {
        prewarmWindow?.isHidden = true
        prewarmWindow = nil
    }
}

@main
struct overpassApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var api = APIClient.shared
    @StateObject private var eia = EIAService.shared
    @StateObject private var store = StationStore.shared
    @StateObject private var routeStore = RouteStore.shared
    private let storeManager = StoreManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(api)
                .environmentObject(eia)
                .environmentObject(store)
                .environmentObject(routeStore)
                .task {
                    await eia.load(api: api)
                    await storeManager.load()
                }
                .fullScreenCover(isPresented: .init(
                    get: { !storeManager.hasAccess },
                    set: { _ in }
                )) {
                    PaywallView()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await BackgroundRefreshService.refreshIfNeeded() }
            }
        }
    }
}
