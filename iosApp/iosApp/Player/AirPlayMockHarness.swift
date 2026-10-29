#if DEBUG
import SwiftUI
import UIKit

enum AirPlayMockState: String, CaseIterable {
    case connecting
    case playing
    case paused
    case preparingRelay = "preparing-relay"
    case compatibility
    case reconnecting
    case live
    case ended
    case failed
    case longTitle = "long-title"
}

enum AirPlayMockHarness {
    static var requestedState: AirPlayMockState? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--airplay-mock"), arguments.indices.contains(index + 1) {
            return AirPlayMockState(rawValue: arguments[index + 1])
        }
        let prefix = "--airplay-mock="
        guard let value = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return AirPlayMockState(rawValue: String(value.dropFirst(prefix.count)))
    }

    static func makeController(state: AirPlayMockState) -> UIViewController {
        let controller = AirPlayPlayerViewController()
        controller.modalPresentationStyle = .fullScreen
        controller.configure(
            displayTitle: "Lumadeck AirPlay Test",
            knownDurationMs: 7_200_000,
            initialPositionMs: 1_845_000,
            playWhenReady: state == .playing || state == .compatibility || state == .live || state == .longTitle
        )
        controller.applyMockState(state)
        return controller
    }
}

struct AirPlayMockRootView: UIViewControllerRepresentable {
    let state: AirPlayMockState

    func makeUIViewController(context: Context) -> UIViewController {
        AirPlayMockHarness.makeController(state: state)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#endif
