import AVFoundation
import VitChiaki
import Foundation

/**
 * The game's sound on the phone, for "Keep translating with the screen off": iOS keeps an app
 * running in the background, screen locked, while it plays sound, so the PS5's stream and the
 * reading go on. The PS5 sends its sound with the picture (Opus, decoded by the shim to PCM); it is
 * played here at the volume chosen in Source.
 */
final class GameAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var queued = 0
    private var started = false

    /** 0 to 1 */
    var volume: Float {
        didSet { player.volume = volume }
    }

    init(volume: Float) {
        self.volume = volume
        player.volume = volume
        engine.attach(player)
    }

    /** The app's sound starts: iOS lets it run in the background from now on. */
    func activate() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            NSLog("GameAudio: no audio session: \(error)")
        }
    }

    /** PCM from the stream (16-bit, interleaved), on chiaki's thread. */
    func play(_ pcm: UnsafePointer<Int16>, frames: Int, channels: Int, rate: Int) {
        guard frames > 0, channels > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if format == nil || format!.channelCount != AVAudioChannelCount(channels) || format!.sampleRate != Double(rate) {
            guard let f = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)) else { return }
            if started {
                player.stop()
                engine.stop()
            }
            engine.connect(player, to: engine.mainMixerNode, format: f)
            format = f
            do {
                try engine.start()
                player.play()
                started = true
            } catch {
                NSLog("GameAudio: the engine didn't start: \(error)")
                return
            }
        }
        // (behind by more than ~0.5 s: this frame is dropped, so the sound stays with the picture)
        guard queued < 25, let format, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
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
        lock.lock()
        if started {
            player.stop()
            engine.stop()
            started = false
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
