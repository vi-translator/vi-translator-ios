import CoreVideo
import Foundation
import VitChiaki

/**
 * PS Remote Play from the PS5, for reading only, as the Android app's PsStream: chiaki-ng's session
 * gives the H.264 frames, VideoToolbox decodes them into GPU buffers (H264Decoder). Every frame is
 * decoded at once (so the stream never waits); about 4 a second are drawn into RGBA and read
 * (Reader, FrameConverter).
 *
 * With "Keep translating with the screen off", the game's sound is played on the phone (GameAudio:
 * iOS keeps a playing app running), and while the app is in the background, where iOS keeps the
 * GPU and the hardware decoder from apps, the frames are decoded on the CPU (FFmpeg, in the shim).
 */
final class PsStream {
    enum State { case connecting, streaming, ended, failed }

    /** told on the main thread */
    var onState: ((State, String?) -> Void)?
    /** the PS5 asks for the account's login passcode (main thread) */
    var onLoginPin: ((Bool) -> Void)?
    /** the PS5 can't stream what it shows (true), or can again (false) (main thread) */
    var onCantDisplay: ((Bool) -> Void)?

    private let console: PsConsole
    private let reader: Reader
    private var handle: OpaquePointer?
    private let box: Box
    private let converter = FrameConverter(stretchLevels: true)

    /** frames decoded (all of them, read or not) */
    var frames: Int { box.decoder.frames }

    /** What chiaki's threads reach, through its user pointer. */
    private final class Box {
        let decoder: H264Decoder
        weak var stream: PsStream?
        weak var reader: Reader?
        /** the session, for asking for a key frame from chiaki's thread */
        var handle: OpaquePointer?
        var lastIdr: TimeInterval = 0
        /** decode on the CPU (the app is in the background) */
        var cpu = false
        var cpuDecoder: OpaquePointer?
        var audio: GameAudio?
        init(_ d: H264Decoder) { decoder = d }

        /** A frame couldn't be decoded: ask the PS5 for a key frame (at most once a second). */
        func needKeyFrame() {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastIdr > 1, let h = handle else { return }
            lastIdr = now
            vit_ps_session_request_idr(h)
        }

        /** One frame from chiaki (its video thread). */
        func video(_ buf: UnsafePointer<UInt8>, _ size: Int) -> Bool {
            if cpu {
                if cpuDecoder == nil {
                    cpuDecoder = vit_sw_decoder_new()
                    // (the CPU decoder starts at a key frame)
                    lastIdr = 0
                    needKeyFrame()
                }
                guard let d = cpuDecoder else { return true }
                if vit_sw_decode(d, buf, size) {
                    reader?.offer(CpuFrame(decoder: d))
                }
                return true
            }
            let ok = decoder.decode(UnsafeBufferPointer(start: buf, count: size))
            if !ok { needKeyFrame() }
            return ok
        }

        func close() {
            decoder.close()
            if let d = cpuDecoder {
                cpuDecoder = nil
                vit_sw_decoder_free(d)
            }
            audio?.stop()
        }
    }

    init(console: PsConsole, reader: Reader) {
        self.console = console
        self.reader = reader
        let converter = self.converter
        box = Box(H264Decoder { [weak reader] buffer in
            // (every frame to the preview, smooth; about 4 a second to the reading)
            if Prefs.preview { VideoOut.shared.show(buffer) }
            reader?.offer(PixelBufferFrame(buffer: buffer, converter: converter))
        })
        box.stream = self
        box.reader = reader
    }

    /** Connect: [height] 720 or 1080; [sound]: play the game's sound on the phone (screen off). */
    func start(height: Int, sound: Bool) {
        guard Ps5.available else {
            onState?(.failed, L("PS Remote Play isn't in this build of the app."))
            return
        }
        var h: OpaquePointer?
        let user = Unmanaged.passUnretained(box).toOpaque()
        let err: Int32 = console.registKey.withUnsafeBytes { rk in
            console.rpKey.withUnsafeBytes { mk in
                vit_ps_session_new(&h, console.host, rk.bindMemory(to: UInt8.self).baseAddress, mk.bindMemory(to: UInt8.self).baseAddress,
                                   Int32(height), 30, { type, value, text, user in
                    guard let user else { return }
                    let box = Unmanaged<PsStream.Box>.fromOpaque(user).takeUnretainedValue()
                    let words = text.map { String(cString: $0) }
                    DispatchQueue.main.async { box.stream?.event(Int(type), Int(value), words) }
                }, { buf, size, _, _, user in
                    guard let user, let buf else { return false }
                    return Unmanaged<PsStream.Box>.fromOpaque(user).takeUnretainedValue().video(buf, size)
                }, user)
            }
        }
        guard err == 0, let h else {
            onState?(.failed, String(cString: vit_ps_error_string(err)))
            return
        }
        handle = h
        box.handle = h
        if sound {
            let a = GameAudio(volume: Float(Prefs.phoneVolume))
            a.start()
            box.audio = a
            vit_ps_session_set_audio(h) { pcm, frames, channels, rate, user in
                guard let user, let pcm else { return }
                Unmanaged<PsStream.Box>.fromOpaque(user).takeUnretainedValue().audio?.play(pcm, frames: frames, channels: Int(channels), rate: Int(rate))
            }
        }
        onState?(.connecting, nil)
        let r = vit_ps_session_start(h)
        if r != 0 { onState?(.failed, String(cString: vit_ps_error_string(r))) }
    }

    private func event(_ type: Int, _ value: Int, _ text: String?) {
        switch type {
        case Int(VIT_PS_EVENT_CONNECTED):
            onState?(.streaming, nil)
        case Int(VIT_PS_EVENT_LOGIN_PIN):
            onLoginPin?(value != 0)
        case Int(VIT_PS_EVENT_CANT_DISPLAY):
            onCantDisplay?(value != 0)
        case Int(VIT_PS_EVENT_QUIT):
            let reason = String(cString: vit_ps_quit_reason_string(Int32(value)))
            let detail = (text?.isEmpty == false) ? text! : reason
            onState?(vit_ps_quit_reason_is_error(Int32(value)) ? .failed : .ended, detail)
        default:
            break
        }
    }

    /** The app left the screen (true) or came back (false): the frames are decoded on the CPU while away. */
    func background(_ away: Bool) {
        box.cpu = away
        refresh()
    }

    /** The game's sound on the phone (screen-off option): whether its player runs, and the sound frames received. Nil without it. */
    var sound: (running: Bool, received: Int)? {
        box.audio.map { ($0.running, $0.received) }
    }

    /** the game's sound's volume, 0 to 1 */
    func setVolume(_ v: Double) {
        box.audio?.volume = Float(v)
    }

    /** Back on screen: a key frame, for the decoder iOS may have dropped while away. */
    func refresh() {
        box.lastIdr = 0
        box.needKeyFrame()
    }

    func setLoginPin(_ pin: String) {
        if let h = handle { vit_ps_session_set_login_pin(h, pin) }
    }

    /** Stop (its threads end off the main thread, then it is freed). */
    func stop() {
        guard let h = handle else { return }
        handle = nil
        let box = self.box
        box.stream = nil
        box.handle = nil
        VideoOut.shared.stop()
        DispatchQueue.global(qos: .userInitiated).async {
            vit_ps_session_stop(h)
            vit_ps_session_free(h)
            box.close()
        }
    }

    deinit {
        stop()
    }
}
