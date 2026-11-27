import CoreVideo
import Foundation
import VitChiaki
import WebRTC

/** A console's stream as the app drives it (the PS5's PsStream, the Xbox's XboxStream). */
protocol GameStream: AnyObject {
    /** The app left the screen (true) or came back (false): the frames are decoded on the CPU while away. */
    func background(_ away: Bool)
    /** Back on screen: a key frame, for the decoder iOS may have dropped while away. */
    func refresh()
    /** The game's sound on the phone (screen-off option): whether its player runs, and the sound received. Nil without it. */
    var sound: (running: Bool, received: Int)? { get }
    func setVolume(_ v: Double)
    func stop()
}

extension PsStream: GameStream {}

/**
 * Xbox Remote Play, for reading only, without Microsoft's web player (as the Android app's
 * XboxStream): the app asks Xbox's servers for a session with the console chosen in Setup, then
 * receives its picture over WebRTC. No controller: the player's own stays on the console.
 *
 * The steps are those of xbox.com's player (see the open-source XStreaming and Greenlight): start
 * the session, wait for the console, swap the WebRTC offer and answer and the network candidates
 * through the servers, then the data channels' greetings (message, control, input) and a keep-alive.
 *
 * The picture takes the PS5's path: WebRTC hands each H.264 frame to the app's own decoder
 * (XboxDecoder), which is the PS5's (VideoToolbox into GPU buffers, FrameConverter, the Reader), and,
 * while the app is in the background with the screen-off option, FFmpeg on the CPU (iOS keeps the
 * GPU and the hardware decoder from apps in the background). The sound plays only with that option
 * (XboxAudio), which is what keeps iOS from pausing the app.
 */
final class XboxStream: NSObject, GameStream, @unchecked Sendable {
    enum State { case connecting, streaming, ended, failed }

    /** told on the main thread */
    var onState: ((State, String?) -> Void)?

    private let console: XboxConsole
    private let resolution: Int
    private let video: XboxVideo
    private let audio: XboxAudio
    private let q = DispatchQueue(label: "xbox-stream")
    private let lock = NSLock()
    private var stopped = false
    private var task: Task<Void, Never>?
    private var home: XboxHome?
    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var channels: [String: RTCDataChannel] = [:]
    private var timers: [DispatchSourceTimer] = []
    private var localCandidates: [RTCIceCandidate] = []
    private var gathered = false
    private var greeted = false
    private var cv = 0
    private var inputSeq: UInt32 = 0
    private let started = ProcessInfo.processInfo.systemUptime
    private var framesAtCheck = 0

    /** frames decoded (all of them, read or not) */
    var frames: Int { video.frames }

    init(console: XboxConsole, resolution: Int, reader: Reader, sound: Bool) {
        self.console = console
        self.resolution = resolution
        video = XboxVideo(reader: reader)
        audio = XboxAudio(plays: sound, volume: Float(Prefs.phoneVolume))
        super.init()
        video.firstFrame = { [weak self] in
            DispatchQueue.main.async { self?.onState?(.streaming, nil) }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /** (main thread) */
    func start() {
        onState?(.connecting, nil)
        audio.prime()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.connect()
            } catch {
                if !(error is CancellationError) {
                    NSLog("XboxStream: \(error)")
                    self.fail(self.describe(error))
                }
            }
        }
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        task?.cancel()
        VideoOut.shared.stop()
        q.async { [self] in
            for t in timers { t.cancel() }
            timers = []
            let chans = Array(channels.values)
            channels = [:]
            let (pc, factory, home, audio, video) = (self.pc, self.factory, self.home, self.audio, self.video)
            self.pc = nil
            Task.detached {
                await home?.stop()
                for c in chans { c.close() }
                pc?.close()
                _ = factory
                _ = audio.terminateDevice()
                video.close()
            }
        }
    }

    // ---- GameStream

    func background(_ away: Bool) {
        video.cpu = away
        refresh()
    }

    func refresh() {
        q.async { self.keyframe() }
    }

    var sound: (running: Bool, received: Int)? {
        audio.plays ? (audio.running, audio.received) : nil
    }

    func setVolume(_ v: Double) {
        audio.volume = Float(v)
    }

    // ---- the session

    private func connect() async throws {
        let login = try await XboxAuth.streaming()
        let h = XboxHome(login, resolution: resolution)
        q.sync { home = h }
        // the console's state now (and the region that has it): asleep, it's woken first
        guard let now = try await h.consoles().first(where: { $0.serverId == console.serverId }) else {
            throw XboxFailure(L("This Xbox isn't on your Microsoft account's list any more. Choose it again in Setup."))
        }
        if now.asleep { try await wake(h) }
        try Task.checkCancellation()

        try await h.play(console.serverId)
        try await waitReady(h)
        let keepAlive = await h.keepAliveSeconds()

        let offer = try await makePeer()
        let answer = try await h.exchangeSdp(offer)
        guard let pc = q.sync(execute: { self.pc }) else { throw CancellationError() }
        try await Self.set(pc, remote: RTCSessionDescription(type: .answer, sdp: answer))
        // (this phone's candidates: all of them, gathered within 5 s)
        let until = Date().addingTimeInterval(5)
        while Date() < until, !q.sync(execute: { gathered }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let mine = q.sync { localCandidates }
            .filter { !XboxHome.skip($0.sdp) }
            .map { c -> IceLine in
                var s = c.sdp
                if s.hasPrefix("a=") { s.removeFirst(2) }
                return IceLine(candidate: s, mid: c.sdpMid ?? "0", index: Int(c.sdpMLineIndex))
            }
        let theirs = XboxHome.withTeredo(try await h.exchangeIce(mine))
        for t in theirs where !XboxHome.skip(t.candidate) {
            var s = t.candidate
            if s.hasPrefix("a=") { s.removeFirst(2) }
            pc.add(RTCIceCandidate(sdp: s, sdpMLineIndex: Int32(t.index), sdpMid: t.mid)) { error in
                if let error { NSLog("XboxStream: candidate refused: \(s) (\(error))") }
            }
        }
        try Task.checkCancellation()

        q.async { [self] in
            every(Double(keepAlive), first: Double(keepAlive)) {
                Task { do { try await h.keepAlive() } catch { NSLog("XboxStream: keep-alive: \(error)") } }
            }
            // no picture within 30 s of connecting: tell the user rather than wait for ever
            q.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, !self.isStopped, self.video.frames == 0 else { return }
                self.fail(L("The Xbox sent no picture. Check that Remote Play works on this network, then try again."))
            }
        }
    }

    private func wake(_ h: XboxHome) async throws {
        do {
            try await XboxAuth.wake(console.serverId)
        } catch {
            NSLog("XboxStream: wake: \(error)")
        }
        // (up to 45 s for it to come on)
        let until = Date().addingTimeInterval(45)
        while Date() < until {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if let c = try? await h.consoles().first(where: { $0.serverId == console.serverId }), !c.asleep { return }
        }
    }

    private func waitReady(_ h: XboxHome) async throws {
        var connected = false
        let until = Date().addingTimeInterval(90)
        while Date() < until {
            try Task.checkCancellation()
            let (state, error) = try await h.state()
            switch state {
            case "Provisioned": return
            case "ReadyToConnect":
                if !connected {
                    try await h.connect(try await XboxAuth.transferToken())
                    connected = true
                }
            case "Failed": throw XboxFailure(failure(error))
            default: break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw XboxFailure(L("The Xbox didn't get ready to stream. Check that it's on or asleep (not off), then try again."))
    }

    /** What the console's error means for the user. */
    private func failure(_ error: String?) -> String {
        guard let e = error else { return L("The Xbox refused the stream.") }
        let low = e.lowercased()
        if low.contains("disabled streaming") { return L("Remote features are off on the Xbox: Settings › Devices & connections › Remote features.") }
        if low.contains("waitingforservertoregister") { return L("The Xbox isn't connected to Xbox services. Restart the Xbox (hold its power button for 10 s), then try again.") }
        if low.contains("xboxstreaminghelper") { return L("The Xbox's streaming stopped working. Restart the Xbox (hold its power button for 10 s), then try again.") }
        return L("The Xbox refused the stream.") + " (\(e))"
    }

    private func describe(_ e: Error) -> String {
        if e is XboxAuth.SignedOut { return L("Signed out of Microsoft. Sign in again in Setup.") }
        if let h = e as? HttpError, h.code == 401 || h.code == 403 { return L("Microsoft refused the sign-in for Remote Play. Sign in again in Setup.") }
        return e.localizedDescription
    }

    // ---- WebRTC

    private static let setUp: Void = { RTCInitializeSSL() }()

    private static let stun = ["stun:worldaz.relay.teams.microsoft.com:3478", "stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]

    /** The peer, its channels and its offer (set as the local description). */
    private func makePeer() async throws -> String {
        _ = Self.setUp
        let f = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: XboxDecoderFactory(video: video), audioDevice: audio)
        let cfg = RTCConfiguration()
        cfg.iceServers = [RTCIceServer(urlStrings: Self.stun)]
        cfg.sdpSemantics = .unifiedPlan
        cfg.continualGatheringPolicy = .gatherOnce
        guard let p = f.peerConnection(with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw XboxFailure("WebRTC: no peer connection")
        }
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        p.addTransceiver(of: .video, init: videoInit)
        // (sendrecv as xbox.com's player, whose chat uses this line; nothing is sent: no microphone track)
        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .sendRecv
        p.addTransceiver(of: .audio, init: audioInit)

        q.sync {
            factory = f
            pc = p
            channel(p, "input", "1.0", ordered: true)
            channel(p, "chat", "chatV1", ordered: false)
            channel(p, "control", "controlV1", ordered: false)
            channel(p, "message", "messageV1", ordered: false)
        }
        // (stopped meanwhile: stop() may have closed the peer before it was here)
        if isStopped {
            p.close()
            throw CancellationError()
        }

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            p.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? XboxFailure("WebRTC: no offer")) }
            }
        }
        // (the console's sound in stereo, as the web player asks)
        let sdp = offer.sdp.replacingOccurrences(of: "useinbandfec=1", with: "useinbandfec=1;stereo=1")
        try await Self.set(p, local: RTCSessionDescription(type: .offer, sdp: sdp))
        return sdp
    }

    private static func set(_ p: RTCPeerConnection, local: RTCSessionDescription? = nil, remote: RTCSessionDescription? = nil) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let done: (Error?) -> Void = { error in
                if let error { c.resume(throwing: XboxFailure("WebRTC: \(error.localizedDescription)")) } else { c.resume() }
            }
            if let local { p.setLocalDescription(local, completionHandler: done) } else if let remote { p.setRemoteDescription(remote, completionHandler: done) }
        }
    }

    /** (on q) */
    private func channel(_ p: RTCPeerConnection, _ label: String, _ proto: String, ordered: Bool) {
        let c = RTCDataChannelConfiguration()
        c.isOrdered = ordered
        c.`protocol` = proto
        guard let dc = p.dataChannel(forLabel: label, configuration: c) else { return }
        dc.delegate = self
        channels[label] = dc
    }

    /** (on q) */
    private func opened(_ label: String) {
        guard !isStopped else { return }
        switch label {
        case "message":
            sendText("message", ["type": "Handshake", "version": "messageV1", "id": uuid(), "cv": nextCv()])
        case "input":
            // (who this client is: no touch screen)
            sendInput(XboxInput.clientMetadata(seq: nextSeq(), ms: elapsedMs()))
        default:
            break
        }
    }

    /** (on q) The console's messages: after its HandshakeAck, the greetings that start the picture. */
    private func message(_ text: String) {
        guard !isStopped, !greeted,
              let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              o["type"] as? String == "HandshakeAck" else { return }
        greeted = true
        // control: allowed in, and a controller slot (as the web player does; the real controller stays on the console)
        sendText("control", ["message": "authorizationRequest", "accessKey": "4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E"])
        sendText("control", ["message": "gamepadChanged", "gamepadIndex": 0, "wasAdded": false])
        q.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendText("control", ["message": "gamepadChanged", "gamepadIndex": 0, "wasAdded": true])
        }
        for (target, content) in XboxInput.greetings(installId: uuid()) {
            sendText("message", ["type": "Message", "content": XboxHttp.json(content), "id": uuid(), "target": target, "cv": nextCv()])
        }
        keyframe()
        // every 10 s: the input channel's sign of life, and a whole picture again if none came
        every(10, first: 2) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.sendInput(XboxInput.metadata(seq: self.nextSeq(), ms: self.elapsedMs(), epochMs: UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))))
            let n = self.video.frames
            if n == self.framesAtCheck { self.keyframe() }
            self.framesAtCheck = n
        }
    }

    /** (on q) */
    private func keyframe() {
        sendText("control", ["message": "videoKeyframeRequested", "ifrRequested": true])
    }

    /** (on q) a timer on q */
    private func every(_ seconds: Double, first: Double, _ run: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + first, repeating: seconds)
        t.setEventHandler(handler: run)
        t.resume()
        timers.append(t)
    }

    private func sendText(_ label: String, _ o: [String: Any]) {
        guard let dc = channels[label], dc.readyState == .open else { return }
        dc.sendData(RTCDataBuffer(data: Data(XboxHttp.json(o).utf8), isBinary: false))
    }

    private func sendInput(_ b: Data) {
        guard let dc = channels["input"], dc.readyState == .open else { return }
        dc.sendData(RTCDataBuffer(data: b, isBinary: true))
    }

    private func nextCv() -> String {
        cv += 1
        return String(cv)
    }

    private func nextSeq() -> UInt32 {
        defer { inputSeq &+= 1 }
        return inputSeq
    }

    private func elapsedMs() -> Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }

    private func uuid() -> String { UUID().uuidString.lowercased() }

    // ---- the end

    private func fail(_ detail: String) {
        guard !isStopped else { return }
        DispatchQueue.main.async { self.onState?(.failed, detail) }
        stop()
    }

    private func end(_ detail: String?) {
        guard !isStopped else { return }
        DispatchQueue.main.async { self.onState?(.ended, detail) }
        stop()
    }
}

extension XboxStream: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { q.async { self.gathered = true } }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        q.async { self.localCandidates.append(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .failed:
            fail(L("Couldn't reach the Xbox over the network (Remote Play needs the router to allow it: UPnP, or the Xbox's ports open)."))
        case .closed:
            end(L("The Xbox ended the stream."))
        default:
            break
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        let label = dataChannel.label
        q.async { self.opened(label) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel.label == "message", !buffer.isBinary else { return }
        let text = String(decoding: buffer.data, as: UTF8.self)
        q.async { self.message(text) }
    }
}

// ---- the picture

/** What the stream's decoders share: where frames go, CPU or GPU, and the count. */
final class XboxVideo: @unchecked Sendable {
    weak var reader: Reader?
    let converter = FrameConverter(stretchLevels: true)
    /** decode on the CPU (the app is in the background) */
    var cpu = false
    var firstFrame: (() -> Void)?
    private let lock = NSLock()
    private var count = 0
    private var decoders: [XboxDecoder] = []

    var frames: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    init(reader: Reader) {
        self.reader = reader
    }

    func decoded() {
        lock.lock()
        count += 1
        let first = count == 1
        lock.unlock()
        if first { firstFrame?() }
    }

    func add(_ d: XboxDecoder) {
        lock.lock()
        decoders.append(d)
        lock.unlock()
    }

    func close() {
        lock.lock()
        let ds = decoders
        decoders = []
        lock.unlock()
        for d in ds { _ = d.releaseDecoder() }
    }
}

/** WebRTC's video decoders for the Xbox: H.264 only (the console sends nothing else), High and Main first. */
final class XboxDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let video: XboxVideo

    init(video: XboxVideo) {
        self.video = video
    }

    static func h264(_ profile: String) -> RTCVideoCodecInfo {
        RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": profile, "level-asymmetry-allowed": "1", "packetization-mode": "1"])
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        // (High, Main, Constrained Baseline: the order xbox.com's player prefers; the app's decoder takes all)
        [Self.h264("640c1f"), Self.h264("4d001f"), Self.h264("42e01f")]
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        guard info.name.caseInsensitiveCompare("H264") == .orderedSame else { return nil }
        let d = XboxDecoder(video: video)
        video.add(d)
        return d
    }
}

/**
 * One H.264 decoder, given each frame by WebRTC (Annex B, as chiaki-ng gives the PS5's): the PS5's
 * H264Decoder on screen, FFmpeg (the shim's) on the CPU while away. A frame that can't be decoded is
 * reported to WebRTC, which then asks the console for a key frame.
 */
final class XboxDecoder: NSObject, RTCVideoDecoder, @unchecked Sendable {
    private let video: XboxVideo
    private var gpu: H264Decoder?
    private var cpuDecoder: OpaquePointer?
    private var callback: RTCVideoDecoderCallback?
    private var rtp: UInt32 = 0
    private var renderMs: Int64 = 0
    private let lock = NSLock()

    init(video: XboxVideo) {
        self.video = video
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback = callback
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        makeGpu()
        return 0
    }

    /** (with the lock) */
    private func makeGpu() {
        guard gpu == nil else { return }
        let video = self.video
        gpu = H264Decoder { [weak self] buffer in
            if Prefs.preview { VideoOut.shared.show(buffer) }
            video.reader?.offer(PixelBufferFrame(buffer: buffer, converter: video.converter))
            video.decoded()
            // (to WebRTC too, as its own decoder would: nothing draws it)
            guard let self, let cb = self.callback else { return }
            let f = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: self.renderMs * 1_000_000)
            f.timeStamp = Int32(bitPattern: self.rtp)
            cb(f)
        }
    }

    func releaseDecoder() -> Int {
        lock.lock()
        defer { lock.unlock() }
        gpu?.close()
        gpu = nil
        if let d = cpuDecoder {
            cpuDecoder = nil
            vit_sw_decoder_free(d)
        }
        return 0
    }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: RTCCodecSpecificInfo?, renderTimeMs: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let data = encodedImage.buffer
        guard !data.isEmpty else { return 0 }
        rtp = encodedImage.timeStamp
        renderMs = renderTimeMs
        let ok: Bool = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let p = raw.bindMemory(to: UInt8.self)
            guard let base = p.baseAddress else { return true }
            if video.cpu {
                if cpuDecoder == nil { cpuDecoder = vit_sw_decoder_new() }
                guard let d = cpuDecoder else { return true }
                if vit_sw_decode(d, base, p.count) {
                    video.reader?.offer(CpuFrame(decoder: d))
                    video.decoded()
                    return true
                }
                // (no picture yet: the CPU decoder starts at a key frame)
                return false
            }
            makeGpu()
            return gpu?.decode(p) ?? false
        }
        // (WEBRTC_VIDEO_CODEC_OK, WEBRTC_VIDEO_CODEC_ERROR: WebRTC then asks for a key frame)
        return ok ? 0 : -1
    }

    func implementationName() -> String { "VideoToolbox/FFmpeg (VI Translator)" }
}
