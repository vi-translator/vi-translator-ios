import AVFoundation
import Foundation
import WebRTC

/**
 * WebRTC's sound device for the Xbox stream: it only plays, never records (WebRTC's own device on
 * iOS opens the microphone, which this app neither needs nor asks for).
 *
 * With "Keep translating with the screen off" ([plays]), the Xbox's sound is played on the phone at
 * the volume chosen in Source: as for the PS5 (GameAudio), iOS keeps an app that plays sound running
 * in the background, screen locked, so the stream and the reading go on. Without it, nothing is
 * played and the audio session isn't touched (WebRTC then simply drops the console's sound).
 */
final class XboxAudio: NSObject, RTCAudioDevice, @unchecked Sendable {
    let plays: Bool
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var delegate: RTCAudioDeviceDelegate?
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    /** 16-bit interleaved samples from WebRTC, before they become the engine's floats */
    private let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: XboxAudio.maxFrames * 2)
    private static let maxFrames = 8192
    private static let rate = 48000.0
    private static let channels = 2

    /** sound buffers that weren't silent (for the screen: is there any sound at all) */
    private(set) var received = 0
    var running: Bool { engine.isRunning }

    /** 0 to 1 */
    var volume: Float {
        didSet { node?.volume = volume }
    }

    private var primed = false
    private var initialized = false
    private var playoutReady = false
    private var playing = false
    private var recordingReady = false
    private var recording = false

    init(plays: Bool, volume: Float) {
        self.plays = plays
        self.volume = volume
        super.init()
    }

    deinit {
        scratch.deallocate()
    }

    // ---- what WebRTC asks of a device

    var deviceInputSampleRate: Double { Self.rate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.rate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { Self.channels }
    var outputLatency: TimeInterval { 0 }
    var isInitialized: Bool { initialized }
    var isPlayoutInitialized: Bool { playoutReady }
    var isPlaying: Bool { playing }
    var isRecordingInitialized: Bool { recordingReady }
    var isRecording: Bool { recording }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.lock()
        self.delegate = delegate
        lock.unlock()
        initialized = true
        return true
    }

    // (Swift's name for -terminateDevice)
    @objc(terminateDevice)
    func terminate() -> Bool {
        playing = false
        if plays { DispatchQueue.main.async { self.stopEngine() } }
        lock.lock()
        delegate = nil
        lock.unlock()
        initialized = false
        return true
    }

    func initializePlayout() -> Bool {
        playoutReady = true
        return true
    }

    func startPlayout() -> Bool {
        playing = true
        if plays { DispatchQueue.main.async { self.startEngine() } }
        return true
    }

    func stopPlayout() -> Bool {
        // (the player keeps running, silent, until the stream ends: it is what keeps the app running)
        playing = false
        return true
    }

    /**
     * (main thread) The player started at once, when the stream starts, silent until the console's
     * sound comes: the app is kept running from the start, as the PS5's GameAudio does.
     */
    func prime() {
        guard plays else { return }
        primed = true
        startEngine()
    }

    // (nothing is recorded: the console gets no sound from the phone)
    func initializeRecording() -> Bool {
        recordingReady = true
        return true
    }

    func startRecording() -> Bool {
        recording = true
        return true
    }

    func stopRecording() -> Bool {
        recording = false
        return true
    }

    // ---- the player

    /** (main thread) The audio session and the engine, pulling the console's sound from WebRTC. */
    private func startEngine() {
        guard primed || playing, !engine.isRunning else { return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            NSLog("XboxAudio: no audio session: \(error)")
        }
        if node == nil {
            guard let f = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: AVAudioChannelCount(Self.channels)) else { return }
            let n = AVAudioSourceNode(format: f) { [weak self] silence, timestamp, frameCount, abl in
                self?.render(silence, timestamp, frameCount, abl) ?? noErr
            }
            n.volume = volume
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: f)
            node = n
        }
        do {
            try engine.start()
        } catch {
            NSLog("XboxAudio: the player didn't start: \(error)")
        }
        if observers.isEmpty {
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                if type == .ended { self?.restart() }
            })
            observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.restart()
            })
        }
    }

    /** (after an interruption or a change of speaker) */
    private func restart() {
        guard primed || playing else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if engine.isRunning { engine.stop() }
        startEngine()
    }

    private func stopEngine() {
        primed = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if engine.isRunning {
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /** (the engine's audio thread) WebRTC's 16-bit sound into the engine's float channels. */
    private func render(_ silence: UnsafeMutablePointer<ObjCBool>, _ timestamp: UnsafePointer<AudioTimeStamp>,
                        _ frameCount: AVAudioFrameCount, _ abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let out = UnsafeMutableAudioBufferListPointer(abl)
        let n = Int(frameCount)
        lock.lock()
        let get = playing ? delegate?.getPlayoutData : nil
        lock.unlock()
        guard let get, n <= Self.maxFrames else {
            for b in out { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            silence.pointee = true
            return noErr
        }
        let ch = Self.channels
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(n * ch * 2), mData: scratch))
        var flags = AudioUnitRenderActionFlags()
        let st = get(&flags, timestamp, 0, frameCount, &list)
        if st != noErr { memset(scratch, 0, n * ch * 2) }
        var loud = false
        for (c, b) in out.enumerated() {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let src = min(c, ch - 1)
            for i in 0..<n {
                let v = scratch[i * ch + src]
                if v != 0 { loud = true }
                d[i] = Float(v) / 32768
            }
        }
        if loud { received += 1 }
        return noErr
    }
}
