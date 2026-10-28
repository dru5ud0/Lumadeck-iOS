import Darwin
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Network

/// Remuxes an Apple-compatible video/audio pair into short MPEG-TS files and
/// exposes them as a bounded HLS playlist on the phone's Wi-Fi address. The
/// AirPlay receiver can consequently fetch a Matroska source from the phone
/// without requiring transcoding support from the upstream media server.
final class AirPlayHLSRelay {
    enum RelayError: LocalizedError {
        case noWiFiAddress
        case listenerFailed(String)
        case inputFailed(String)
        case unsupportedVideo(String)
        case unsupportedAudio(String)
        case outputFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noWiFiAddress:
                return "The phone needs a Wi-Fi address that the AirPlay receiver can reach."
            case .listenerFailed(let reason):
                return "The AirPlay relay could not start: \(reason)"
            case .inputFailed(let reason):
                return "The source could not be opened for AirPlay: \(reason)"
            case .unsupportedVideo(let codec):
                return "The source uses unsupported video codec \(codec). H.264 or HEVC is required."
            case .unsupportedAudio(let codec):
                return "The source uses unsupported audio codec \(codec). AAC, MP3, AC-3, or E-AC-3 is required."
            case .outputFailed(let reason):
                return "The AirPlay relay failed: \(reason)"
            case .cancelled:
                return "The AirPlay relay was cancelled."
            }
        }
    }

    private struct Segment {
        let number: Int
        let filename: String
        let duration: Double
    }

    private struct OutputSegment {
        let context: UnsafeMutablePointer<AVFormatContext>
        let streamMap: [Int: Int]
        let path: String
    }

    private static let targetSegmentDuration = 6.0
    private static let minimumSegmentsBeforePlayback = 3
    private static let maximumSegmentsAhead = 8
    private static let maximumSegmentsBehind = 60
    private static let ioTimeoutMicroseconds = "15000000"
    private static let noPtsValue = Int64.min
    private static let endOfFileError: Int32 = -541_478_725

    private let sourceURL: String
    private let headers: [String: String]
    private let startPositionMs: Int64
    private let token = UUID().uuidString.lowercased()
    private let rootURL: URL
    private let stateQueue = DispatchQueue(label: "airplay-hls-relay.state")
    private let networkQueue = DispatchQueue(label: "airplay-hls-relay.network")
    private let remuxQueue = DispatchQueue(label: "airplay-hls-relay.remux", qos: .userInitiated)
    private let abortFlag = AirPlayRelayAbortFlag()

    private var listener: NWListener?
    private var listenerURL: URL?
    private var segments: [Segment] = []
    private var highestRequestedSegment = -1
    private var completed = false
    private var maximumSegmentDuration = targetSegmentDuration
    private var startCompletion: ((Result<URL, Error>) -> Void)?
    private var didCompleteStart = false
    var onFailure: ((Error) -> Void)?

    init(sourceURL: String, headers: [String: String], startPositionMs: Int64) throws {
        self.sourceURL = sourceURL
        self.headers = headers
        self.startPositionMs = max(0, startPositionMs)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirPlayRelay", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        rootURL = base
    }

    deinit {
        stop()
    }

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.startCompletion == nil, !self.didCompleteStart else { return }
            self.startCompletion = completion
            self.startListener()
            self.stateQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.listenerURL == nil, !self.didCompleteStart else { return }
                self.abortFlag.set()
                self.listener?.cancel()
                self.finishStart(.failure(RelayError.listenerFailed("timed out waiting for the local server")))
            }
            self.remuxQueue.async { [weak self] in
                self?.runRemux()
            }
        }
    }

    func stop() {
        abortFlag.set()
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            if !self.didCompleteStart {
                self.finishStart(.failure(RelayError.cancelled))
            }
        }
        let directory = rootURL
        remuxQueue.async {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func startListener() {
        guard let address = Self.wiFiIPv4Address() else {
            finishStart(.failure(RelayError.noWiFiAddress))
            return
        }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                self.stateQueue.async {
                    switch state {
                    case .ready:
                        guard let port = listener?.port else {
                            self.finishStart(.failure(RelayError.listenerFailed("no listening port")))
                            return
                        }
                        self.listenerURL = URL(string: "http://\(address):\(port.rawValue)/\(self.token)/index.m3u8")
                        self.maybeFinishStart()
                    case .failed(let error):
                        self.finishStart(.failure(RelayError.listenerFailed(error.localizedDescription)))
                    default:
                        break
                    }
                }
            }
            listener.start(queue: networkQueue)
        } catch {
            finishStart(.failure(RelayError.listenerFailed(error.localizedDescription)))
        }
    }

    private func maybeFinishStart() {
        guard !didCompleteStart,
              segments.count >= Self.minimumSegmentsBeforePlayback,
              let listenerURL else { return }
        finishStart(.success(listenerURL))
    }

    private func finishStart(_ result: Result<URL, Error>) {
        guard !didCompleteStart else { return }
        didCompleteStart = true
        let completion = startCompletion
        startCompletion = nil
        DispatchQueue.main.async {
            completion?(result)
        }
    }

    // MARK: HTTP server

    private func handle(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }
            var requestData = accumulated
            if let data { requestData.append(data) }
            guard requestData.count <= 32 * 1024 else {
                self.send(status: "431 Request Header Fields Too Large", contentType: "text/plain", body: Data(), on: connection)
                return
            }
            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil || complete {
                guard let request = String(data: requestData, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                self.respond(to: request, on: connection)
            } else {
                self.receiveRequest(on: connection, accumulated: requestData)
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else {
            send(status: "400 Bad Request", contentType: "text/plain", body: Data(), on: connection)
            return
        }
        let method = String(first[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", contentType: "text/plain", body: Data(), on: connection)
            return
        }
        let rawPath = String(first[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let prefix = "/\(token)/"
        guard rawPath.hasPrefix(prefix) else {
            send(status: "404 Not Found", contentType: "text/plain", body: Data(), on: connection)
            return
        }
        let name = String(rawPath.dropFirst(prefix.count))
        if name == "index.m3u8" {
            let body = playlistData()
            send(
                status: "200 OK",
                contentType: "application/vnd.apple.mpegurl",
                body: body,
                sendBody: method != "HEAD",
                extraHeaders: ["Cache-Control": "no-store"],
                on: connection
            )
            return
        }
        guard name.range(of: #"^segment-[0-9]+\.ts$"#, options: .regularExpression) != nil else {
            send(status: "404 Not Found", contentType: "text/plain", body: Data(), on: connection)
            return
        }
        if let number = Int(name.dropFirst("segment-".count).dropLast(".ts".count)) {
            recordRequestedSegment(number)
        }
        let fileURL = rootURL.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: fileURL) else {
            send(status: "404 Not Found", contentType: "text/plain", body: Data(), on: connection)
            return
        }
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
        if method == "GET", let range = byteRange(from: rangeHeader, length: data.count) {
            let body = data.subdata(in: range)
            send(
                status: "206 Partial Content",
                contentType: "video/mp2t",
                body: body,
                extraHeaders: [
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "public, max-age=3600",
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)",
                ],
                on: connection
            )
            return
        }
        send(
            status: "200 OK",
            contentType: "video/mp2t",
            body: data,
            sendBody: method != "HEAD",
            extraHeaders: ["Accept-Ranges": "bytes", "Cache-Control": "public, max-age=3600"],
            on: connection
        )
    }

    private func byteRange(from header: String?, length: Int) -> Range<Int>? {
        guard let value = header?.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              value.lowercased().hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]), start >= 0, start < length else { return nil }
        let requestedEnd = Int(bounds[1]) ?? (length - 1)
        let end = min(max(requestedEnd, start), length - 1)
        return start..<(end + 1)
    }

    private func recordRequestedSegment(_ number: Int) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.highestRequestedSegment = max(self.highestRequestedSegment, number)
            let oldestToKeep = max(0, self.highestRequestedSegment - Self.maximumSegmentsBehind)
            let expired = self.segments.filter { $0.number < oldestToKeep }
            self.segments.removeAll { $0.number < oldestToKeep }
            for segment in expired {
                try? FileManager.default.removeItem(at: self.rootURL.appendingPathComponent(segment.filename))
            }
        }
    }

    private func playlistData() -> Data {
        let snapshot: ([Segment], Bool, Double) = stateQueue.sync {
            (segments, completed, maximumSegmentDuration)
        }
        let target = max(Int(ceil(snapshot.2)), 1)
        let sequence = snapshot.0.first?.number ?? 0
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:\(sequence)",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        for segment in snapshot.0 {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(segment.filename)
        }
        if snapshot.1 { lines.append("#EXT-X-ENDLIST") }
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func send(
        status: String,
        contentType: String,
        body: Data,
        sendBody: Bool = true,
        extraHeaders: [String: String] = [:],
        on connection: NWConnection
    ) {
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
        ]
        headers.append(contentsOf: extraHeaders.map { "\($0.key): \($0.value)" })
        headers.append("")
        headers.append("")
        var response = Data(headers.joined(separator: "\r\n").utf8)
        if sendBody { response.append(body) }
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: FFmpeg remux

    private func runRemux() {
        do {
            try remux()
            stateQueue.async { [weak self] in
                guard let self else { return }
                self.completed = true
                self.maybeFinishStart()
            }
        } catch {
            stateQueue.async { [weak self] in
                guard let self else { return }
                if !self.didCompleteStart {
                    self.finishStart(.failure(error))
                } else {
                    let wasCancelled: Bool
                    if let relayError = error as? RelayError, case .cancelled = relayError {
                        wasCancelled = true
                    } else {
                        wasCancelled = false
                    }
                    if !wasCancelled {
                        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
                    }
                }
            }
        }
    }

    private func remux() throws {
        _ = avformat_network_init()
        var inputContext = try openInput()
        defer { avformat_close_input(&inputContext) }
        guard let input = inputContext else {
            throw RelayError.inputFailed("format context unavailable")
        }
        let infoResult = avformat_find_stream_info(input, nil)
        guard infoResult >= 0 else {
            throw RelayError.inputFailed(Self.describe(infoResult))
        }

        let videoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0,
              let videoParameters = input.pointee.streams[Int(videoIndex)]?.pointee.codecpar else {
            throw RelayError.inputFailed("no video stream")
        }
        guard Self.supportedVideoCodecs.contains(videoParameters.pointee.codec_id) else {
            throw RelayError.unsupportedVideo(Self.codecName(videoParameters.pointee.codec_id))
        }

        let audioCandidate = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        var selectedInputIndexes = [Int(videoIndex)]
        if audioCandidate >= 0,
           input.pointee.nb_streams > 0 {
            let audioStreams = (0..<Int(input.pointee.nb_streams)).compactMap { index -> (Int, AVCodecID)? in
                guard let parameters = input.pointee.streams[index]?.pointee.codecpar,
                      parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { return nil }
                return (index, parameters.pointee.codec_id)
            }
            if let supported = audioStreams.first(where: { Self.supportedAudioCodecs.contains($0.1) }) {
                selectedInputIndexes.append(supported.0)
            } else if let firstAudio = audioStreams.first {
                throw RelayError.unsupportedAudio(Self.codecName(firstAudio.1))
            }
        }

        if startPositionMs > 0 {
            var target = startPositionMs * 1_000
            if input.pointee.start_time != Self.noPtsValue {
                target += input.pointee.start_time
            }
            let seekResult = avformat_seek_file(input, -1, Int64.min, target, target, AVSEEK_FLAG_BACKWARD)
            guard seekResult >= 0 else {
                throw RelayError.inputFailed("resume seek failed: \(Self.describe(seekResult))")
            }
        }

        guard let packet = av_packet_alloc() else {
            throw RelayError.outputFailed("packet allocation failed")
        }
        var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetPointer) }

        var timelineOriginUs: Int64?
        var output: OutputSegment?
        var segmentNumber = 0
        var segmentStartSeconds = 0.0
        var lastVideoSeconds = 0.0
        var started = false

        while !abortFlag.isSet {
            let readResult = av_read_frame(input, packet)
            if readResult == Self.endOfFileError { break }
            if readResult < 0 {
                if let output { closeOutput(output, writeTrailer: false) }
                output = nil
                throw RelayError.inputFailed("source read failed: \(Self.describe(readResult))")
            }
            defer { av_packet_unref(packet) }

            let inputIndex = Int(packet.pointee.stream_index)
            guard selectedInputIndexes.contains(inputIndex),
                  let inputStream = input.pointee.streams[inputIndex] else { continue }

            let isVideo = inputIndex == Int(videoIndex)
            let isKeyframe = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
            if !started {
                guard isVideo && isKeyframe else { continue }
                started = true
                segmentStartSeconds = 0
                let timestamp = packet.pointee.dts != Self.noPtsValue ? packet.pointee.dts : packet.pointee.pts
                if timestamp != Self.noPtsValue {
                    timelineOriginUs = av_rescale_q(
                        timestamp,
                        inputStream.pointee.time_base,
                        AVRational(num: 1, den: 1_000_000)
                    )
                }
                output = try createOutputSegment(
                    input: input,
                    selectedInputIndexes: selectedInputIndexes,
                    number: segmentNumber
                )
            }

            if let timelineOriginUs {
                let streamOrigin = av_rescale_q(
                    timelineOriginUs,
                    AVRational(num: 1, den: 1_000_000),
                    inputStream.pointee.time_base
                )
                if packet.pointee.pts != Self.noPtsValue { packet.pointee.pts -= streamOrigin }
                if packet.pointee.dts != Self.noPtsValue { packet.pointee.dts -= streamOrigin }
            }

            var videoSeconds: Double?
            if isVideo {
                let timestamp = packet.pointee.pts != Self.noPtsValue
                    ? packet.pointee.pts
                    : packet.pointee.dts
                if timestamp != Self.noPtsValue {
                    videoSeconds = Double(timestamp) * Double(inputStream.pointee.time_base.num)
                        / Double(inputStream.pointee.time_base.den)
                    lastVideoSeconds = max(lastVideoSeconds, videoSeconds ?? 0)
                }
            }

            if isVideo, isKeyframe, let videoSeconds,
               videoSeconds - segmentStartSeconds >= Self.targetSegmentDuration,
               let current = output {
                try finalize(current, duration: videoSeconds - segmentStartSeconds)
                segmentNumber += 1
                segmentStartSeconds = videoSeconds
                output = try createOutputSegment(
                    input: input,
                    selectedInputIndexes: selectedInputIndexes,
                    number: segmentNumber
                )
            }

            guard let current = output,
                  let outputIndex = current.streamMap[inputIndex],
                  let outputStream = current.context.pointee.streams[outputIndex] else { continue }
            av_packet_rescale_ts(packet, inputStream.pointee.time_base, outputStream.pointee.time_base)
            packet.pointee.stream_index = Int32(outputIndex)
            packet.pointee.pos = -1
            let writeResult = av_interleaved_write_frame(current.context, packet)
            guard writeResult >= 0 else {
                closeOutput(current, writeTrailer: false)
                output = nil
                throw RelayError.outputFailed("segment write failed: \(Self.describe(writeResult))")
            }
            waitForPlayerIfNeeded(afterProducing: segmentNumber)
        }

        if abortFlag.isSet {
            if let output { closeOutput(output, writeTrailer: false) }
            throw RelayError.cancelled
        }
        guard started, let finalOutput = output else {
            throw RelayError.inputFailed("no keyframe was found")
        }
        try finalize(
            finalOutput,
            duration: max(lastVideoSeconds - segmentStartSeconds, 0.1)
        )
    }

    private func openInput() throws -> UnsafeMutablePointer<AVFormatContext>? {
        guard let context = avformat_alloc_context() else {
            throw RelayError.inputFailed("format allocation failed")
        }
        context.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<AirPlayRelayAbortFlag>.fromOpaque(opaque).takeUnretainedValue().isSet ? 1 : 0
        }
        context.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(abortFlag).toOpaque()

        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        _ = av_dict_set(&options, "rw_timeout", Self.ioTimeoutMicroseconds, 0)
        _ = av_dict_set(&options, "extension_picky", "0", 0)
        _ = av_dict_set(&options, "allowed_extensions", "ALL", 0)
        var headerLines = ""
        for (name, value) in headers {
            if name.caseInsensitiveCompare("User-Agent") == .orderedSame {
                _ = av_dict_set(&options, "user_agent", value, 0)
            } else {
                headerLines += "\(name): \(value)\r\n"
            }
        }
        if !headerLines.isEmpty { _ = av_dict_set(&options, "headers", headerLines, 0) }

        var contextPointer: UnsafeMutablePointer<AVFormatContext>? = context
        let result = avformat_open_input(&contextPointer, sourceURL, nil, &options)
        guard result >= 0 else {
            throw RelayError.inputFailed(Self.describe(result))
        }
        return contextPointer
    }

    private func createOutputSegment(
        input: UnsafeMutablePointer<AVFormatContext>,
        selectedInputIndexes: [Int],
        number: Int
    ) throws -> OutputSegment {
        let filename = String(format: "segment-%05d.ts", number)
        let path = rootURL.appendingPathComponent(filename).path
        var context: UnsafeMutablePointer<AVFormatContext>?
        let allocationResult = avformat_alloc_output_context2(&context, nil, "mpegts", path)
        guard allocationResult >= 0, let output = context else {
            throw RelayError.outputFailed("MPEG-TS muxer unavailable: \(Self.describe(allocationResult))")
        }
        var streamMap: [Int: Int] = [:]
        for inputIndex in selectedInputIndexes {
            guard let inputStream = input.pointee.streams[inputIndex],
                  let outputStream = avformat_new_stream(output, nil),
                  let inputParameters = inputStream.pointee.codecpar,
                  let outputParameters = outputStream.pointee.codecpar else {
                avformat_free_context(output)
                throw RelayError.outputFailed("stream allocation failed")
            }
            let copyResult = avcodec_parameters_copy(outputParameters, inputParameters)
            guard copyResult >= 0 else {
                avformat_free_context(output)
                throw RelayError.outputFailed("codec copy failed: \(Self.describe(copyResult))")
            }
            outputParameters.pointee.codec_tag = 0
            outputStream.pointee.time_base = inputStream.pointee.time_base
            streamMap[inputIndex] = Int(outputStream.pointee.index)
        }

        let openResult = avio_open(&output.pointee.pb, path, AVIO_FLAG_WRITE)
        guard openResult >= 0 else {
            avformat_free_context(output)
            throw RelayError.outputFailed("segment open failed: \(Self.describe(openResult))")
        }
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        _ = av_dict_set(&options, "mpegts_flags", "+resend_headers", 0)
        let headerResult = avformat_write_header(output, &options)
        guard headerResult >= 0 else {
            closeOutput(OutputSegment(context: output, streamMap: streamMap, path: path), writeTrailer: false)
            throw RelayError.outputFailed("segment header failed: \(Self.describe(headerResult))")
        }
        return OutputSegment(context: output, streamMap: streamMap, path: path)
    }

    private func finalize(_ output: OutputSegment, duration: Double) throws {
        let trailerResult = av_write_trailer(output.context)
        closeOutput(output, writeTrailer: false)
        guard trailerResult >= 0 else {
            throw RelayError.outputFailed("segment trailer failed: \(Self.describe(trailerResult))")
        }
        let filename = URL(fileURLWithPath: output.path).lastPathComponent
        stateQueue.async { [weak self] in
            guard let self else { return }
            let number = Int(filename.dropFirst("segment-".count).dropLast(".ts".count)) ?? self.segments.count
            let boundedDuration = max(duration, 0.1)
            self.maximumSegmentDuration = max(self.maximumSegmentDuration, boundedDuration)
            self.segments.append(Segment(number: number, filename: filename, duration: boundedDuration))
            self.maybeFinishStart()
        }
    }

    private func waitForPlayerIfNeeded(afterProducing segmentNumber: Int) {
        while !abortFlag.isSet {
            let mayContinue = stateQueue.sync {
                let consumed = max(highestRequestedSegment, Self.minimumSegmentsBeforePlayback - 1)
                return segmentNumber - consumed < Self.maximumSegmentsAhead
            }
            if mayContinue { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func closeOutput(_ output: OutputSegment, writeTrailer: Bool) {
        if writeTrailer { _ = av_write_trailer(output.context) }
        if output.context.pointee.pb != nil { _ = avio_closep(&output.context.pointee.pb) }
        avformat_free_context(output.context)
    }

    private static let supportedVideoCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_H264,
        AV_CODEC_ID_HEVC,
    ]

    private static let supportedAudioCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_AAC,
        AV_CODEC_ID_MP3,
        AV_CODEC_ID_AC3,
        AV_CODEC_ID_EAC3,
    ]

    private static func codecName(_ codec: AVCodecID) -> String {
        guard let name = avcodec_get_name(codec) else { return "unknown" }
        return String(cString: name)
    }

    private static func describe(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        _ = av_strerror(code, &buffer, buffer.count)
        return "\(String(cString: buffer)) (\(code))"
    }

    private static func wiFiIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let socketAddress = current.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard name != "lo0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: host)
            if name == "en0" { return address }
            if fallback == nil, name.hasPrefix("en") { fallback = address }
        }
        return fallback
    }
}

private final class AirPlayRelayAbortFlag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
