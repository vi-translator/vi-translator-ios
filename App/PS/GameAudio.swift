import AVFoundation
import Foundation
import VitChiaki

/**
 * The game's sound on the phone, for "Keep translating with the screen off": iOS keeps an app
 * running in the background, screen locked, while it plays sound, so the PS5's stream and the
 * reading go on. The player starts as soon as translating starts (before the PS5 sends any sound,
 * so the app is kept running either way) and starts again after an interruption (a call, Siri,
 * headphones unplugged). The PS5 sends its sound with the picture (Opus, decoded by the shim to
 * PCM); it is played here at the volume chosen in Source.
 */
final class GameAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var queued = 0
    private var observers: [NSObjectProtocol] = []

    /** sound frames received from the PS5 (for the screen: is there any sound at all) */
    private(set) var received = 0
    /** the player runs (iOS keeps the app running) */
    var running: Bool { engine.isRunning }

    /** 0 to 1 */
    var volume: Float {
        didSet { player.volume = volume }
    }

    init(volume: Float) {
        self.volume = volume
        player.volume = volume
        engine.attach(player)
    }

    /** Start now (main thread): the audio session, and the player at the PS5's usual 48 kHz stereo. */
    func start() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            NSLog("GameAudio: no audio session: \(error)")
        }
        lock.lock()
        connect(rate: 48000, channels: 2)
        lock.unlock()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { self?.restart() }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        })
    }

    /** (after an interruption or a change of speaker) */
    private func restart() {
        try? AVAudioSession.sharedInstance().setActive(true)
        lock.lock()
        if let f = format {
            format = nil
            connect(rate: f.sampleRate, channels: f.channelCount)
        }
        lock.unlock()
    }

    /** (with the lock) */
    private func connect(rate: Double, channels: AVAudioChannelCount) {
        guard let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else { return }
        if engine.isRunning {
            player.stop()
            engine.stop()
        }
        engine.connect(player, to: engine.mainMixerNode, format: f)
        format = f
        queued = 0
        do {
            try engine.start()
            player.play()
        } catch {
            NSLog("GameAudio: the player didn't start: \(error)")
        }
    }

    /** PCM from the stream (16-bit, interleaved), on chiaki's thread. */
    func play(_ pcm: UnsafePointer<Int16>, frames: Int, channels: Int, rate: Int) {
        guard frames > 0, channels > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        received += 1
        if format == nil || format!.channelCount != AVAudioChannelCount(channels) || format!.sampleRate != Double(rate) {
            connect(rate: Double(rate), channels: AVAudioChannelCount(channels))
        }
        // (behind by more than ~0.5 s: this frame is dropped, so the sound stays with the picture)
        guard engine.isRunning, queued < 25, let format, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<channels {
            let dst = out[ch]
            var i = 0
            while i < frames {
                dst[i] = Float(pcm[i * channels + ch]) / 32768
                i += 1
            }
        }
        queued += 1
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queued -= 1
            self.lock.unlock()
        }
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        lock.lock()
        if engine.isRunning {
            player.stop()
            engine.stop()
        }
        format = nil
        queued = 0
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/** A picture the CPU decoder (FFmpeg) made: copied into RGBA at once (its buffer is reused for the next frame). */
struct CpuFrame: Frame {
    let decoder: OpaquePointer

    func snapshot() throws -> Snapshot {
        var w: Int32 = 0, h: Int32 = 0
        vit_sw_frame_size(decoder, &w, &h)
        guard w > 0, h > 0 else { throw CoreFailure("no picture") }
        var data = Data(count: Int(w) * Int(h) * 4)
        let ok = data.withUnsafeMutableBytes { p in
            vit_sw_frame_rgba(decoder, p.bindMemory(to: UInt8.self).baseAddress, p.count, true)
        }
        guard ok else { throw CoreFailure("the picture couldn't be copied") }
        return DataSnapshot(width: Int(w), height: Int(h), data: data)
    }
}

private struct DataSnapshot: Snapshot {
    let width: Int
    let height: Int
    let data: Data

    func rgba() throws -> Data { data }
}
