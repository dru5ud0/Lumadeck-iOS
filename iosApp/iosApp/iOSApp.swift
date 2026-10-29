import SwiftUI
import ComposeApp

@main
struct iOSApp: App {
    @UIApplicationDelegateAdaptor(OrientationLockAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let state = AirPlayMockHarness.requestedState {
                AirPlayMockRootView(state: state)
                    .preferredColorScheme(.dark)
            } else {
                appContent
            }
#else
            appContent
#endif
        }
    }

    private var appContent: some View {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    AppUrlBridgeKt.handleAppUrl(url: url.absoluteString)
                }
    }
}
