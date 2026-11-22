import CoreVideo
import Foundation
import VitChiaki

/**
 * PS Remote Play from the PS5, for reading only, as the Android app's PsStream: chiaki-ng's session
 * gives the H.264 frames, VideoToolbox decodes them into GPU buffers (H264Decoder), no sound. Every
 * frame is decoded at once (so the stream never waits); about 4 a second are drawn into RGBA and
 * read (Reader, FrameConverter).
 */
final class PsStream {
    enum State { case connecting, streaming, ended, failed }

    /** told on the main thread */
    var onState: ((State, String?) -> Void)?
    /** the PS5 asks for the account's login passcode (main thread) */
    var onLoginPin: ((Bool) -> Void)?

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
        /** the session, for asking for a key frame from chiaki's thread */
        var handle: OpaquePointer?
        var lastIdr: TimeInterval = 0
        init(_ d: H264Decoder) { decoder = d }

        /** A frame couldn't be decoded: ask the PS5 for a key frame (at most once a second). */
        func needKeyFrame() {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastIdr > 1, let h = handle else { return }
            lastIdr = now
            vit_ps_session_request_idr(h)
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
    }

    /** Connect: [height] 720 or 1080. */
    func start(height: Int) {
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
                    let box = Unmanaged<PsStream.Box>.fromOpaque(user).takeUnretainedValue()
                    let ok = box.decoder.decode(UnsafeBufferPointer(start: buf, count: size))
                    if !ok { box.needKeyFrame() }
                    return ok
                }, user)
            }
        }
        guard err == 0, let h else {
            onState?(.failed, String(cString: vit_ps_error_string(err)))
            return
        }
        handle = h
        box.handle = h
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
        case Int(VIT_PS_EVENT_QUIT):
            let reason = String(cString: vit_ps_quit_reason_string(Int32(value)))
            let detail = (text?.isEmpty == false) ? text! : reason
            onState?(vit_ps_quit_reason_is_error(Int32(value)) ? .failed : .ended, detail)
        default:
            break
        }
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
            box.decoder.close()
        }
    }

    deinit {
        stop()
    }
}
