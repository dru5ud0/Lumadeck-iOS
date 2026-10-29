#if DEBUG
import AVFoundation
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
    case routePicker = "route-picker"
    case playbackProbe = "playback-probe"
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
            knownDurationMs: state == .playbackProbe ? 12_000 : 7_200_000,
            initialPositionMs: state == .playbackProbe ? 0 : 1_845_000,
            playWhenReady: state == .playing || state == .compatibility || state == .live || state == .longTitle || state == .playbackProbe
        )
        if state == .playbackProbe, let url = requestedProbeURL {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
            controller.attach(player: player, item: item)
            player.play()
            return controller
        }
        controller.applyMockState(state)
        if state == .routePicker {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                controller.presentRoutePickerForTesting()
            }
        }
        return controller
    }

    private static var requestedProbeURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let index = arguments.firstIndex(of: "--airplay-probe-url"),
            arguments.indices.contains(index + 1)
        else { return nil }
        return URL(string: arguments[index + 1])
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
