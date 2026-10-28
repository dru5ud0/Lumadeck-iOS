import Foundation
import UIKit
import AVFoundation
import AVKit
import MediaPlayer
import Metal
import Libmpv
import ComposeApp

// MARK: - Player Bridge Implementation (Kotlin protocol conformance)

final class MPVPlayerBridgeImpl: NSObject, NuvioPlayerBridge, AVRoutePickerViewDelegate {

    private var playerVC: MPVPlayerViewController?
    private var experimentalSinglePrimaryPictureInPictureEnabled = false
    private var keyboardShortcutsEnabled = true
    private var keyboardShortcutHandler: ((String) -> Void)?
    private var airPlayPlayerViewController: AirPlayPlayerViewController?
    private var airPlayPlayer: AVPlayer?
    private var airPlayStatusObservation: NSKeyValueObservation?
    private var airPlayRelay: AirPlayHLSRelay?
    private var airPlaySourceURL: String?
    private var airPlaySourceHeaders: [String: String] = [:]
    private var airPlayStartPositionMs: Int64 = 0
    private var airPlayKnownDurationMs: Int64 = 0
    private var airPlayTitle: String?
    private var airPlayLocalPlaybackWasPlaying = false
    private var didAttemptAirPlayRelay = false
    private var airPlayRoutePickerView: AVRoutePickerView?
    private var airPlayRouteChangeObserver: NSObjectProtocol?
    private var airPlayRouteSelectionWorkItem: DispatchWorkItem?
    private var airPlayRoutePickerDidEnd = false

    func createPlayerViewController() -> UIViewController {
        return ensurePlayerViewController()
    }

    private func ensurePlayerViewController() -> MPVPlayerViewController {
        if let playerVC { return playerVC }
        let vc = MPVPlayerViewController()
        vc.setKeyboardShortcutsEnabled(keyboardShortcutsEnabled)
        vc.setKeyboardShortcutHandler(keyboardShortcutHandler)
        self.playerVC = vc
        return vc
    }

    func loadFile(url: String) { ensurePlayerViewController().loadFile(url) }
    func loadFileWithAudio(videoUrl: String, audioUrl: String?, headersJson: String?, subtitlesJson: String?) {
        ensurePlayerViewController().loadFile(
            videoUrl,
            audioUrl: audioUrl,
            requestHeaders: parseRequestHeaders(headersJson),
            subtitles: parseSubtitles(subtitlesJson)
        )
    }

    private func parseSubtitles(_ json: String?) -> [PluginSubtitle] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return raw.compactMap { dict in
            guard let url = dict["url"] as? String else { return nil }
            return PluginSubtitle(
                url: url,
                language: dict["language"] as? String ?? "Unknown",
                name: dict["name"] as? String,
                headers: dict["headers"] as? [String: String]
            )
        }
    }

    func play() { playerVC?.playPlayback() }
    func pause() { playerVC?.pausePlayback() }
    func seekTo(positionMs: Int64) { playerVC?.seekToMs(positionMs) }
    func seekBy(offsetMs: Int64) { playerVC?.seekByMs(offsetMs) }
    func setSystemControlHandler(handler: PlayerSystemControlHandler?) {
        if let handler {
            ensurePlayerViewController().systemControlHandler = handler
        } else {
            playerVC?.systemControlHandler = nil
        }
    }
    func getKeepsPlaybackInBackground() -> Bool {
        playerVC?.keepsPlaybackInBackground ?? false
    }
    func retry() { playerVC?.retryPlayback() }
    func isPictureInPictureSupported() -> Bool { playerVC?.isPictureInPictureSupported() ?? false }
    func startPictureInPicture() { playerVC?.startPictureInPicture() }
    func isAirPlaySupported() -> Bool { true }

    func presentAirPlayPlayer(
        videoUrl: String,
        headersJson: String?,
        title: String?,
        startPositionMs: Int64
    ) -> Bool {
        guard let url = URL(string: videoUrl), url.scheme != nil else { return false }
        guard airPlayPlayerViewController == nil, airPlayRoutePickerView == nil else { return true }
        guard let presenter = playerVC ?? topViewController() else { return false }

        let headers = parseRequestHeaders(headersJson)
        airPlaySourceURL = videoUrl
        airPlaySourceHeaders = headers
        airPlayStartPositionMs = startPositionMs
        airPlayTitle = title
        didAttemptAirPlayRelay = false

        if isAirPlayRouteSelected {
            beginAirPlayPlayback(url: url, headers: headers, presenter: presenter)
            return true
        }

        let picker = AVRoutePickerView(frame: .zero)
        picker.delegate = self
        picker.prioritizesVideoDevices = true
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.alpha = 0.01
        presenter.view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.centerXAnchor.constraint(equalTo: presenter.view.centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: presenter.view.centerYAnchor),
            picker.widthAnchor.constraint(equalToConstant: 44),
            picker.heightAnchor.constraint(equalToConstant: 44),
        ])
        airPlayRoutePickerView = picker
        airPlayRoutePickerDidEnd = false
        airPlayRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self, self.airPlayRoutePickerDidEnd else { return }
            self.completeAirPlayRouteSelectionIfPossible()
        }

        DispatchQueue.main.async { [weak self, weak picker] in
            guard let self, let picker, self.airPlayRoutePickerView === picker else { return }
            guard let button = self.firstButton(in: picker) else {
                self.clearAirPlayRouteSelection(resetSource: true)
                self.presentAirPlayError("The AirPlay device picker could not be opened.")
                return
            }
            button.sendActions(for: .touchUpInside)
        }
        return true
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        airPlayRoutePickerDidEnd = false
        airPlayRouteSelectionWorkItem?.cancel()
        airPlayRouteSelectionWorkItem = nil
        InAppLogBridge.shared.info(tag: "Player/AirPlay", message: "AirPlay route selection opened")
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        guard airPlayRoutePickerView === routePickerView else { return }
        airPlayRoutePickerDidEnd = true
        if completeAirPlayRouteSelectionIfPossible() { return }

        let workItem = DispatchWorkItem { [weak self, weak routePickerView] in
            guard let self, let routePickerView, self.airPlayRoutePickerView === routePickerView else { return }
            if !self.completeAirPlayRouteSelectionIfPossible() {
                InAppLogBridge.shared.info(tag: "Player/AirPlay", message: "AirPlay route selection cancelled")
                self.clearAirPlayRouteSelection(resetSource: true)
            }
        }
        airPlayRouteSelectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    @discardableResult
    private func completeAirPlayRouteSelectionIfPossible() -> Bool {
        guard airPlayRoutePickerDidEnd, isAirPlayRouteSelected else { return false }
        guard
            let source = airPlaySourceURL,
            let url = URL(string: source),
            let presenter = playerVC ?? topViewController()
        else {
            clearAirPlayRouteSelection(resetSource: true)
            return false
        }

        let headers = airPlaySourceHeaders
        clearAirPlayRouteSelection(resetSource: false)
        beginAirPlayPlayback(url: url, headers: headers, presenter: presenter)
        return true
    }

    private var isAirPlayRouteSelected: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    private func beginAirPlayPlayback(
        url: URL,
        headers: [String: String],
        presenter: UIViewController
    ) {
        guard airPlayPlayerViewController == nil else { return }

        playerVC?.refreshPlaybackState()
        if let positionMs = playerVC?.positionMs {
            airPlayStartPositionMs = max(0, positionMs)
        }
        let knownDurationMs = max(0, playerVC?.durationMs ?? 0)
        airPlayKnownDurationMs = knownDurationMs
        airPlayLocalPlaybackWasPlaying = playerVC?.isPlayerPlaying == true
        playerVC?.pausePlayback()

        let controller = AirPlayPlayerViewController()
        controller.modalPresentationStyle = .fullScreen
        if let title = airPlayTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller.title = title
        }
        controller.configure(
            displayTitle: airPlayTitle,
            knownDurationMs: knownDurationMs,
            initialPositionMs: airPlayStartPositionMs
        )
        controller.onDismiss = { [weak self] in
            self?.resetAirPlayPlayback()
        }
        controller.onExternalPlaybackEnded = { [weak self, weak controller] positionMs, wasPlaying in
            guard let self, let controller, self.airPlayPlayerViewController === controller else { return }
            self.playerVC?.seekToMs(positionMs)
            controller.dismiss(animated: true) {
                if wasPlaying { self.playerVC?.playPlayback() }
            }
        }

        airPlayPlayerViewController = controller
        presenter.present(controller, animated: true) {
            self.startNativeAirPlayPlayer(url: url, headers: headers, controller: controller)
        }
    }

    private func clearAirPlayRouteSelection(resetSource: Bool) {
        airPlayRouteSelectionWorkItem?.cancel()
        airPlayRouteSelectionWorkItem = nil
        if let observer = airPlayRouteChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            airPlayRouteChangeObserver = nil
        }
        airPlayRoutePickerView?.delegate = nil
        airPlayRoutePickerView?.removeFromSuperview()
        airPlayRoutePickerView = nil
        airPlayRoutePickerDidEnd = false
        if resetSource {
            airPlaySourceURL = nil
            airPlaySourceHeaders = [:]
            airPlayStartPositionMs = 0
            airPlayKnownDurationMs = 0
            airPlayTitle = nil
            airPlayLocalPlaybackWasPlaying = false
            didAttemptAirPlayRelay = false
        }
    }

    private func resetAirPlayPlayback() {
        clearAirPlayRouteSelection(resetSource: true)
        airPlayPlayer?.pause()
        airPlayRelay?.stop()
        airPlayRelay = nil
        airPlayPlayer = nil
        airPlayPlayerViewController = nil
        airPlayStatusObservation = nil
    }

    private func firstButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let button = firstButton(in: subview) { return button }
        }
        return nil
    }

    private func startNativeAirPlayPlayer(
        url: URL,
        headers: [String: String],
        controller: AirPlayPlayerViewController
    ) {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        installAirPlayPlayer(item: AVPlayerItem(asset: asset), controller: controller, allowRelayFallback: true)
    }

    private func installAirPlayPlayer(
        item: AVPlayerItem,
        controller: AirPlayPlayerViewController,
        allowRelayFallback: Bool
    ) {
        airPlayStatusObservation = nil
        airPlayPlayer?.pause()
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        if allowRelayFallback, airPlayKnownDurationMs > 0 {
            item.forwardPlaybackEndTime = CMTime(value: airPlayKnownDurationMs, timescale: 1000)
        }
        applyAirPlayMetadata(to: item)
        controller.player = player
        controller.attach(player: player, item: item)
        airPlayPlayer = player
        airPlayStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak controller] item, _ in
            guard item.status == .failed else { return }
            let message = self?.airPlayErrorMessage(item)
            DispatchQueue.main.async {
                guard let self, let controller else { return }
                if allowRelayFallback, !self.didAttemptAirPlayRelay {
                    self.startAirPlayRelay(controller: controller, nativeError: message)
                } else {
                    self.failAirPlayPlayback(controller: controller, message: message)
                }
            }
        }
        if airPlayStartPositionMs > 0 {
            player.seek(to: CMTime(value: airPlayStartPositionMs, timescale: 1000))
        }
        player.play()
    }

    private func startAirPlayRelay(controller: AirPlayPlayerViewController, nativeError: String?) {
        guard !didAttemptAirPlayRelay, let sourceURL = airPlaySourceURL else { return }
        didAttemptAirPlayRelay = true
        airPlayStatusObservation = nil
        airPlayPlayer?.pause()
        airPlayPlayer = nil
        controller.detachPlayer()
        controller.setPreparingRelay(true)
        do {
            let relay = try AirPlayHLSRelay(
                sourceURL: sourceURL,
                headers: airPlaySourceHeaders,
                startPositionMs: airPlayStartPositionMs
            )
            airPlayRelay = relay
            relay.onFailure = { [weak self, weak controller, weak relay] error in
                guard let self, let controller, self.airPlayRelay === relay else { return }
                self.failAirPlayPlayback(
                    controller: controller,
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            InAppLogBridge.shared.info(
                tag: "Player/AirPlay",
                message: "Native playback failed; starting local HLS remux. \(nativeError ?? "")"
            )
            relay.start { [weak self, weak controller, weak relay] result in
                guard let self, let controller, self.airPlayRelay === relay else { return }
                controller.setPreparingRelay(false)
                switch result {
                case .success(let playlistURL):
                    InAppLogBridge.shared.info(
                        tag: "Player/AirPlay",
                        message: "Local HLS relay ready at \(playlistURL.host ?? "phone")"
                    )
                    let relayStartPositionMs = self.airPlayStartPositionMs
                    self.airPlayStartPositionMs = 0
                    controller.setRelayTimelineOffset(positionMs: relayStartPositionMs)
                    let item = AVPlayerItem(url: playlistURL)
                    self.installAirPlayPlayer(item: item, controller: controller, allowRelayFallback: false)
                case .failure(let error):
                    let relayMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.failAirPlayPlayback(
                        controller: controller,
                        message: [nativeError, relayMessage].compactMap { $0 }.joined(separator: "\n\n")
                    )
                }
            }
        } catch {
            controller.setPreparingRelay(false)
            let relayMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failAirPlayPlayback(
                controller: controller,
                message: [nativeError, relayMessage].compactMap { $0 }.joined(separator: "\n\n")
            )
        }
    }

    private func failAirPlayPlayback(controller: AirPlayPlayerViewController, message: String?) {
        let shouldResumeLocalPlayback = airPlayLocalPlaybackWasPlaying
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            if shouldResumeLocalPlayback { self.playerVC?.playPlayback() }
            self.presentAirPlayError(message)
        }
    }

    private func airPlayErrorMessage(_ item: AVPlayerItem) -> String? {
        var details: [String] = []
        if let error = item.error {
            let nsError = error as NSError
            details.append(nsError.localizedDescription)
            details.append("\(nsError.domain) (\(nsError.code))")
            if let reason = nsError.localizedFailureReason, !reason.isEmpty {
                details.append(reason)
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                details.append("Underlying: \(underlying.domain) (\(underlying.code)) \(underlying.localizedDescription)")
            }
        }
        if let event = item.errorLog()?.events.last {
            if event.errorStatusCode != 0 {
                details.append("HTTP/status \(event.errorStatusCode)")
            }
            if let comment = event.errorComment, !comment.isEmpty {
                details.append(comment)
            }
        }
        let unique = details.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    private func applyAirPlayMetadata(to item: AVPlayerItem) {
        guard let title = airPlayTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return
        }
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"
        item.externalMetadata = [titleItem]
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    private func presentAirPlayError(_ message: String?) {
        let alert = UIAlertController(
            title: "AirPlay playback failed",
            message: message ?? "This stream is not compatible with the native player. Try an HLS or MP4 source.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (playerVC ?? topViewController())?.present(alert, animated: true)
    }
    func setVideoZoom(scale: Double) { playerVC?.setVideoZoom(scale) }
    func setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: Bool) {
        experimentalSinglePrimaryPictureInPictureEnabled = enabled
    }
    func updateNowPlayingMetadata(
        title: String,
        subtitle: String?,
        artworkUrl: String?
    ) {
        ensurePlayerViewController().updateNowPlayingMetadata(
            title: title,
            subtitle: subtitle,
            artworkUrl: artworkUrl
        )
    }
    func clearNowPlayingInfo() { playerVC?.clearNowPlayingInfo() }
    func setKeyboardShortcutsEnabled(enabled: Bool) {
        keyboardShortcutsEnabled = enabled
        playerVC?.setKeyboardShortcutsEnabled(enabled)
    }
    func setKeyboardShortcutHandler(handler: ((String) -> Void)?) {
        keyboardShortcutHandler = handler
        playerVC?.setKeyboardShortcutHandler(handler)
    }
    func configureVideoOutput(
        hardwareDecoder: String,
        targetColorspaceHint: Bool,
        toneMapping: String,
        hdrComputePeak: Bool,
        targetPrimaries: String,
        targetTransfer: String,
        extendedDynamicRange: Bool,
        deband: Bool,
        interpolation: Bool,
        brightness: Int32,
        contrast: Int32,
        saturation: Int32,
        gamma: Int32
    ) {
        playerVC?.configureVideoOutput(
            hardwareDecoder: hardwareDecoder,
            targetColorspaceHint: targetColorspaceHint,
            toneMapping: toneMapping,
            hdrComputePeak: hdrComputePeak,
            targetPrimaries: targetPrimaries,
            targetTransfer: targetTransfer,
            extendedDynamicRange: extendedDynamicRange,
            deband: deband,
            interpolation: interpolation,
            brightness: Int(brightness),
            contrast: Int(contrast),
            saturation: Int(saturation),
            gamma: Int(gamma)
        )
    }
    func configureAudioOutput(audioOutput: String) {
        playerVC?.configureAudioOutput(audioOutput: audioOutput)
    }

    func applyAudioLanguagePreferences(languages: [String]) {
        ensurePlayerViewController().applyAudioLanguagePreferences(languages)
    }
    func setPlaybackSpeed(speed: Float) { playerVC?.setSpeed(speed) }
    func getVolume() -> Float { playerVC?.getVolume() ?? 1.0 }
    func setVolume(volume: Float) { playerVC?.setVolume(volume) }
    func setMuted(muted: Bool) { playerVC?.setMuted(muted) }
    func setEmbeddedPreviewMode(enabled: Bool) { ensurePlayerViewController().setEmbeddedPreviewMode(enabled) }
    func setResizeMode(mode: Int32) { playerVC?.setResize(Int(mode)) }
    func syncVideoSurfaceLayout(width: Double, height: Double) {
        playerVC?.syncVideoSurfaceLayout(size: CGSize(width: width, height: height))
    }

    // Audio tracks
    func getAudioTrackCount() -> Int32 { Int32(playerVC?.audioTracks.count ?? 0) }
    func getAudioTrackIndex(at: Int32) -> Int32 {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return 0 }
        return Int32(t[Int(at)].index)
    }
    func getAudioTrackId(at: Int32) -> String {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return "0" }
        return "\(t[Int(at)].id)"
    }
    func getAudioTrackLabel(at: Int32) -> String {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return "" }
        return t[Int(at)].title
    }
    func getAudioTrackLang(at: Int32) -> String {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return "" }
        return t[Int(at)].lang
    }
    func isAudioTrackSelected(at: Int32) -> Bool {
        guard let t = playerVC?.audioTracks, Int(at) < t.count else { return false }
        return t[Int(at)].selected
    }

    // Subtitle tracks
    func getSubtitleTrackCount() -> Int32 { Int32(playerVC?.subtitleTracks.count ?? 0) }
    func getSubtitleTrackIndex(at: Int32) -> Int32 {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return 0 }
        return Int32(t[Int(at)].index)
    }
    func getSubtitleTrackId(at: Int32) -> String {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return "0" }
        return "\(t[Int(at)].id)"
    }
    func getSubtitleTrackLabel(at: Int32) -> String {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return "" }
        return t[Int(at)].title
    }
    func getSubtitleTrackLang(at: Int32) -> String {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return "" }
        return t[Int(at)].lang
    }
    func isSubtitleTrackSelected(at: Int32) -> Bool {
        guard let t = playerVC?.subtitleTracks, Int(at) < t.count else { return false }
        return t[Int(at)].selected
    }

    func selectAudioTrack(trackId: Int32) { playerVC?.selectAudio(Int(trackId)) }
    func selectSubtitleTrack(trackId: Int32) { playerVC?.selectSubtitle(Int(trackId)) }
    func setSubtitleUrl(url: String) { playerVC?.addSubtitleUrl(url) }
    func clearExternalSubtitle() { playerVC?.removeExternalSubtitles() }
    func clearExternalSubtitleAndSelect(trackId: Int32) { playerVC?.removeExternalSubtitlesAndSelect(Int(trackId)) }
    func setSubtitleDelayMs(delayMs: Int32) { playerVC?.setSubtitleDelayMs(Int(delayMs)) }
    func setSubtitleFontPath(path: String) { playerVC?.setSubtitleFontPath(path) }
    func applySubtitleStyle(
        textColor: String,
        backgroundColor: String,
        outlineColor: String,
        outlineSize: Float,
        shadowOffset: Float,
        bold: Bool,
        fontSize: Float,
        subPos: Int32,
        stripSdh: Bool
    ) {
        playerVC?.applySubtitleStyle(
            textColor: textColor,
            backgroundColor: backgroundColor,
            outlineColor: outlineColor,
            outlineSize: outlineSize,
            shadowOffset: shadowOffset,
            bold: bold,
            fontSize: fontSize,
            subPos: Int(subPos),
            stripSdh: stripSdh
        )
    }

    // State - refreshes position from mpv on each call (polled from Kotlin every 250ms)
    func getIsLoading() -> Bool { playerVC?.refreshPlaybackState(); return playerVC?.isPlayerLoading ?? true }
    func getIsPlaying() -> Bool { return playerVC?.isPlayerPlaying ?? false }
    func getIsEnded() -> Bool { return playerVC?.isPlayerEnded ?? false }
    func getDurationMs() -> Int64 { return playerVC?.durationMs ?? 0 }
    func getPositionMs() -> Int64 { return playerVC?.positionMs ?? 0 }
    func getBufferedMs() -> Int64 { return playerVC?.bufferedMs ?? 0 }
    func getPlaybackSpeed() -> Float { playerVC?.currentSpeed ?? 1.0 }
    func getVideoWidth() -> Int32 { Int32(playerVC?.currentVideoWidth ?? 0) }
    func getVideoHeight() -> Int32 { Int32(playerVC?.currentVideoHeight ?? 0) }
    func getErrorMessage() -> String { playerVC?.currentErrorMessage ?? "" }
    func getMediaInfoJson() -> String { playerVC?.getMediaInfoJson() ?? "{}" }
    func getProperty(name: String) -> String { playerVC?.getString(name) ?? "" }

    func destroy() {
        airPlayPlayerViewController?.dismiss(animated: false)
        resetAirPlayPlayback()
        playerVC?.systemControlHandler = nil
        playerVC?.destroyPlayer()
        playerVC = nil
    }

    private func parseRequestHeaders(_ headersJson: String?) -> [String: String] {
        guard
            let headersJson,
            !headersJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let data = headersJson.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        var headers: [String: String] = [:]
        headers.reserveCapacity(raw.count)
        raw.forEach { key, value in
            guard let headerValue = value as? String else { return }
            headers[key] = headerValue
        }
        return headers
    }
}

struct PluginSubtitle {
    let url: String
    let language: String
    let name: String?
    let headers: [String: String]?
}

// MARK: - Track Info

struct TrackInfo {
    let index: Int
    let id: Int
    let type: String
    let title: String
    let lang: String
    let selected: Bool
}

private struct PendingLoadRequest {
    let urlString: String
    let audioUrl: String?
    let requestHeaders: [String: String]
    let subtitles: [PluginSubtitle]
    let queuedAtUptime: TimeInterval
}

// MARK: - MPV Player View Controller

final class MPVPlayerViewController: UIViewController {

    static let defaultAudioOutput = "audiounit"

    private struct CachedNowPlayingMetadata {
        let title: String
        let subtitle: String?
        let artworkUrl: String?
    }

    private let errorStateLock = NSLock()
    let metalLayer = MetalLayer()
    private var pictureInPictureController: PlayerPictureInPictureController?
    var systemControlHandler: PlayerSystemControlHandler?
    var keepsPlaybackInBackground: Bool { pictureInPictureController?.keepsPlaybackAlive == true }
    private var lastAppliedDrawableSize: CGSize = .zero
    private var externallyManagedViewSize: CGSize?
    private var pendingSurfaceLayoutWorkItems: [DispatchWorkItem] = []
    private var pendingLoadRequest: PendingLoadRequest?
    private var pendingLoadRetryWorkItem: DispatchWorkItem?
    var mpv: OpaquePointer?
    private var cachedNowPlayingMetadata: CachedNowPlayingMetadata?
    private lazy var nowPlayingController = PlayerNowPlayingController(owner: self)
    private lazy var audioSessionController: PlayerAudioSessionController = {
        let controller = PlayerAudioSessionController()
        controller.onConfigurationChanged = { [weak self] in
            guard let self, self.mpv != nil else { return }
            self.publishCachedNowPlayingInfoIfNeeded()
            self.syncNowPlayingPlaybackState(isPlaying: self.isPlayerPlaying)
        }
        return controller
    }()
    private let eventQueue = DispatchQueue(label: "mpv-events", qos: .userInitiated)
    private let mpvQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "mpv-properties", qos: .userInitiated)
        queue.setSpecific(key: MPVPlayerViewController.mpvQueueKey, value: ())
        return queue
    }()
    private static let mpvQueueKey = DispatchSpecificKey<Void>()

    private func onMpvQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.mpvQueueKey) != nil {
            work()
        } else {
            mpvQueue.async(execute: work)
        }
    }

    private let mpvLifecycleLock = NSLock()
    private var storedMpvGeneration: UInt64 = 0
    private var mpvGeneration: UInt64 {
        mpvLifecycleLock.lock()
        defer { mpvLifecycleLock.unlock() }
        return storedMpvGeneration
    }
    private func bumpMpvGeneration() {
        mpvLifecycleLock.lock()
        storedMpvGeneration &+= 1
        mpvLifecycleLock.unlock()
    }

    private func withMpvOnQueue(_ work: @escaping (OpaquePointer) -> Void) {
        guard mpv != nil else { return }
        let generation = mpvGeneration
        onMpvQueue { [weak self] in
            guard let self, self.mpvGeneration == generation, let ctx = self.mpv else { return }
            work(ctx)
        }
    }
    private let stateRefreshLock = NSLock()
    private var isPlaybackStateRefreshInFlight = false
    private var isTrackRefreshInFlight = false
    private var playbackStateGeneration: UInt64 = 0

    private let positionSampleLock = NSLock()
    private var positionSampleMs: Int64 = 0
    private var positionSampleTime: CFTimeInterval = 0
    private var positionSampleRate: Double = 0

    private static let mediaInfoRefreshInterval: CFTimeInterval = 1.0
    private let mediaInfoLock = NSLock()
    private var cachedMediaInfoJson = "{}"
    private var cachedVideoWidth = 0
    private var cachedVideoHeight = 0
    private var cachedFrameRate: Double = 30.0
    private var isMediaInfoRefreshInFlight = false
    private var lastMediaInfoRefreshTime: CFTimeInterval = 0
    private var mediaInfoGeneration: UInt64 = 0
    private var recentPlaybackLogs: [String] = []
    private var activeRequestHeaders: [String: String] = [:]
    private var keyboardShortcutsEnabled: Bool = true
    private var keyboardShortcutHandler: ((String) -> Void)?

    struct VideoOutputSettings {
        let hardwareDecoder: String
        let targetColorspaceHint: Bool
        let toneMapping: String
        let hdrComputePeak: Bool
        let targetPrimaries: String
        let targetTransfer: String
        let extendedDynamicRange: Bool
        let deband: Bool
        let interpolation: Bool
        let brightness: Int
        let contrast: Int
        let saturation: Int
        let gamma: Int
    }

    struct SubtitleStyleSettings {
        let textColor: String
        let backgroundColor: String
        let outlineColor: String
        let outlineSize: Float
        let shadowOffset: Float
        let bold: Bool
        let fontSize: Float
        let subPos: Int
        let stripSdh: Bool
    }

    private var lastLoadRequest: PendingLoadRequest?
    private var lastVideoOutputSettings: VideoOutputSettings?
    private var lastSubtitleStyle: SubtitleStyleSettings?
    private var lastAudioOutput: String?
    private var lastResizeMode: Int?
    private var lastVideoZoom: Double?
    private var lastSubtitleDelayMs: Int?
    private var lastVolume: Float?
    private var lastMuted: Bool?
    private var lastSelectedAudioTrackId: Int?
    private var lastSelectedSubtitleTrackId: Int?
    private var isRecoveringFromDeviceLoss = false
    private var isDeviceLossRecoveryPending = false
    private var hasGivenUpOnDeviceLossRecovery = false
    private var isPlayerDestroyed = false
    private var deviceLossRecoveryAttempts = 0
    private var lastDeviceLossRecoveryTime: CFTimeInterval = 0
    private var deviceLossDetectedAt: CFTimeInterval = 0
    private var deviceLossResumeSeconds: Double = 0
    private var deviceLossResumePlayback = false
    private var deviceLossRecoveryProbeWorkItem: DispatchWorkItem?
    private var isDeviceLossResumePending = false
    private var deviceLossResumeGeneration: UInt64 = 0
    private var deviceLossDetectedPositionSeconds: Double = 0
    private var deviceLossResumeTimeoutWorkItem: DispatchWorkItem?
    private var gpuProbeCommandQueue: MTLCommandQueue?
    private var gpuProbeBuffer: MTLBuffer?
    private var sawDeviceLossInLog = false

    private struct ThrottledLogEntry {
        let prefix: String
        let level: String
        let text: String
        var count: Int
        var lastEmitTime: CFTimeInterval
    }

    private static let logCoalesceInterval: CFTimeInterval = 2.0
    private let logCoalesceLock = NSLock()
    private var throttledLogEntries: [String: ThrottledLogEntry] = [:]

    var audioTracks: [TrackInfo] = []
    var subtitleTracks: [TrackInfo] = []
    var isPlayerLoading: Bool = true
    var isPlayerPlaying: Bool = false
    var isPlayerEnded: Bool = false
    var durationMs: Int64 = 0
    var positionMs: Int64 = 0
    var bufferedMs: Int64 = 0
    var currentSpeed: Float = 1.0
    var currentErrorMessage: String {
        errorStateLock.lock()
        defer { errorStateLock.unlock() }
        return _currentErrorMessage ?? ""
    }
    private var _currentErrorMessage: String?
    private var isEmbeddedPreviewMode = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var canBecomeFirstResponder: Bool {
        !isEmbeddedPreviewMode
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        !isEmbeddedPreviewMode
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        isEmbeddedPreviewMode ? [] : [.bottom, .left, .right]
    }

    override var prefersStatusBarHidden: Bool {
        !isEmbeddedPreviewMode
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        .fade
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true

        metalLayer.contentsGravity = .resize
        metalLayer.contentsScale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.anchorPoint = CGPoint(x: 0, y: 0)
        metalLayer.position = .zero
        metalLayer.onRenderingSuspensionChanged = { suspended, reason in
            if suspended {
                InAppLogBridge.shared.warn(
                    tag: "MPV/iOS",
                    message: "Drawable acquisition suspended (\(reason)); iOS is likely denying " +
                        "background GPU work. Rendering will resume when the app is visible again."
                )
            } else {
                InAppLogBridge.shared.info(
                    tag: "MPV/iOS",
                    message: "Drawable acquisition resumed (\(reason))"
                )
            }
        }
        let pip = PlayerPictureInPictureController(owner: self, metalLayer: metalLayer)
        pictureInPictureController = pip
        view.layer.addSublayer(pip.displayLayer)
        view.layer.addSublayer(metalLayer)
        layoutPlayerSurfaces()

        setupMpv()
        if !isEmbeddedPreviewMode {
            activateAudioSessionForPlayback()
        }
        setupNotifications()
        refreshImmersiveSystemUI()
    }

    func setPictureInPicturePlaceholderVisible(_ visible: Bool) {
        SystemUI.shared.setPictureInPicturePlaceholder(self, visible: visible)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshImmersiveSystemUI()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayerSurfaces()
        attemptStartPendingLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isEmbeddedPreviewMode {
            publishImmersiveSystemUIVisibility(isVisible: true)
            refreshImmersiveSystemUI()
            becomeFirstResponder()
            UIApplication.shared.beginReceivingRemoteControlEvents()
            publishCachedNowPlayingInfoIfNeeded()
        }
        syncVideoSurfaceLayout()
        attemptStartPendingLoad()
    }

    override func viewWillDisappear(_ animated: Bool) {
        if !isEmbeddedPreviewMode {
            publishImmersiveSystemUIVisibility(isVisible: false)
        }
        super.viewWillDisappear(animated)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            publishImmersiveSystemUIVisibility(isVisible: false)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        syncVideoSurfaceLayout()
        refreshImmersiveSystemUI()
        attemptStartPendingLoad()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        syncVideoSurfaceLayoutNow(scheduleDeferredPasses: false)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.syncVideoSurfaceLayoutNow(scheduleDeferredPasses: false)
        }, completion: { [weak self] _ in
            self?.syncVideoSurfaceLayout()
            self?.attemptStartPendingLoad()
        })
    }

    func syncVideoSurfaceLayout(size: CGSize) {
        if Thread.isMainThread {
            syncVideoSurfaceLayoutNow(size: size, scheduleDeferredPasses: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.syncVideoSurfaceLayoutNow(size: size, scheduleDeferredPasses: true)
            }
        }
    }

    private func syncVideoSurfaceLayout() {
        if Thread.isMainThread {
            syncVideoSurfaceLayoutNow(size: nil, scheduleDeferredPasses: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.syncVideoSurfaceLayoutNow(size: nil, scheduleDeferredPasses: true)
            }
        }
    }

    private func syncVideoSurfaceLayoutNow(size: CGSize? = nil, scheduleDeferredPasses: Bool) {
        guard isViewLoaded else { return }
        if let size, size.width > 1, size.height > 1 {
            externallyManagedViewSize = size
            applyExternallyManagedViewSize(size)
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        layoutPlayerSurfaces()

        if scheduleDeferredPasses {
            scheduleDeferredSurfaceLayoutPasses()
        }
    }

    private func scheduleDeferredSurfaceLayoutPasses() {
        pendingSurfaceLayoutWorkItems.forEach { $0.cancel() }
        pendingSurfaceLayoutWorkItems.removeAll(keepingCapacity: true)

        [0.0, 0.05, 0.15, 0.35].forEach { delay in
            let workItem = DispatchWorkItem { [weak self] in
                self?.syncVideoSurfaceLayoutNow(scheduleDeferredPasses: false)
            }
            pendingSurfaceLayoutWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func applyExternallyManagedViewSize(_ size: CGSize) {
        let targetBounds = CGRect(origin: .zero, size: size)
        if view.bounds != targetBounds {
            view.bounds = targetBounds
        }

        var targetFrame = view.frame
        if targetFrame.size != size {
            targetFrame.size = size
            view.frame = targetFrame
        }
    }

    private func layoutPlayerSurfaces() {
        let bounds = CGRect(origin: .zero, size: externallyManagedViewSize ?? view.bounds.size)
        guard bounds.width > 1, bounds.height > 1 else { return }

        let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let drawableSize = CGSize(
            width: (bounds.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (bounds.height * scale).rounded(.toNearestOrAwayFromZero)
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.position = .zero
        metalLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        pictureInPictureController?.displayLayer.frame = bounds
        if drawableSize != lastAppliedDrawableSize {
            metalLayer.drawableSize = drawableSize
            lastAppliedDrawableSize = drawableSize
        }
        CATransaction.commit()
    }

    private lazy var subtitleFonts = MPVSubtitleFontController(player: self)

    // MARK: - MPV Setup

    private func setupMpv() {
        mpv = mpv_create()
        guard mpv != nil else {
            print("[MPV] Failed to create mpv instance")
            InAppLogBridge.shared.error(tag: "MPV/iOS", message: "Failed to create mpv instance")
            return
        }

        InAppLogBridge.shared.info(tag: "MPV/iOS", message: "Initializing mpv vo=gpu-next gpu-api=vulkan gpu-context=moltenvk hwdec=videotoolbox")
        checkError(mpv_request_log_messages(mpv, "warn"))

        var layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerPointer))
        setSetupOption("vo", "gpu-next")
        setSetupOption("gpu-api", "vulkan")
        setSetupOption("gpu-context", "moltenvk")
        setSetupOption("hwdec", "videotoolbox")
        setSetupOption("hwdec-software-fallback", "300")
        setSetupOption("ao", Self.defaultAudioOutput)
        setSetupOption("audio-exclusive", "yes")
        setSetupOption("audio-channels", "auto")
        setSetupOption("audio-fallback-to-null", "yes")
        setSetupOption("volume-max", "200")
        setSetupOption("volume", "100")
        setSetupOption("volume-gain-max", "12")
        setSetupOption("volume-gain", "0")
        setSetupOption("vulkan-swap-mode", "fifo")
        setSetupOption("vulkan-queue-count", "1")
        setSetupOption("vulkan-async-compute", "no")
        setSetupOption("vulkan-async-transfer", "no")
        setSetupOption("vulkan-disable-interop", "yes")
        setSetupOption("video-rotate", "no")
        setSetupOption("subs-match-os-language", "yes")
        setSetupOption("subs-fallback", "yes")
        subtitleFonts.applySetupOptions(setSetupOption)
        setSetupOption("keep-open", "yes")
        setSetupOption("target-colorspace-hint", "yes")
        setSetupOption("tone-mapping", "auto")
        setSetupOption("hdr-compute-peak", "yes")
        setSetupOption("demuxer-max-bytes", "\(Self.demuxerMaxBytes)")
        setSetupOption("demuxer-max-back-bytes", "\(Self.demuxerMaxBackBytes)")
        setSetupOption("demuxer-lavf-o", "protocol_whitelist=[file,crypto,data,http,https,tcp,tls]")

        checkError(mpv_initialize(mpv))

        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "core-idle", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "seeking", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "current-tracks/sub/id", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "current-tracks/sub/lang", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "sub-text", MPV_FORMAT_STRING)

        mpv_set_wakeup_callback(mpv, { ctx in
            let vc = unsafeBitCast(ctx, to: MPVPlayerViewController.self)
            vc.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private static let demuxerMaxBytes = 64 * 1024 * 1024

    private static let demuxerMaxBackBytes = 32 * 1024 * 1024

    private func setSetupOption(_ name: String, _ value: String) {
        guard let ctx = mpv else { return }
        let status = mpv_set_option_string(ctx, name, value)
        if status < 0 {
            let reason = String(cString: mpv_error_string(status))
            InAppLogBridge.shared.warn(
                tag: "MPV/iOS",
                message: "Ignoring mpv option \(name)=\(value): \(reason)"
            )
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    private var hwdecBeforeBackground: String?

    @objc private func enterBackground() {
        metalLayer.releasePendingDrawable()
        guard mpv != nil else { return }
        let coreGeneration = mpvGeneration
        mpvQueue.async { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration, self.mpv != nil else { return }
            self.hwdecBeforeBackground = self.getString("hwdec-current")
        }
        if pictureInPictureController?.enteredBackground() == true { return }
        pauseBackgroundPlayback()
    }

    func pauseBackgroundPlayback() {
        pausePlayback()
        setStringProperty("vid", "no")
    }

    func restoreBackgroundVideo() {
        setStringProperty("vid", "auto")
    }

    @objc private func enterForeground() {
        resumeRenderingAfterDeviceLossIfPossible(reason: "enter-foreground")
        guard mpv != nil else { return }
        let wasInPictureInPicture = pictureInPictureController?.enteredForeground() == true
        if wasInPictureInPicture { return }
        restoreBackgroundVideo()
        playPlayback()
    }

    @objc private func didBecomeActive() {
        resumeRenderingAfterDeviceLossIfPossible(reason: "did-become-active")
        restoreHardwareDecodingIfLost()
    }

    private func restoreHardwareDecodingIfLost() {
        guard mpv != nil else { return }
        let configured = lastVideoOutputSettings?.hardwareDecoder ?? "videotoolbox"
        guard configured != "no" else { return }
        let coreGeneration = mpvGeneration
        mpvQueue.async { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration, self.mpv != nil else { return }
            let before = self.hwdecBeforeBackground ?? ""
            self.hwdecBeforeBackground = nil
            let current = self.getString("hwdec-current") ?? ""
            guard !before.isEmpty, before != "no", current.isEmpty || current == "no" else { return }
            InAppLogBridge.shared.warn(
                tag: "MPV/iOS",
                message: "Hardware decoding lost in background (was \(before)); reinitialising hwdec=\(configured)"
            )
            self.setStringProperty("hwdec", "no")
            self.setStringProperty("hwdec", configured)
        }
    }

    private func resumeRenderingAfterDeviceLossIfPossible(reason: String) {
        retryDeviceLossRecoveryNow()
        if !isAwaitingDeviceLossRecovery {
            metalLayer.setRenderingSuspended(false, reason: reason)
        }
    }

    // MARK: - Picture in Picture

    func isPictureInPictureSupported() -> Bool {
        pictureInPictureController?.isSupported ?? false
    }

    func startPictureInPicture() {
        pictureInPictureController?.start()
    }

    func isPictureInPictureActive() -> Bool {
        pictureInPictureController?.isActive ?? false
    }

    func setParkedInPictureInPicture(_ parked: Bool) {
        guard !isEmbeddedPreviewMode else { return }
        publishImmersiveSystemUIVisibility(isVisible: !parked)
        if parked {
            resignFirstResponder()
        } else {
            becomeFirstResponder()
        }
    }

    func endPictureInPictureSession() {
        pictureInPictureController?.invalidate()
        pictureInPictureController = nil
    }

    // MARK: - Playback API

    func loadFile(_ urlString: String, audioUrl: String? = nil, requestHeaders: [String: String] = [:], subtitles: [PluginSubtitle] = []) {
        let request = PendingLoadRequest(
            urlString: urlString,
            audioUrl: audioUrl,
            requestHeaders: requestHeaders,
            subtitles: subtitles,
            queuedAtUptime: ProcessInfo.processInfo.systemUptime
        )

        if Thread.isMainThread {
            queueLoad(request)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.queueLoad(request)
            }
        }
    }

    private func queueLoad(_ request: PendingLoadRequest) {
        pendingLoadRequest = request
        attemptStartPendingLoad()
    }

    private func attemptStartPendingLoad() {
        guard let request = pendingLoadRequest else { return }
        guard mpv != nil else { return }
        layoutPlayerSurfaces()
        guard isViewportReadyForPlayback(queuedAtUptime: request.queuedAtUptime) else {
            schedulePendingLoadRetry()
            return
        }

        pendingLoadRequest = nil
        pendingLoadRetryWorkItem?.cancel()
        pendingLoadRetryWorkItem = nil
        lastLoadRequest = request
        cancelPendingDeviceLossResume()
        hasGivenUpOnDeviceLossRecovery = false
        deviceLossRecoveryAttempts = 0
        startLoad(request)
    }

    private func startLoad(_ request: PendingLoadRequest) {
        guard mpv != nil else { return }
        layoutPlayerSurfaces()
        clearPlaybackError()
        let sanitizedHeaders = sanitizeRequestHeaders(request.requestHeaders)
        InAppLogBridge.shared.info(
            tag: "MPV/iOS",
            message: "loadfile url=\(redactedPlaybackUrlForLogs(request.urlString)) audio=\(!(request.audioUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) subtitles=\(request.subtitles.count) headers=\(sanitizedHeaders.keys.sorted().joined(separator: ","))"
        )
        activeRequestHeaders = sanitizedHeaders
        applyRequestHeaders(sanitizedHeaders)
        isPlayerLoading = true
        isPlayerEnded = false
        playbackStateGeneration &+= 1
        invalidateMediaInfoCache()
        command("loadfile", args: [request.urlString, "replace"])
        if let audioUrl = request.audioUrl, !audioUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.command("audio-add", args: [audioUrl, "select"], checkForErrors: false)
            }
        }

        for subtitle in request.subtitles {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.addSubtitle(subtitle, mode: "auto")
            }
        }
    }

    private func isViewportReadyForPlayback(queuedAtUptime: TimeInterval) -> Bool {
        guard isViewLoaded, view.window != nil else { return false }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return false }
        if bounds.width >= bounds.height { return true }

        let age = ProcessInfo.processInfo.systemUptime - queuedAtUptime
        return age >= 0.9
    }

    private func schedulePendingLoadRetry() {
        guard pendingLoadRetryWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingLoadRetryWorkItem = nil
            self?.attemptStartPendingLoad()
        }
        pendingLoadRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    // Requests from PiP and Now Playing go to the session controller when one handles them.
    func requestSystemPlaying(_ playing: Bool) {
        if systemControlHandler?.handleSetPlaying(playing: playing) == true { return }
        if playing { playPlayback() } else { pausePlayback() }
    }

    func requestSystemSeekTo(_ positionMs: Int64) {
        if systemControlHandler?.handleSeekTo(positionMs: positionMs) == true { return }
        seekToMs(positionMs)
    }

    func requestSystemSeekBy(_ offsetMs: Int64, exact: Bool = false) {
        if systemControlHandler?.handleSeekBy(offsetMs: offsetMs) == true { return }
        seekByMs(offsetMs, exact: exact)
    }

    func playPlayback() {
        guard mpv != nil else { return }
        if !isEmbeddedPreviewMode {
            publishNowPlayingForPlaybackSession()
        }
        setFlag("pause", false)
        isPlayerPlaying = true
        playbackStateGeneration &+= 1
        if !isEmbeddedPreviewMode {
            syncNowPlayingPlaybackState(isPlaying: true)
        }
    }

    func pausePlayback() {
        guard mpv != nil else { return }
        setFlag("pause", true)
        isPlayerPlaying = false
        playbackStateGeneration &+= 1
        if !isEmbeddedPreviewMode {
            syncNowPlayingPlaybackState(isPlaying: false)
        }
    }

    func seekToMs(_ ms: Int64) {
        guard mpv != nil else { return }
        let seconds = Double(ms) / 1000.0
        if isRecoveringFromDeviceLoss { deviceLossResumeSeconds = max(0, seconds) }
        command("seek", args: [String(format: "%.3f", seconds), "absolute"])
    }

    func seekByMs(_ ms: Int64, exact: Bool = false) {
        guard mpv != nil else { return }
        let seconds = Double(ms) / 1000.0
        if isRecoveringFromDeviceLoss {
            deviceLossResumeSeconds = max(0, deviceLossResumeSeconds + seconds)
        }
        let seekMode = exact ? "relative+exact" : "relative"
        command("seek", args: [String(format: "%.3f", seconds), seekMode])
    }

    // MARK: - GPU device-loss recovery

    private static let deviceLossRecoveryCooldown: CFTimeInterval = 10.0
    private static let maxDeviceLossRecoveryAttempts = 3
    private static let deviceLossProbeInterval: CFTimeInterval = 0.75
    private static let deviceLossRecoveryDeadline: CFTimeInterval = 60.0
    private static let deviceLossResumeTimeout: CFTimeInterval = 15.0

    func handleVideoOutputDeviceLost() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.mpv != nil,
                  !self.hasGivenUpOnDeviceLossRecovery,
                  !self.isRecoveringFromDeviceLoss,
                  !self.isDeviceLossRecoveryPending
            else {
                self.clearDeviceLossLogLatch()
                return
            }

            self.isDeviceLossRecoveryPending = true
            self.deviceLossDetectedAt = CACurrentMediaTime()
            self.deviceLossDetectedPositionSeconds = max(0, Double(self.positionMs) / 1000.0)
            InAppLogBridge.shared.warn(
                tag: "MPV/iOS",
                message: "GPU device lost; waiting for GPU access to rebuild mpv core " +
                    "positionMs=\(self.positionMs)"
            )
            self.metalLayer.setRenderingSuspended(true, reason: "device-lost")
            self.scheduleDeviceLossRecoveryProbe(delay: 0)
        }
    }

    var isAwaitingDeviceLossRecovery: Bool {
        isDeviceLossRecoveryPending || isRecoveringFromDeviceLoss
    }

    private func clearDeviceLossLogLatch() {
        eventQueue.async { [weak self] in self?.sawDeviceLossInLog = false }
    }

    func retryDeviceLossRecoveryNow() {
        guard isDeviceLossRecoveryPending else { return }
        scheduleDeviceLossRecoveryProbe(delay: 0)
    }

    private func scheduleDeviceLossRecoveryProbe(delay: CFTimeInterval) {
        deviceLossRecoveryProbeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.deviceLossRecoveryProbeWorkItem = nil
            self?.attemptDeviceLossRecovery()
        }
        deviceLossRecoveryProbeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
    }

    private func attemptDeviceLossRecovery() {
        guard isDeviceLossRecoveryPending, !isRecoveringFromDeviceLoss, mpv != nil else { return }

        if CACurrentMediaTime() - deviceLossDetectedAt > Self.deviceLossRecoveryDeadline {
            giveUpOnDeviceLossRecovery(reason: "GPU never became available again")
            return
        }

        scheduleDeviceLossRecoveryProbe(delay: Self.deviceLossProbeInterval)

        probeGpuAvailability { [weak self] permitted in
            guard let self, permitted else { return }
            guard self.isDeviceLossRecoveryPending, !self.isRecoveringFromDeviceLoss else { return }
            self.deviceLossRecoveryProbeWorkItem?.cancel()
            self.deviceLossRecoveryProbeWorkItem = nil
            self.beginDeviceLossRebuild()
        }
    }

    private func beginDeviceLossRebuild() {
        let now = CACurrentMediaTime()
        if now - lastDeviceLossRecoveryTime > Self.deviceLossRecoveryCooldown {
            deviceLossRecoveryAttempts = 0
        }
        guard deviceLossRecoveryAttempts < Self.maxDeviceLossRecoveryAttempts else {
            giveUpOnDeviceLossRecovery(
                reason: "rebuilt \(deviceLossRecoveryAttempts) times without recovering"
            )
            return
        }

        deviceLossRecoveryAttempts += 1
        lastDeviceLossRecoveryTime = now
        isDeviceLossRecoveryPending = false
        isRecoveringFromDeviceLoss = true
        let polledPosition = max(0, Double(positionMs) / 1000.0)
        deviceLossResumeSeconds = polledPosition > 0 ? polledPosition : deviceLossDetectedPositionSeconds
        deviceLossResumePlayback = isPlayerPlaying

        InAppLogBridge.shared.warn(
            tag: "MPV/iOS",
            message: "GPU available again; rebuilding mpv core " +
                "attempt=\(deviceLossRecoveryAttempts) resumeAt=\(deviceLossResumeSeconds)s"
        )
        rebuildMpvCoreAfterDeviceLoss()
    }

    private func giveUpOnDeviceLossRecovery(reason: String) {
        deviceLossRecoveryProbeWorkItem?.cancel()
        deviceLossRecoveryProbeWorkItem = nil
        deviceLossResumeTimeoutWorkItem?.cancel()
        deviceLossResumeTimeoutWorkItem = nil
        isDeviceLossResumePending = false
        isDeviceLossRecoveryPending = false
        isRecoveringFromDeviceLoss = false
        hasGivenUpOnDeviceLossRecovery = true
        metalLayer.setRenderingSuspended(false, reason: "device-loss-gave-up")
        InAppLogBridge.shared.error(
            tag: "MPV/iOS",
            message: "GPU device-loss recovery abandoned — \(reason)"
        )
        setPlaybackError("Video output was lost and could not be restarted.")
    }

    private func probeGpuAvailability(completion: @escaping (Bool) -> Void) {
        guard
            let queue = makeGpuProbeQueueIfNeeded(),
            let buffer = gpuProbeBuffer,
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            completion(false)
            return
        }

        blit.fill(buffer: buffer, range: 0..<4, value: 0)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { finished in
            let permitted = finished.status == .completed && finished.error == nil
            DispatchQueue.main.async { completion(permitted) }
        }
        commandBuffer.commit()
    }

    private func makeGpuProbeQueueIfNeeded() -> MTLCommandQueue? {
        if let existing = gpuProbeCommandQueue { return existing }
        guard let device = metalLayer.device ?? MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }
        guard let buffer = device.makeBuffer(length: 4, options: .storageModePrivate) else { return nil }
        gpuProbeCommandQueue = queue
        gpuProbeBuffer = buffer
        return queue
    }

    private func releaseGpuProbeResources() {
        gpuProbeCommandQueue = nil
        gpuProbeBuffer = nil
    }

    private func rebuildMpvCoreAfterDeviceLoss() {
        teardownMpvCore { [weak self] in
            guard let self, !self.isPlayerDestroyed else { return }

            self.metalLayer.setRenderingSuspended(false, reason: "device-loss-recovery")
            self.metalLayer.releasePendingDrawable()

            self.setupMpv()
            guard self.mpv != nil else {
                self.giveUpOnDeviceLossRecovery(reason: "could not create a new mpv core")
                return
            }

            self.reapplyRememberedSettings()

            guard let request = self.lastLoadRequest else {
                self.isRecoveringFromDeviceLoss = false
                return
            }

            self.startLoad(request)
            self.scheduleDeviceLossResume()
        }
    }

    private func scheduleDeviceLossResume() {
        isDeviceLossResumePending = true
        deviceLossResumeGeneration = mpvGeneration
        deviceLossResumeTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isDeviceLossResumePending else { return }
            InAppLogBridge.shared.warn(
                tag: "MPV/iOS",
                message: "File did not load within \(Int(Self.deviceLossResumeTimeout))s after rebuild; " +
                    "resuming anyway"
            )
            self.performDeviceLossResume()
        }
        deviceLossResumeTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deviceLossResumeTimeout, execute: timeout)
    }

    private func cancelPendingDeviceLossResume() {
        isDeviceLossResumePending = false
        deviceLossResumeTimeoutWorkItem?.cancel()
        deviceLossResumeTimeoutWorkItem = nil
        deviceLossRecoveryProbeWorkItem?.cancel()
        deviceLossRecoveryProbeWorkItem = nil
        isDeviceLossRecoveryPending = false
        isRecoveringFromDeviceLoss = false
    }

    private func performDeviceLossResume() {
        guard isDeviceLossResumePending else { return }
        guard mpvGeneration == deviceLossResumeGeneration else {
            cancelPendingDeviceLossResume()
            return
        }
        isDeviceLossResumePending = false
        deviceLossResumeTimeoutWorkItem?.cancel()
        deviceLossResumeTimeoutWorkItem = nil
        defer { isRecoveringFromDeviceLoss = false }
        guard mpv != nil else { return }

        command("seek", args: [String(format: "%.3f", deviceLossResumeSeconds), "absolute"])
        if deviceLossResumePlayback {
            playPlayback()
        } else {
            pausePlayback()
        }
        clearDeviceLossLogLatch()
        InAppLogBridge.shared.info(
            tag: "MPV/iOS",
            message: "mpv core rebuilt after device loss; resumed at \(deviceLossResumeSeconds)s"
        )
    }

    private func teardownMpvCore(completion: (() -> Void)? = nil) {
        guard let ctx = mpv else {
            completion?()
            return
        }
        mpv = nil
        bumpMpvGeneration()
        mpv_set_wakeup_callback(ctx, nil, nil)
        pendingLoadRetryWorkItem?.cancel()
        pendingLoadRetryWorkItem = nil
        pendingLoadRequest = nil

        mpvQueue.async { [weak self, eventQueue, metalLayer] in
            eventQueue.sync {}
            mpv_terminate_destroy(ctx)
            withExtendedLifetime(metalLayer) {}
            eventQueue.async { self?.sawDeviceLossInLog = false }
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func reapplyRememberedSettings() {
        if let settings = lastVideoOutputSettings {
            configureVideoOutput(
                hardwareDecoder: settings.hardwareDecoder,
                targetColorspaceHint: settings.targetColorspaceHint,
                toneMapping: settings.toneMapping,
                hdrComputePeak: settings.hdrComputePeak,
                targetPrimaries: settings.targetPrimaries,
                targetTransfer: settings.targetTransfer,
                extendedDynamicRange: settings.extendedDynamicRange,
                deband: settings.deband,
                interpolation: settings.interpolation,
                brightness: settings.brightness,
                contrast: settings.contrast,
                saturation: settings.saturation,
                gamma: settings.gamma
            )
        }
        if let audioOutput = lastAudioOutput { setStringProperty("ao", audioOutput) }
        if let mode = lastResizeMode { setResize(mode) }
        if let zoom = lastVideoZoom { setVideoZoom(zoom) }
        if let delay = lastSubtitleDelayMs { setSubtitleDelayMs(delay) }
        if let style = lastSubtitleStyle {
            applySubtitleStyle(
                textColor: style.textColor,
                backgroundColor: style.backgroundColor,
                outlineColor: style.outlineColor,
                outlineSize: style.outlineSize,
                shadowOffset: style.shadowOffset,
                bold: style.bold,
                fontSize: style.fontSize,
                subPos: style.subPos,
                stripSdh: style.stripSdh
            )
        }
        setSpeed(currentSpeed)
        if let volume = lastVolume { setVolume(volume) }
        if let muted = lastMuted { setMuted(muted) }
        if let audioTrack = lastSelectedAudioTrackId { selectAudio(audioTrack) }
        if let subtitleTrack = lastSelectedSubtitleTrackId { selectSubtitle(subtitleTrack) }
    }

    func retryPlayback() {
        guard mpv != nil else { return }
        clearPlaybackError()
        applyRequestHeaders(activeRequestHeaders)
        playbackStateGeneration &+= 1
        invalidateMediaInfoCache()
        let coreGeneration = mpvGeneration
        mpvQueue.async { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration else { return }
            guard self.mpv != nil, let path = self.getString("path") else { return }
            let pos = self.getDouble("time-pos")
            self.command("loadfile", args: [path, "replace"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.command("seek", args: [String(format: "%.3f", pos), "absolute"])
            }
        }
    }

    func configureVideoOutput(
        hardwareDecoder: String,
        targetColorspaceHint: Bool,
        toneMapping: String,
        hdrComputePeak: Bool,
        targetPrimaries: String,
        targetTransfer: String,
        extendedDynamicRange: Bool,
        deband: Bool,
        interpolation: Bool,
        brightness: Int,
        contrast: Int,
        saturation: Int,
        gamma: Int
    ) {
        lastVideoOutputSettings = VideoOutputSettings(
            hardwareDecoder: hardwareDecoder,
            targetColorspaceHint: targetColorspaceHint,
            toneMapping: toneMapping,
            hdrComputePeak: hdrComputePeak,
            targetPrimaries: targetPrimaries,
            targetTransfer: targetTransfer,
            extendedDynamicRange: extendedDynamicRange,
            deband: deband,
            interpolation: interpolation,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            gamma: gamma
        )
        metalLayer.wantsExtendedDynamicRangeContent = extendedDynamicRange
        guard mpv != nil else { return }

        setStringProperty("hwdec", hardwareDecoder)
        setStringProperty("target-colorspace-hint", targetColorspaceHint ? "yes" : "no")
        setStringProperty("tone-mapping", toneMapping)
        setStringProperty("hdr-compute-peak", hdrComputePeak ? "yes" : "no")
        setStringProperty("target-prim", targetPrimaries)
        setStringProperty("target-trc", targetTransfer)
        setStringProperty("deband", deband ? "yes" : "no")
        setStringProperty("interpolation", interpolation ? "yes" : "no")
        setVideoEqualizer("brightness", brightness)
        setVideoEqualizer("contrast", contrast)
        setVideoEqualizer("saturation", saturation)
        setVideoEqualizer("gamma", gamma)
    }

    func configureAudioOutput(audioOutput: String) {
        guard mpv != nil else { return }
        let resolvedAudioOutput: String
        if audioOutput.contains("avfoundation") {
            resolvedAudioOutput = Self.defaultAudioOutput
        } else {
            resolvedAudioOutput = audioOutput
        }
        lastAudioOutput = resolvedAudioOutput
        setStringProperty("ao", resolvedAudioOutput)
    }

    func setSpeed(_ speed: Float) {
        guard mpv != nil else { return }
        setDoubleProperty("speed", Double(speed))
    }

    func getVolume() -> Float {
        guard mpv != nil else { return 1.0 }
        let baseVolume = getDouble("volume") / 100.0
        let gainDb = getDouble("volume-gain")
        let gainMultiplier = pow(10.0, gainDb / 20.0)
        return Float(max(0.0, min(2.0, baseVolume * gainMultiplier)))
    }

    func setVolume(_ volume: Float) {
        lastVolume = volume
        guard mpv != nil else { return }
        let clamped = max(0.0, min(2.0, Double(volume)))

        if clamped <= 0.001 {
            setDoubleProperty("volume", 0.0)
            setDoubleProperty("volume-gain", 0.0)
            return
        }

        setDoubleProperty("volume", 100.0)
        setDoubleProperty("volume-gain", 20.0 * log10(clamped))
    }


    func setEmbeddedPreviewMode(_ enabled: Bool) {
        guard isEmbeddedPreviewMode != enabled else { return }
        isEmbeddedPreviewMode = enabled
        if isViewLoaded {
            setNeedsStatusBarAppearanceUpdate()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }

    func setMuted(_ muted: Bool) {
        lastMuted = muted
        guard mpv != nil else { return }
        setFlag("mute", muted)
    }

    func setVideoZoom(_ scale: Double) {
        let clamped = min(max(scale, 0.25), 4.0)
        lastVideoZoom = clamped
        guard mpv != nil else { return }
        setDoubleProperty("video-zoom", log2(clamped))
    }

    func setResize(_ mode: Int) {
        lastResizeMode = mode
        guard mpv != nil else { return }
        setStringProperty("video-unscaled", "no")
        switch mode {
        case 1: // Fill: stretch to the screen without cropping (ignores the aspect ratio)
            setStringProperty("keepaspect", "no")
            setStringProperty("panscan", "0.0")
        case 2: // Zoom: enlarge with the aspect ratio kept until the black bars are gone
            setStringProperty("keepaspect", "yes")
            setStringProperty("panscan", "1.0")
        default: // Fit
            setStringProperty("keepaspect", "yes")
            setStringProperty("panscan", "0.0")
        }
    }

    // MARK: - Track selection

    func selectAudio(_ trackId: Int) {
        lastSelectedAudioTrackId = trackId
        guard mpv != nil else { return }
        setIntProperty("aid", Int64(trackId))
    }

    func applyAudioLanguagePreferences(_ languages: [String]) {
        let normalized = languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        setStringProperty("alang", normalized.joined(separator: ","))
        setStringProperty("aid", "auto")
    }

    func selectSubtitle(_ trackId: Int) {
        lastSelectedSubtitleTrackId = trackId
        guard mpv != nil else { return }
        if trackId < 0 {
            setStringProperty("sid", "no")
        } else {
            setIntProperty("sid", Int64(trackId))
        }
    }

    func addSubtitleUrl(_ url: String) {
        guard mpv != nil else { return }
        command("sub-add", args: [url, "select"])
    }

    private func addSubtitle(_ subtitle: PluginSubtitle, mode: String) {
        guard mpv != nil else { return }
        let subtitleHeaders = sanitizeRequestHeaders(subtitle.headers ?? [:])
        let previousHeaders = activeRequestHeaders

        let coreGeneration = mpvGeneration
        onMpvQueue { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration, self.mpv != nil else { return }
            if !subtitleHeaders.isEmpty {
                self.applyRequestHeaders(
                    previousHeaders.merging(subtitleHeaders) { _, subtitleValue in subtitleValue }
                )
            }

            self.command(
                "sub-add",
                args: [subtitle.url, mode, subtitle.name ?? subtitle.language, subtitle.language],
                checkForErrors: false
            )

            if !subtitleHeaders.isEmpty {
                self.applyRequestHeaders(previousHeaders)
            }
        }
    }

    func removeExternalSubtitles() {
        guard mpv != nil else { return }
        let coreGeneration = mpvGeneration
        onMpvQueue { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration, self.mpv != nil else { return }
            self.removeExternalSubtitleTracksOnMpvQueue()
            self.setStringProperty("sid", "no")
        }
    }

    func removeExternalSubtitlesAndSelect(_ trackId: Int) {
        guard mpv != nil else { return }
        let coreGeneration = mpvGeneration
        onMpvQueue { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration, self.mpv != nil else { return }
            self.removeExternalSubtitleTracksOnMpvQueue()
            if trackId >= 0 {
                self.selectSubtitle(trackId)
            } else {
                self.setStringProperty("sid", "no")
            }
        }
    }

    private func removeExternalSubtitleTracksOnMpvQueue() {
        let count = getInt("track-list/count")
        for i in stride(from: count - 1, through: 0, by: -1) {
            let type = getString("track-list/\(i)/type") ?? ""
            let external = getFlag("track-list/\(i)/external")
            if type == "sub" && external {
                let id = getInt("track-list/\(i)/id")
                command("sub-remove", args: ["\(id)"], checkForErrors: false)
            }
        }
    }

    func setSubtitleFontPath(_ path: String) {
        subtitleFonts.setCustomFontPath(path.isEmpty ? nil : path)
    }

    func setSubtitleDelayMs(_ delayMs: Int) {
        lastSubtitleDelayMs = delayMs
        guard mpv != nil else { return }
        setDoubleProperty("sub-delay", Double(max(-60_000, min(60_000, delayMs))) / 1000.0)
    }

    func applySubtitleStyle(
        textColor: String,
        backgroundColor: String,
        outlineColor: String,
        outlineSize: Float,
        shadowOffset: Float,
        bold: Bool,
        fontSize: Float,
        subPos: Int,
        stripSdh: Bool
    ) {
        lastSubtitleStyle = SubtitleStyleSettings(
            textColor: textColor,
            backgroundColor: backgroundColor,
            outlineColor: outlineColor,
            outlineSize: outlineSize,
            shadowOffset: shadowOffset,
            bold: bold,
            fontSize: fontSize,
            subPos: subPos,
            stripSdh: stripSdh
        )
        guard mpv != nil else { return }

        let hasBackground = !backgroundColor.hasPrefix("#00")

        let effectiveOutlineColor = hasBackground ? backgroundColor : outlineColor
        let hasShadow = shadowOffset > 0
        let shadowColor = "#B3000000"
        let effectiveBackColor = (hasShadow && !hasBackground) ? shadowColor : backgroundColor
        let effectiveOutlineSize = hasBackground
            ? max(Double(outlineSize), 1.0)
            : Double(outlineSize)

        subtitleFonts.reapplyFont()
        setStringProperty("sub-ass-override", "no")
        setStringProperty("sub-color", textColor)
        setStringProperty("sub-back-color", effectiveBackColor)
        setStringProperty("sub-outline-color", effectiveOutlineColor)
        setStringProperty("sub-border-style", hasBackground ? "opaque-box" : "outline-and-shadow")
        setDoubleProperty("sub-shadow-offset", hasBackground ? 0 : Double(shadowOffset))
        setStringProperty("sub-bold", bold ? "yes" : "no")
        setDoubleProperty("sub-outline-size", effectiveOutlineSize)
        setDoubleProperty("sub-font-size", Double(fontSize))
        setIntProperty("sub-pos", Int64(subPos))
        setStringProperty("sub-filter-sdh", stripSdh ? "yes" : "no")
        setStringProperty("sub-filter-sdh-harder", stripSdh ? "yes" : "no")
    }

    func destroyPlayer() {
        pictureInPictureController?.invalidate()
        pictureInPictureController = nil
        NotificationCenter.default.removeObserver(self)
        if !isEmbeddedPreviewMode {
            UIApplication.shared.endReceivingRemoteControlEvents()
            resignFirstResponder()
        }
        pendingLoadRetryWorkItem?.cancel()
        pendingLoadRetryWorkItem = nil
        deviceLossRecoveryProbeWorkItem?.cancel()
        deviceLossRecoveryProbeWorkItem = nil
        deviceLossResumeTimeoutWorkItem?.cancel()
        deviceLossResumeTimeoutWorkItem = nil
        isDeviceLossResumePending = false
        isDeviceLossRecoveryPending = false
        pendingSurfaceLayoutWorkItems.forEach { $0.cancel() }
        pendingSurfaceLayoutWorkItems.removeAll(keepingCapacity: false)
        pendingLoadRequest = nil
        if !isEmbeddedPreviewMode {
            nowPlayingController.invalidate()
        }
        clearPlaybackError()
        if !isEmbeddedPreviewMode {
            deactivateAudioSession()
        }
        isPlayerDestroyed = true
        isRecoveringFromDeviceLoss = false
        releaseGpuProbeResources()
        flushPendingCoalescedLog()
        teardownMpvCore()
    }

    private func activateAudioSessionForPlayback() {
        audioSessionController.activate()
    }

    private func deactivateAudioSession() {
        audioSessionController.deactivate()
    }

    // MARK: - Media Info

    func getMediaInfoJson() -> String {
        guard mpv != nil else { return "{}" }
        scheduleMediaInfoRefreshIfNeeded()
        mediaInfoLock.lock()
        defer { mediaInfoLock.unlock() }
        return cachedMediaInfoJson
    }

    private func invalidateMediaInfoCache() {
        mediaInfoLock.lock()
        cachedMediaInfoJson = "{}"
        cachedVideoWidth = 0
        cachedVideoHeight = 0
        cachedFrameRate = 30.0
        lastMediaInfoRefreshTime = 0
        mediaInfoGeneration &+= 1
        mediaInfoLock.unlock()
    }

    private func scheduleMediaInfoRefreshIfNeeded() {
        let now = CACurrentMediaTime()
        mediaInfoLock.lock()
        let shouldRefresh = !isMediaInfoRefreshInFlight &&
            (now - lastMediaInfoRefreshTime) >= Self.mediaInfoRefreshInterval
        if shouldRefresh {
            isMediaInfoRefreshInFlight = true
            lastMediaInfoRefreshTime = now
        }
        let generation = mediaInfoGeneration
        mediaInfoLock.unlock()
        guard shouldRefresh else { return }

        let coreGeneration = mpvGeneration
        mpvQueue.async { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration else { return }
            let json = self.computeMediaInfoJson()
            let width = self.readCurrentVideoWidth()
            let height = self.readCurrentVideoHeight()
            let frameRate = self.readCurrentFrameRate()
            self.mediaInfoLock.lock()
            self.isMediaInfoRefreshInFlight = false
            if generation == self.mediaInfoGeneration {
                self.cachedMediaInfoJson = json
                self.cachedVideoWidth = width
                self.cachedVideoHeight = height
                self.cachedFrameRate = frameRate
            }
            self.mediaInfoLock.unlock()
        }
    }

    private func computeMediaInfoJson() -> String {
        guard mpv != nil else { return "{}" }
        let count = getInt("track-list/count")

        var videoCodec = getString("video-codec") ?? ""
        var videoDecoder = ""
        var dvProfile = ""
        var codecProfile = ""
        let filename = getString("filename") ?? ""
        let gamma = getString("video-params/gamma") ?? ""
        let primaries = getString("video-params/primaries") ?? ""
        let colorLevels = getString("video-params/colorlevels") ?? ""
        let pixelFormat = getString("video-out-params/pixelformat") ?? ""
        let videoWidth = getInt("video-params/w")
        let videoHeight = getInt("video-params/h")
        let fps = getDouble("container-fps")
        let hwdecCurrent = getString("hwdec-current") ?? ""
        var hdrFormat = ""

        for index in 0..<count {
            let type = getString("track-list/\(index)/type") ?? ""
            if type == "video" {
                videoCodec = getString("track-list/\(index)/codec") ?? videoCodec
                videoDecoder = getString("track-list/\(index)/decoder-desc") ?? ""
                dvProfile = getString("track-list/\(index)/dolby-vision-profile") ?? ""
                if dvProfile.isEmpty {
                    dvProfile = getString("track-list/\(index)/dv_profile") ?? ""
                }
                codecProfile = getString("track-list/\(index)/codec-profile") ?? ""
                let dvLower = dvProfile.lowercased()
                let isDolbyVision = !dvProfile.isEmpty &&
                    dvLower != "none" &&
                    dvLower != "unknown" &&
                    dvLower != "0" &&
                    dvLower != "false"
                if isDolbyVision ||
                    videoCodec.localizedCaseInsensitiveContains("dvhe") ||
                    videoCodec.localizedCaseInsensitiveContains("dvh1") ||
                    videoDecoder.localizedCaseInsensitiveContains("dovi") ||
                    codecProfile.localizedCaseInsensitiveContains("dovi") {
                    hdrFormat = "dolby_vision"
                }
                break
            }
        }

        if hdrFormat.isEmpty {
            if gamma.caseInsensitiveCompare("hlg") == .orderedSame {
                hdrFormat = "hlg"
            } else if gamma.caseInsensitiveCompare("pq") == .orderedSame {
                hdrFormat = "hdr"
            } else if primaries.caseInsensitiveCompare("bt.2020") == .orderedSame ||
                        primaries.caseInsensitiveCompare("bt.2020nc") == .orderedSame {
                hdrFormat = "hdr"
            } else if gamma.caseInsensitiveCompare("sdr") == .orderedSame {
                hdrFormat = "sdr"
            }
        }

        var audioCodec = getString("audio-codec") ?? ""
        var audioDecoder = ""
        var audioChannels = ""
        var audioSampleRate = ""
        var audioLang = ""
        for index in 0..<count {
            let type = getString("track-list/\(index)/type") ?? ""
            let selected = getFlag("track-list/\(index)/selected")
            if type == "audio" && selected {
                audioCodec = getString("track-list/\(index)/codec") ?? audioCodec
                audioDecoder = getString("track-list/\(index)/decoder-desc") ?? ""
                let channelCount = getInt("track-list/\(index)/demux-channel-count")
                audioChannels = channelCount > 0 ? "\(channelCount)" : ""
                let sampleRate = getInt("track-list/\(index)/demux-samplerate")
                audioSampleRate = sampleRate > 0 ? "\(sampleRate)" : ""
                audioLang = getString("track-list/\(index)/lang") ?? ""
                break
            }
        }

        let videoBitrate = getDouble("video-bitrate")
        let audioBitrate = getDouble("audio-bitrate")
        let videoBitrateKbps = videoBitrate.isFinite && videoBitrate > 0 ? Int(videoBitrate / 1000.0) : 0
        let audioBitrateKbps = audioBitrate.isFinite && audioBitrate > 0 ? Int(audioBitrate / 1000.0) : 0

        let payload: [String: Any] = [
            "engine": "libmpv",
            "filename": filename,
            "videoCodec": videoCodec,
            "videoDecoder": videoDecoder,
            "dvProfile": dvProfile,
            "codecProfile": codecProfile,
            "hdrFormat": hdrFormat,
            "gamma": gamma,
            "primaries": primaries,
            "colorLevels": colorLevels,
            "pixelFormat": pixelFormat,
            "videoWidth": videoWidth,
            "videoHeight": videoHeight,
            "fps": fps.isFinite ? fps : 0.0,
            "hwdecCurrent": hwdecCurrent,
            "audioCodec": audioCodec,
            "audioDecoder": audioDecoder,
            "audioChannels": audioChannels,
            "audioSampleRate": audioSampleRate,
            "audioLang": audioLang,
            "videoBitrateKbps": videoBitrateKbps,
            "audioBitrateKbps": audioBitrateKbps,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }

    private struct PlaybackStateSnapshot {
        let isLoading: Bool
        let isPlaying: Bool
        let isEnded: Bool
        let durationMs: Int64
        let positionMs: Int64
        let bufferedMs: Int64
        let speed: Float
    }

    func refreshPlaybackState() {
        guard mpv != nil else { return }

        stateRefreshLock.lock()
        if isPlaybackStateRefreshInFlight {
            stateRefreshLock.unlock()
            return
        }
        isPlaybackStateRefreshInFlight = true
        stateRefreshLock.unlock()

        let generation = playbackStateGeneration
        let coreGeneration = mpvGeneration
        mpvQueue.async { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration else { return }
            let snapshot = self.readPlaybackStateSnapshot()

            self.stateRefreshLock.lock()
            self.isPlaybackStateRefreshInFlight = false
            self.stateRefreshLock.unlock()

            guard let snapshot else { return }
            DispatchQueue.main.async {
                guard generation == self.playbackStateGeneration else { return }
                self.applyPlaybackStateSnapshot(snapshot)
            }
        }
    }

    private func readPlaybackStateSnapshot() -> PlaybackStateSnapshot? {
        guard mpv != nil else { return nil }
        let duration = getDouble("duration")
        let position = getDouble("time-pos")
        let cached = getDouble("demuxer-cache-time")
        let speed = getDouble("speed")
        let paused = getFlag("pause")
        let eofReached = getFlag("eof-reached")
        let idle = getFlag("core-idle")
        let seeking = getFlag("seeking")
        let bufferingCache = getFlag("paused-for-cache")

        return PlaybackStateSnapshot(
            isLoading: (idle && !paused && !eofReached) || seeking || bufferingCache,
            isPlaying: !paused && !idle && !eofReached,
            isEnded: eofReached,
            durationMs: Int64(duration * 1000),
            positionMs: Int64(max(position, 0) * 1000),
            bufferedMs: Int64(max(position + cached, 0) * 1000),
            speed: Float(speed > 0 ? speed : 1.0)
        )
    }

    var interpolatedPositionSeconds: Double {
        positionSampleLock.lock()
        let base = Double(positionSampleMs) / 1000.0
        let sampledAt = positionSampleTime
        let rate = positionSampleRate
        positionSampleLock.unlock()
        guard sampledAt > 0 else { return base }
        return base + max(0, CACurrentMediaTime() - sampledAt) * rate
    }

    private func applyPlaybackStateSnapshot(_ snapshot: PlaybackStateSnapshot) {
        isPlayerLoading = snapshot.isLoading
        isPlayerPlaying = snapshot.isPlaying
        isPlayerEnded = snapshot.isEnded
        durationMs = snapshot.durationMs
        positionMs = snapshot.positionMs
        bufferedMs = snapshot.bufferedMs
        currentSpeed = snapshot.speed

        positionSampleLock.lock()
        positionSampleMs = snapshot.positionMs
        positionSampleTime = CACurrentMediaTime()
        positionSampleRate = snapshot.isPlaying ? Double(snapshot.speed) : 0.0
        positionSampleLock.unlock()

        let shouldPublishNowPlayingState = !isEmbeddedPreviewMode &&
            (!isPlayerLoading || isPlayerPlaying || durationMs > 0 || positionMs > 0)
        if shouldPublishNowPlayingState {
            syncNowPlayingPlaybackState(isPlaying: isPlayerPlaying)
        }
    }

    private func syncNowPlayingPlaybackState(isPlaying: Bool) {
        let start = CACurrentMediaTime()
        pictureInPictureController?.updatePlaybackState()
        nowPlayingController.syncPlayback(
            positionMs: positionMs,
            durationMs: durationMs,
            isPlaying: isPlaying,
            playbackSpeed: currentSpeed
        )
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        if elapsedMs >= 100 {
            InAppLogBridge.shared.warn(
                tag: "Audio/iOS",
                message: "Now Playing sync (isPlaying=\(isPlaying)) took \(Int(elapsedMs))ms on main thread"
            )
        }
    }

    func updateState() {
        refreshPlaybackState()
        refreshTracks()
    }

    private func refreshTracks() {
        guard mpv != nil else { return }

        stateRefreshLock.lock()
        if isTrackRefreshInFlight {
            stateRefreshLock.unlock()
            return
        }
        isTrackRefreshInFlight = true
        stateRefreshLock.unlock()

        let coreGeneration = mpvGeneration
        mpvQueue.async { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration else { return }
            let tracks = self.readTracks()

            self.stateRefreshLock.lock()
            self.isTrackRefreshInFlight = false
            self.stateRefreshLock.unlock()

            guard let tracks else { return }
            DispatchQueue.main.async {
                self.audioTracks = tracks.audio
                self.subtitleTracks = tracks.subtitles
            }
        }
    }

    private func readTracks() -> (audio: [TrackInfo], subtitles: [TrackInfo])? {
        guard mpv != nil else { return nil }
        var audio = [TrackInfo]()
        var subs = [TrackInfo]()
        let count = getInt("track-list/count")
        var audioIdx = 0
        var subIdx = 0

        for i in 0..<count {
            let type = getString("track-list/\(i)/type") ?? ""
            let id = getInt("track-list/\(i)/id")
            let title = getTrackString(i, "title")
            let lang = getTrackString(i, "lang")
            let codec = getTrackString(i, "codec")
            let decoderDescription = getTrackString(i, "decoder-desc")
            let channels = getTrackString(i, "demux-channels")
            let channelCount = getInt("track-list/\(i)/demux-channel-count")
            let selected = getFlag("track-list/\(i)/selected")
            let displayTitle = formatTrackTitle(
                type: type,
                index: type == "audio" ? audioIdx : subIdx,
                title: title,
                lang: lang,
                codec: codec,
                decoderDescription: decoderDescription,
                channels: channels,
                channelCount: channelCount
            )

            if type == "audio" {
                audio.append(TrackInfo(index: audioIdx, id: id, type: type, title: displayTitle, lang: lang, selected: selected))
                audioIdx += 1
            } else if type == "sub" {
                subs.append(TrackInfo(index: subIdx, id: id, type: type, title: displayTitle, lang: lang, selected: selected))
                subIdx += 1
            }
        }
        return (audio, subs)
    }

    func updateNowPlayingMetadata(
        title: String,
        subtitle: String?,
        artworkUrl: String?
    ) {
        cachedNowPlayingMetadata = CachedNowPlayingMetadata(
            title: title,
            subtitle: subtitle,
            artworkUrl: artworkUrl
        )
        nowPlayingController.updateMetadata(
            title: title,
            subtitle: subtitle,
            artworkUrl: artworkUrl
        )
        publishNowPlayingForPlaybackSession()
    }

    func clearNowPlayingInfo() {
        cachedNowPlayingMetadata = nil
        nowPlayingController.clear()
    }

    private func publishCachedNowPlayingInfoIfNeeded() {
        guard let metadata = cachedNowPlayingMetadata else { return }
        nowPlayingController.updateMetadata(
            title: metadata.title,
            subtitle: metadata.subtitle,
            artworkUrl: metadata.artworkUrl
        )
    }

    private func publishNowPlayingForPlaybackSession() {
        guard !isEmbeddedPreviewMode else { return }
        activateAudioSessionForPlayback()
        if isViewLoaded, view.window != nil {
            becomeFirstResponder()
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()
        publishCachedNowPlayingInfoIfNeeded()
        syncNowPlayingPlaybackState(isPlaying: isPlayerPlaying)
    }

    private func getTrackString(_ index: Int, _ field: String) -> String {
        (getString("track-list/\(index)/\(field)") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatTrackTitle(
        type: String,
        index: Int,
        title: String,
        lang: String,
        codec: String,
        decoderDescription: String,
        channels: String,
        channelCount: Int
    ) -> String {
        let base = ifNotBlank(title)
            ?? localizedLanguageName(lang)
            ?? (type == "sub" ? "Subtitle \(index + 1)" : "Track \(index + 1)")
        let codecName = codecDisplayName(codec) ?? codecDisplayName(decoderDescription)
        let channelName = type == "audio" ? channelLayoutName(channels: channels, channelCount: channelCount) : nil
        let details = [channelName, codecName]
            .compactMap { $0 }
            .filter { detail in !base.localizedCaseInsensitiveContains(detail) }
        return details.isEmpty ? base : "\(base) (\(details.joined(separator: ", ")))"
    }

    private func ifNotBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func localizedLanguageName(_ languageCode: String) -> String? {
        guard let code = ifNotBlank(languageCode) else { return nil }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private func channelLayoutName(channels: String, channelCount: Int) -> String? {
        if let normalized = ifNotBlank(channels), normalized != "unknown" {
            let lower = normalized.lowercased()
            if lower == "mono" { return "Mono" }
            if lower == "stereo" { return "Stereo" }
            return normalized
        }
        switch channelCount {
        case 1:
            return "Mono"
        case 2:
            return "Stereo"
        case 6:
            return "5.1"
        case 8:
            return "7.1"
        case let count where count > 0:
            return "\(count)ch"
        default:
            return nil
        }
    }

    private func codecDisplayName(_ value: String) -> String? {
        guard let raw = ifNotBlank(value) else { return nil }
        let codec = raw.lowercased()
        if codec.contains("eac3") || codec.contains("e-ac-3") || codec.contains("e ac-3") {
            return codec.contains("joc") || codec.contains("atmos") ? "E-AC-3-JOC" : "E-AC-3"
        }
        if codec.contains("truehd") || codec.contains("true hd") { return "TrueHD" }
        if codec.contains("ac3") || codec.contains("ac-3") { return "AC-3" }
        if codec.contains("dts-hd") || codec.contains("dtshd") || codec.contains("dts hd") { return "DTS-HD" }
        if codec.contains("dts") || codec == "dca" { return "DTS" }
        if codec.contains("aac") { return "AAC" }
        if codec.contains("mp3") || codec.contains("mpeg audio") { return "MP3" }
        if codec.contains("mp2") { return "MP2" }
        if codec.contains("opus") { return "Opus" }
        if codec.contains("vorbis") { return "Vorbis" }
        if codec.contains("flac") { return "FLAC" }
        if codec.contains("alac") { return "ALAC" }
        if codec.contains("pcm") || codec.contains("wav") { return "WAV" }
        if codec.contains("amr_wb") || codec.contains("amr-wb") { return "AMR-WB" }
        if codec.contains("amr_nb") || codec.contains("amr-nb") { return "AMR-NB" }
        if codec.contains("amr") { return "AMR" }
        if codec.contains("iamf") { return "IAMF" }
        if codec.contains("mpegh") || codec.contains("mpeg-h") { return "MPEG-H" }
        if codec.contains("pgs") || codec.contains("hdmv") { return "PGS" }
        if codec.contains("subrip") || codec == "srt" { return "SRT" }
        if codec.contains("ass") || codec.contains("ssa") { return "SSA" }
        if codec.contains("webvtt") || codec == "vtt" { return "VTT" }
        if codec.contains("ttml") { return "TTML" }
        if codec.contains("mov_text") || codec.contains("tx3g") { return "TX3G" }
        if codec.contains("dvb") { return "DVB" }
        return raw
    }

    private func clearPlaybackError() {
        errorStateLock.lock()
        recentPlaybackLogs.removeAll(keepingCapacity: true)
        _currentErrorMessage = nil
        errorStateLock.unlock()
    }

    private func appendPlaybackLog(prefix: String, level: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard level == "warn" || level == "error" || level == "fatal" else { return }

        if !sawDeviceLossInLog, trimmed.contains("VK_ERROR_DEVICE_LOST") {
            sawDeviceLossInLog = true
            handleVideoOutputDeviceLost()
        }

        if emitCoalescedLog(prefix: prefix, level: level, text: trimmed) {
            InAppLogBridge.shared.mpv(platform: "iOS", prefix: prefix, level: level, message: trimmed)
        }

        let formatted = "[\(prefix)] \(trimmed)"
        errorStateLock.lock()
        recentPlaybackLogs.append(formatted)
        if recentPlaybackLogs.count > 4 {
            recentPlaybackLogs.removeFirst(recentPlaybackLogs.count - 4)
        }
        errorStateLock.unlock()
    }

    private func emitCoalescedLog(prefix: String, level: String, text: String) -> Bool {
        let key = "\(prefix)|\(level)|\(text)"
        let now = CACurrentMediaTime()

        var summary: String?
        logCoalesceLock.lock()
        if var entry = throttledLogEntries[key] {
            entry.count += 1
            if now - entry.lastEmitTime >= Self.logCoalesceInterval {
                summary = "\(text) (repeated ×\(entry.count))"
                entry.count = 0
                entry.lastEmitTime = now
            }
            throttledLogEntries[key] = entry
            logCoalesceLock.unlock()

            if let summary {
                InAppLogBridge.shared.mpv(platform: "iOS", prefix: prefix, level: level, message: summary)
            }
            return false
        }

        if throttledLogEntries.count > 64 { throttledLogEntries.removeAll(keepingCapacity: true) }
        throttledLogEntries[key] = ThrottledLogEntry(
            prefix: prefix,
            level: level,
            text: text,
            count: 0,
            lastEmitTime: now
        )
        logCoalesceLock.unlock()
        return true
    }

    private func flushPendingCoalescedLog() {
        logCoalesceLock.lock()
        let pending = throttledLogEntries.values.filter { $0.count > 0 }
        throttledLogEntries.removeAll(keepingCapacity: false)
        logCoalesceLock.unlock()

        for entry in pending {
            InAppLogBridge.shared.mpv(
                platform: "iOS",
                prefix: entry.prefix,
                level: entry.level,
                message: "\(entry.text) (repeated ×\(entry.count))"
            )
        }
    }

    private func setPlaybackError(_ fallback: String) {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        errorStateLock.lock()
        var parts = recentPlaybackLogs.suffix(3)
        if !trimmedFallback.isEmpty && !parts.contains(trimmedFallback) {
            parts.append(trimmedFallback)
        }
        _currentErrorMessage = parts.isEmpty ? "Unable to play this stream." : parts.joined(separator: "\n")
        errorStateLock.unlock()
    }

    // MARK: - Event Loop

    private func readEvents() {
        let coreGeneration = mpvGeneration
        eventQueue.async { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration, let mpv = self.mpv else { return }

            while true {
                let event = mpv_wait_event(mpv, 0)
                guard let eventPtr = event else { break }
                if eventPtr.pointee.event_id == MPV_EVENT_NONE { break }

                switch eventPtr.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    self.subtitleFonts.handlePropertyChange(eventPtr)
                    DispatchQueue.main.async { self.updateState() }
                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async {
                        self.clearPlaybackError()
                        self.isPlayerLoading = false
                        self.playbackStateGeneration &+= 1
                        self.invalidateMediaInfoCache()
                        self.updateState()
                        if !self.isEmbeddedPreviewMode {
                            self.publishNowPlayingForPlaybackSession()
                        }
                        self.logCurrentAudioOutput()
                        self.performDeviceLossResume()
                    }
                case MPV_EVENT_PLAYBACK_RESTART:
                    DispatchQueue.main.async {
                        self.updateState()
                        if !self.isEmbeddedPreviewMode {
                            self.publishNowPlayingForPlaybackSession()
                        }
                    }
                case MPV_EVENT_END_FILE:
                    if let data = eventPtr.pointee.data {
                        let endFile = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                        if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errorText = String(cString: mpv_error_string(endFile.error))
                            DispatchQueue.main.async { self.cancelPendingDeviceLossResume() }
                            self.setPlaybackError("[mpv] \(errorText)")
                            InAppLogBridge.shared.error(tag: "MPV/iOS", message: "End file error: \(errorText)")
                            print("[MPV] End file error: \(errorText)")
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(eventPtr.pointee.data)) {
                        let prefix = String(cString: msg.pointee.prefix!)
                        let level = String(cString: msg.pointee.level!)
                        let text = String(cString: msg.pointee.text!)
                        self.appendPlaybackLog(prefix: prefix, level: level, text: text)
                        print("[MPV][\(prefix)] \(level): \(text)", terminator: "")
                    }
                default:
                    break
                }
            }
        }
    }

    var currentVideoWidth: Int {
        scheduleMediaInfoRefreshIfNeeded()
        mediaInfoLock.lock()
        defer { mediaInfoLock.unlock() }
        return cachedVideoWidth
    }

    var currentVideoHeight: Int {
        scheduleMediaInfoRefreshIfNeeded()
        mediaInfoLock.lock()
        defer { mediaInfoLock.unlock() }
        return cachedVideoHeight
    }

    var currentRenderFrameRate: Double {
        scheduleMediaInfoRefreshIfNeeded()
        mediaInfoLock.lock()
        defer { mediaInfoLock.unlock() }
        return cachedFrameRate
    }

    private func readCurrentFrameRate() -> Double {
        let container = getDouble("container-fps")
        if container.isFinite, container >= 12 { return container }
        let estimated = getDouble("estimated-vf-fps")
        return estimated.isFinite && estimated >= 12 ? estimated : 30.0
    }

    private func readCurrentVideoWidth() -> Int {
        let width = getInt("video-out-params/w")
        return width > 0 ? width : getInt("video-params/w")
    }

    private func readCurrentVideoHeight() -> Int {
        let height = getInt("video-out-params/h")
        return height > 0 ? height : getInt("video-params/h")
    }

    // MARK: - MPV Helpers

    func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true) {
        guard mpv != nil else { return }
        let argv = makeCArgs(command, args)
        withMpvOnQueue { [weak self] ctx in
            var cargs = argv.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
            defer { for ptr in cargs where ptr != nil { free(UnsafeMutablePointer(mutating: ptr!)) } }
            let ret = mpv_command(ctx, &cargs)
            if checkForErrors { self?.checkError(ret) }
        }
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        return strArgs
    }

    func getDouble(_ name: String) -> Double {
        guard let ctx = mpv else { return 0.0 }
        var data = Double()
        mpv_get_property(ctx, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    fileprivate func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        let cstr = mpv_get_property_string(mpv, name)
        let str: String? = cstr == nil ? nil : String(cString: cstr!)
        mpv_free(cstr)
        return str
    }

    func getFlag(_ name: String) -> Bool {
        guard let ctx = mpv else { return false }
        var data = CInt(0)
        mpv_get_property(ctx, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    func setFlag(_ name: String, _ flag: Bool) {
        withMpvOnQueue { ctx in
            var data = CInt(flag ? 1 : 0)  // MPV_FORMAT_FLAG is a C int
            mpv_set_property(ctx, name, MPV_FORMAT_FLAG, &data)
        }
    }

    func setStringProperty(_ name: String, _ value: String) {
        withMpvOnQueue { [weak self] ctx in
            self?.checkError(mpv_set_property_string(ctx, name, value))
        }
    }

    private func setDoubleProperty(_ name: String, _ value: Double) {
        withMpvOnQueue { [weak self] ctx in
            var data = value
            self?.checkError(mpv_set_property(ctx, name, MPV_FORMAT_DOUBLE, &data))
        }
    }

    private func setIntProperty(_ name: String, _ value: Int64) {
        withMpvOnQueue { [weak self] ctx in
            var data = value
            self?.checkError(mpv_set_property(ctx, name, MPV_FORMAT_INT64, &data))
        }
    }

    private func setVideoEqualizer(_ name: String, _ value: Int) {
        setIntProperty(name, Int64(max(-100, min(100, value))))
    }

    private func getInt(_ name: String) -> Int {
        guard let ctx = mpv else { return 0 }
        var data = Int64()
        mpv_get_property(ctx, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func logCurrentAudioOutput() {
        let coreGeneration = mpvGeneration
        mpvQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.mpvGeneration == coreGeneration, self.mpv != nil else { return }
            let currentAo = self.getString("current-ao") ?? "unknown"
            let channels = self.getString("audio-out-params/hr-channels")
                ?? self.getString("audio-params/hr-channels")
                ?? "unknown"
            let channelCount = self.getInt("audio-out-params/channel-count")
            let codec = self.getString("audio-codec-name") ?? "unknown"
            let message = "Audio output: ao=\(currentAo), channels=\(channels), channelCount=\(channelCount), codec=\(codec)"
            InAppLogBridge.shared.info(tag: "MPV/iOS", message: message)
            print("[MPV] \(message)")
        }
    }

    func checkError(_ status: CInt) {
        if status < 0 {
            let message = "API error: \(String(cString: mpv_error_string(status)))"
            InAppLogBridge.shared.warn(tag: "MPV/iOS", message: message)
            print("[MPV] \(message)")
        }
    }

    private func redactedPlaybackUrlForLogs(_ urlString: String, maxLength: Int = 180) -> String {
        let withoutQuery = urlString.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? urlString
        if withoutQuery.count <= maxLength {
            return withoutQuery
        }
        return String(withoutQuery.prefix(maxLength)) + "…"
    }

    private func sanitizeRequestHeaders(_ headers: [String: String]) -> [String: String] {
        guard !headers.isEmpty else { return [:] }

        var sanitized: [String: String] = [:]
        sanitized.reserveCapacity(headers.count)
        headers.forEach { rawKey, rawValue in
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            guard key.caseInsensitiveCompare("Range") != .orderedSame else { return }
            sanitized[key] = value
        }
        return sanitized
    }

    private func applyRequestHeaders(_ headers: [String: String]) {
        guard mpv != nil else { return }
        if headers.isEmpty {
            setStringProperty("http-header-fields", "")
            return
        }

        let serialized = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                let escapedValue = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: ",", with: "\\,")
                return "\(key): \(escapedValue)"
            }
            .joined(separator: ",")
        setStringProperty("http-header-fields", serialized)
    }

    private func refreshImmersiveSystemUI() {
        guard !isEmbeddedPreviewMode else { return }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()

        var currentParent = parent
        while let controller = currentParent {
            controller.setNeedsUpdateOfHomeIndicatorAutoHidden()
            controller.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            controller.setNeedsStatusBarAppearanceUpdate()
            if let rootController = controller as? RootComposeViewController {
                rootController.refreshImmersiveSystemUI()
            }
            currentParent = controller.parent
        }
    }

    private func publishImmersiveSystemUIVisibility(isVisible: Bool) {
        guard !isEmbeddedPreviewMode else { return }
        if isVisible {
            SystemUI.shared.playerDidBecomeVisible(self)
        } else {
            SystemUI.shared.playerDidBecomeHidden(self)
        }
        NotificationCenter.default.post(
            name: nuvioPlayerImmersiveSystemUIVisibilityDidChange,
            object: self,
            userInfo: [nuvioPlayerImmersiveSystemUIVisibleKey: isVisible]
        )
    }

    // MARK: - Hardware keyboard shortcuts

    // mpv's view controller sees hardware key presses that never reach Compose, so it recognises
    // them here — but it deliberately does NOT act on the player itself. It reports the shortcut
    // to Kotlin, which runs the same action a tap or gesture would, so seek feedback, control
    // reveal and watch-progress syncing behave identically whichever layer caught the key.
    private enum KeyboardShortcut: String {
        case togglePlayback = "toggle_playback"
        case seekBackward = "seek_backward"
        case seekForward = "seek_forward"
        case exit

        init?(key: UIKey) {
            switch key.charactersIgnoringModifiers {
            case UIKeyCommand.inputEscape: self = .exit
            case UIKeyCommand.inputLeftArrow: self = .seekBackward
            case UIKeyCommand.inputRightArrow: self = .seekForward
            case " ": self = .togglePlayback
            default: return nil
            }
        }
    }

    func setKeyboardShortcutsEnabled(_ enabled: Bool) {
        keyboardShortcutsEnabled = enabled
    }

    func setKeyboardShortcutHandler(_ handler: ((String) -> Void)?) {
        keyboardShortcutHandler = handler
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard keyboardShortcutsEnabled, let handler = keyboardShortcutHandler else {
            super.pressesBegan(presses, with: event)
            return
        }

        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let shortcut = KeyboardShortcut(key: key) else {
                unhandled.insert(press)
                continue
            }
            handler(shortcut.rawValue)
        }

        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }
}

// MARK: - Bridge Creator (implements Kotlin protocol)

final class MPVPlayerBridgeCreator: NSObject, NuvioPlayerBridgeCreator {
    func createBridge() -> any NuvioPlayerBridge {
        return MPVPlayerBridgeImpl()
    }
}

// MARK: - Registration (called from Swift app startup)

enum NuvioPlayerRegistration {
    static func register() {
        NuvioPlayerBridgeFactory.shared.registerFactory(creator: MPVPlayerBridgeCreator())
        NuvioSeekPreviewRegistry.shared.registerCreator(creator: FFmpegSeekPreviewGeneratorCreator())
    }
}

private final class AirPlayPlayerViewController: UIViewController {
    var onDismiss: (() -> Void)?
    var onExternalPlaybackEnded: ((Int64, Bool) -> Void)?
    var player: AVPlayer?
    private var displayTitle = "Now Playing"
    private var knownDurationSeconds: Double = 0
    private var timelineOffsetSeconds: Double = 0
    private var isScrubbing = false
    private var playbackSpeed: Float = 1
    private var isPreparingRelay = false
    private var didBecomeExternallyActive = false
    private var isEndingSession = false
    private weak var trackedPlayer: AVPlayer?
    private weak var trackedItem: AVPlayerItem?
    private var periodicTimeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?

    private lazy var remoteScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        return scrollView
    }()

    private lazy var remoteContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor(white: 0.08, alpha: 0.96)
        view.layer.cornerRadius = 24
        view.layer.cornerCurve = .continuous
        return view
    }()

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .systemGreen
        label.textAlignment = .center
        label.text = "Connecting to AirPlay…"
        return label
    }()

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .title2)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private lazy var currentTimeLabel = makeTimeLabel(alignment: .left)
    private lazy var remainingTimeLabel = makeTimeLabel(alignment: .right)

    private lazy var timelineSlider: UISlider = {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .systemBlue
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
        slider.addTarget(self, action: #selector(scrubbingBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubbingChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubbingEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }()

    private lazy var rewindButton = makeTransportButton(
        systemName: "gobackward.15",
        accessibilityLabel: "Rewind 15 seconds",
        action: #selector(rewindTapped)
    )

    private lazy var playPauseButton = makeTransportButton(
        systemName: "pause.fill",
        accessibilityLabel: "Play or pause",
        action: #selector(playPauseTapped),
        pointSize: 34
    )

    private lazy var forwardButton = makeTransportButton(
        systemName: "goforward.30",
        accessibilityLabel: "Forward 30 seconds",
        action: #selector(forwardTapped)
    )

    private lazy var subtitlesButton = makeMenuButton(title: "Subtitles", systemName: "captions.bubble")
    private lazy var audioButton = makeMenuButton(title: "Audio", systemName: "waveform")
    private lazy var speedButton = makeMenuButton(title: "Speed", systemName: "speedometer")

    private lazy var routePicker: AVRoutePickerView = {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.widthAnchor.constraint(equalToConstant: 44),
            picker.heightAnchor.constraint(equalToConstant: 44),
        ])
        return picker
    }()

    private lazy var volumeView: MPVolumeView = {
        let volume = MPVolumeView(frame: .zero)
        volume.showsRouteButton = false
        volume.showsVolumeSlider = true
        return volume
    }()

    private lazy var stopButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Stop playback"
        configuration.image = UIImage(systemName: "stop.fill")
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = .systemRed
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        return button
    }()

    private lazy var preparingIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = .white
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        installRemoteInterface()
        refreshSpeedMenu()
        showUnavailableMediaMenus()
        refreshInterface()
    }

    func configure(displayTitle: String?, knownDurationMs: Int64, initialPositionMs: Int64) {
        let cleanedTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayTitle = cleanedTitle?.isEmpty == false ? cleanedTitle! : "Now Playing"
        knownDurationSeconds = max(0, Double(knownDurationMs) / 1000)
        timelineOffsetSeconds = 0
        loadViewIfNeeded()
        titleLabel.text = self.displayTitle
        updateTimeline(positionSeconds: max(0, Double(initialPositionMs) / 1000))
    }

    func setRelayTimelineOffset(positionMs: Int64) {
        timelineOffsetSeconds = max(0, Double(positionMs) / 1000)
        statusLabel.text = "Playing on TV through compatibility relay"
        timelineSlider.isEnabled = false
        rewindButton.isEnabled = false
        forwardButton.isEnabled = false
    }

    func attach(player: AVPlayer, item: AVPlayerItem) {
        unbindPlayer()
        trackedPlayer = player
        trackedItem = item
        self.player = player
        didBecomeExternallyActive = false

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshInterface() }
        }
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleExternalPlaybackChange() }
        }
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshInterface()
                self?.refreshMediaMenus()
            }
        }
        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshInterface() }
        }
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            self?.refreshInterface()
        }
        refreshMediaMenus()
        refreshInterface()
    }

    func setPreparingRelay(_ preparing: Bool) {
        isPreparingRelay = preparing
        if preparing {
            statusLabel.text = "Preparing compatible TV stream…"
            if preparingIndicator.superview == nil {
                remoteContainer.addSubview(preparingIndicator)
                NSLayoutConstraint.activate([
                    preparingIndicator.centerXAnchor.constraint(equalTo: remoteContainer.centerXAnchor),
                    preparingIndicator.centerYAnchor.constraint(equalTo: remoteContainer.centerYAnchor),
                ])
            }
            preparingIndicator.startAnimating()
            setRemoteControlsEnabled(false)
        } else {
            preparingIndicator.stopAnimating()
            preparingIndicator.removeFromSuperview()
            setRemoteControlsEnabled(true)
        }
    }

    private func installRemoteInterface() {
        let overlay = view!
        overlay.addSubview(remoteScrollView)
        remoteScrollView.addSubview(remoteContainer)

        let timeRow = UIStackView(arrangedSubviews: [currentTimeLabel, UIView(), remainingTimeLabel])
        timeRow.axis = .horizontal

        let transport = UIStackView(arrangedSubviews: [rewindButton, playPauseButton, forwardButton])
        transport.axis = .horizontal
        transport.alignment = .center
        transport.distribution = .equalSpacing
        transport.spacing = 28

        let optionButtons = UIStackView(arrangedSubviews: [subtitlesButton, audioButton, speedButton])
        optionButtons.axis = .horizontal
        optionButtons.alignment = .fill
        optionButtons.distribution = .fillEqually
        optionButtons.spacing = 10

        let outputLabel = UILabel()
        outputLabel.text = "Output / Disconnect"
        outputLabel.textColor = .white
        outputLabel.font = .preferredFont(forTextStyle: .body)
        let routeRow = UIStackView(arrangedSubviews: [outputLabel, UIView(), routePicker])
        routeRow.axis = .horizontal
        routeRow.alignment = .center

        let volumeLabel = UILabel()
        volumeLabel.text = "Volume"
        volumeLabel.textColor = .secondaryLabel
        volumeLabel.font = .preferredFont(forTextStyle: .caption1)

        let stack = UIStackView(arrangedSubviews: [
            statusLabel,
            titleLabel,
            timelineSlider,
            timeRow,
            transport,
            optionButtons,
            volumeLabel,
            volumeView,
            routeRow,
            stopButton,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.setCustomSpacing(22, after: titleLabel)
        stack.setCustomSpacing(24, after: timeRow)
        stack.setCustomSpacing(24, after: transport)
        remoteContainer.addSubview(stack)

        let preferredContainerWidth = remoteContainer.widthAnchor.constraint(
            equalTo: remoteScrollView.frameLayoutGuide.widthAnchor,
            multiplier: 0.9
        )
        preferredContainerWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            remoteScrollView.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor),
            remoteScrollView.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor),
            remoteScrollView.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor),
            remoteScrollView.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor),

            remoteContainer.centerXAnchor.constraint(equalTo: remoteScrollView.frameLayoutGuide.centerXAnchor),
            remoteContainer.topAnchor.constraint(equalTo: remoteScrollView.contentLayoutGuide.topAnchor, constant: 12),
            remoteContainer.bottomAnchor.constraint(equalTo: remoteScrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            remoteScrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: remoteScrollView.frameLayoutGuide.widthAnchor),
            remoteContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            remoteContainer.widthAnchor.constraint(lessThanOrEqualTo: remoteScrollView.frameLayoutGuide.widthAnchor, multiplier: 0.9),
            preferredContainerWidth,

            stack.leadingAnchor.constraint(equalTo: remoteContainer.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: remoteContainer.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: remoteContainer.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: remoteContainer.bottomAnchor, constant: -22),

            rewindButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            rewindButton.heightAnchor.constraint(equalToConstant: 56),
            playPauseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            playPauseButton.heightAnchor.constraint(equalToConstant: 72),
            forwardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            forwardButton.heightAnchor.constraint(equalToConstant: 56),
            stopButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    private func makeTimeLabel(alignment: NSTextAlignment) -> UILabel {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = alignment
        label.text = "--:--"
        return label
    }

    private func makeTransportButton(
        systemName: String,
        accessibilityLabel: String,
        action: Selector,
        pointSize: CGFloat = 27
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = pointSize > 30 ? 36 : 28
        button.setImage(
            UIImage(systemName: systemName)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)),
            for: .normal
        )
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeMenuButton(title: String, systemName: String) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: systemName)
        configuration.imagePlacement = .top
        configuration.imagePadding = 5
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.14)
        configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        return button
    }

    private func showUnavailableMediaMenus() {
        let unavailable = UIAction(title: "Not available in this stream", attributes: .disabled) { _ in }
        subtitlesButton.menu = UIMenu(title: "Subtitles", children: [unavailable])
        audioButton.menu = UIMenu(title: "Audio", children: [unavailable])
    }

    private func refreshMediaMenus() {
        guard let item = trackedItem, item.status == .readyToPlay else { return }
        let asset = item.asset
        let key = "availableMediaCharacteristicsWithMediaSelectionOptions"
        asset.loadValuesAsynchronously(forKeys: [key]) { [weak self, weak item] in
            var error: NSError?
            guard asset.statusOfValue(forKey: key, error: &error) == .loaded else { return }
            DispatchQueue.main.async {
                guard let self, let item, self.trackedItem === item else { return }
                self.installMediaMenus(for: item)
            }
        }
    }

    private func installMediaMenus(for item: AVPlayerItem) {
        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            var actions: [UIAction] = []
            if group.allowsEmptySelection {
                actions.append(UIAction(
                    title: "Off",
                    state: item.currentMediaSelection.selectedMediaOption(in: group) == nil ? .on : .off
                ) { [weak self, weak item] _ in
                    guard let self, let item else { return }
                    item.select(nil, in: group)
                    self.installMediaMenus(for: item)
                })
            }
            actions += group.options.map { option in
                let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                return UIAction(
                    title: option.displayName,
                    state: selected?.isEqual(option) == true ? .on : .off
                ) { [weak self, weak item] _ in
                    guard let self, let item else { return }
                    item.select(option, in: group)
                    self.installMediaMenus(for: item)
                }
            }
            subtitlesButton.menu = UIMenu(title: "Subtitles", children: actions)
            subtitlesButton.isEnabled = !group.options.isEmpty
        } else {
            subtitlesButton.isEnabled = false
        }

        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            let actions = group.options.map { option in
                UIAction(
                    title: option.displayName,
                    state: selected?.isEqual(option) == true ? .on : .off
                ) { [weak self, weak item] _ in
                    guard let self, let item else { return }
                    item.select(option, in: group)
                    self.installMediaMenus(for: item)
                }
            }
            audioButton.menu = UIMenu(title: "Audio", children: actions)
            audioButton.isEnabled = !actions.isEmpty
        } else {
            audioButton.isEnabled = false
        }
    }

    private func refreshSpeedMenu() {
        let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
        let actions = speeds.map { speed in
            UIAction(
                title: speed == 1 ? "Normal" : "\(speed.formatted())×",
                state: abs(speed - playbackSpeed) < 0.001 ? .on : .off
            ) { [weak self] _ in
                guard let self, let player = self.trackedPlayer else { return }
                self.playbackSpeed = speed
                player.defaultRate = speed
                if player.timeControlStatus == .playing { player.rate = speed }
                self.refreshSpeedMenu()
            }
        }
        speedButton.menu = UIMenu(title: "Playback Speed", children: actions)
    }

    private func refreshInterface() {
        guard isViewLoaded else { return }
        titleLabel.text = displayTitle
        guard let player = trackedPlayer else {
            playPauseButton.isEnabled = false
            return
        }

        playPauseButton.isEnabled = trackedItem?.status != .failed
        let isPlaying = player.timeControlStatus == .playing
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(
            UIImage(systemName: symbol)?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)),
            for: .normal
        )
        if !isPreparingRelay {
            statusLabel.text = player.isExternalPlaybackActive ? "Playing on TV" : "Connecting to AirPlay…"
        }
        if !isScrubbing {
            updateTimeline(positionSeconds: resolvedPositionSeconds(player: player))
        }
    }

    private func updateTimeline(positionSeconds: Double) {
        let duration = resolvedDurationSeconds
        let position = min(max(0, positionSeconds), duration > 0 ? duration : max(positionSeconds, 1))
        currentTimeLabel.text = formatTime(position)
        if duration > 0 {
            timelineSlider.maximumValue = Float(duration)
            timelineSlider.value = Float(position)
            timelineSlider.isEnabled = timelineOffsetSeconds == 0
            remainingTimeLabel.text = "−\(formatTime(max(0, duration - position)))"
        } else {
            timelineSlider.maximumValue = 1
            timelineSlider.value = 0
            timelineSlider.isEnabled = false
            remainingTimeLabel.text = "Live"
        }
    }

    private var resolvedDurationSeconds: Double {
        if let seconds = trackedItem?.duration.seconds, seconds.isFinite, seconds > 0 {
            return seconds + timelineOffsetSeconds
        }
        return knownDurationSeconds
    }

    private func resolvedPositionSeconds(player: AVPlayer) -> Double {
        let seconds = player.currentTime().seconds
        return (seconds.isFinite ? max(0, seconds) : 0) + timelineOffsetSeconds
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds) }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func setRemoteControlsEnabled(_ enabled: Bool) {
        [rewindButton, playPauseButton, forwardButton, subtitlesButton, audioButton, speedButton, stopButton]
            .forEach { $0.isEnabled = enabled }
        let seekingEnabled = enabled && timelineOffsetSeconds == 0
        rewindButton.isEnabled = seekingEnabled
        forwardButton.isEnabled = seekingEnabled
        timelineSlider.isEnabled = seekingEnabled && resolvedDurationSeconds > 0
    }

    @objc private func playPauseTapped() {
        guard let player = trackedPlayer else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.playImmediately(atRate: playbackSpeed)
        }
        refreshInterface()
    }

    @objc private func rewindTapped() { seekBy(seconds: -15) }
    @objc private func forwardTapped() { seekBy(seconds: 30) }

    private func seekBy(seconds: Double) {
        guard let player = trackedPlayer, timelineOffsetSeconds == 0 else { return }
        let duration = resolvedDurationSeconds
        let current = resolvedPositionSeconds(player: player)
        let target = min(max(0, current + seconds), duration > 0 ? duration : current + max(seconds, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000))
        updateTimeline(positionSeconds: target)
    }

    @objc private func scrubbingBegan() {
        isScrubbing = true
    }

    @objc private func scrubbingChanged() {
        updateTimeline(positionSeconds: Double(timelineSlider.value))
    }

    @objc private func scrubbingEnded() {
        guard let player = trackedPlayer else { return }
        isScrubbing = false
        let target = Double(timelineSlider.value)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000))
        updateTimeline(positionSeconds: target)
    }

    @objc private func stopTapped() {
        isEndingSession = true
        trackedPlayer?.pause()
        dismiss(animated: true)
    }

    private func handleExternalPlaybackChange() {
        guard let player = trackedPlayer else { return }
        if player.isExternalPlaybackActive {
            didBecomeExternallyActive = true
        } else if didBecomeExternallyActive, !isEndingSession {
            isEndingSession = true
            let positionMs = Int64(resolvedPositionSeconds(player: player) * 1000)
            let wasPlaying = player.timeControlStatus == .playing
            player.pause()
            onExternalPlaybackEnded?(positionMs, wasPlaying)
            return
        }
        refreshInterface()
    }

    func detachPlayer() {
        unbindPlayer()
        player = nil
    }

    private func unbindPlayer() {
        if let observer = periodicTimeObserver, let player = trackedPlayer {
            player.removeTimeObserver(observer)
        }
        periodicTimeObserver = nil
        timeControlObservation = nil
        externalPlaybackObservation = nil
        itemStatusObservation = nil
        itemDurationObservation = nil
        trackedPlayer = nil
        trackedItem = nil
        didBecomeExternallyActive = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        player?.pause()
        player = nil
        unbindPlayer()
        onDismiss?()
    }

    deinit {
        unbindPlayer()
    }
}
