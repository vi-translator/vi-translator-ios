import Foundation
import VitChiaki

/** The PS5 this phone is registered with (Remote Play's keys for it), kept across runs. */
struct PsConsole: Codable, Equatable {
    var host: String
    var nickname: String
    var mac: Data
    var registKey: Data
    var rpKey: Data

    /** The number the PS5 wakes up for (its registration key, written in hex). */
    var credential: UInt64? {
        let bytes = registKey.prefix { $0 != 0 }
        guard let s = String(data: bytes, encoding: .utf8) else { return nil }
        return UInt64(s, radix: 16)
    }

    var name: String { nickname.isEmpty ? "PS5" : nickname }
}

/** A PlayStation found on the home network. */
struct PsHost: Identifiable, Equatable {
    var id: String { addr }
    let addr: String
    let name: String
    let standby: Bool
    let ps5: Bool
}

enum Ps5 {
    private static let d = UserDefaults.standard

    /** chiaki-ng's library, started once (its log in the app's caches). */
    static let available: Bool = {
        let log = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("chiaki.log").path
        return vit_ps_init(log) == 0
    }()

    static var saved: PsConsole? {
        get {
            guard let data = d.data(forKey: "ps5.console") else { return nil }
            return try? JSONDecoder().decode(PsConsole.self, from: data)
        }
        set {
            if let c = newValue, let data = try? JSONEncoder().encode(c) {
                d.set(data, forKey: "ps5.console")
            } else {
                d.removeObject(forKey: "ps5.console")
            }
        }
    }

    /** The PSN account ID from the sign-in (base64 of 8 bytes), kept for registering again. */
    static var accountId: String {
        get { d.string(forKey: "ps5.account_id") ?? "" }
        set { d.set(newValue, forKey: "ps5.account_id") }
    }

    /** the address chosen (a console found, or typed), and its name */
    static var address: String {
        get { d.string(forKey: "ps5.address") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "ps5.address") }
    }

    static var addressName: String {
        get { d.string(forKey: "ps5.name") ?? "" }
        set { d.set(newValue, forKey: "ps5.name") }
    }

    /** Wake a PS5 in rest mode. */
    static func wakeup(_ c: PsConsole) {
        guard let cred = c.credential else { return }
        DispatchQueue.global().async { _ = vit_ps_wakeup(c.host, cred) }
    }

    static func validAddress(_ a: String) -> Bool {
        let parts = a.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in p.count >= 1 && p.count <= 3 && p.allSatisfy(\.isASCII) && Int(p).map { $0 <= 255 } == true }
    }

    /** a PSN account ID: 8 bytes in base64 (12 characters) */
    static func validAccount(_ a: String) -> Bool {
        Data(base64Encoded: a.trimmingCharacters(in: .whitespaces))?.count == 8
    }
}

/** Looks for PlayStations on the home network while it lives; [found] gets the PS5s, on the main thread. */
final class PsDiscovery {
    private var handle: OpaquePointer?
    private let box: Box

    private final class Box {
        let found: ([PsHost]) -> Void
        init(_ f: @escaping ([PsHost]) -> Void) { found = f }
    }

    init?(found: @escaping ([PsHost]) -> Void) {
        guard Ps5.available else { return nil }
        box = Box(found)
        let own = LocalNet.ownIPv4()
        let user = Unmanaged.passUnretained(box).toOpaque()
        var h: OpaquePointer?
        let err = vit_ps_discovery_new(&h, own, { hosts, count, user in
            guard let user else { return }
            let box = Unmanaged<PsDiscovery.Box>.fromOpaque(user).takeUnretainedValue()
            var list: [PsHost] = []
            for i in 0..<count {
                guard let h = hosts?[i] else { continue }
                let addr = withUnsafeBytes(of: h.addr) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                let name = withUnsafeBytes(of: h.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if h.ps5, !addr.isEmpty { list.append(PsHost(addr: addr, name: name.isEmpty ? "PS5" : name, standby: h.state == 2, ps5: h.ps5)) }
            }
            DispatchQueue.main.async { box.found(list) }
        }, user)
        guard err == 0, let h else {
            NSLog("PS5 discovery failed: \(String(cString: vit_ps_error_string(err)))")
            return nil
        }
        handle = h
    }

    func stop() {
        if let h = handle {
            handle = nil
            vit_ps_discovery_free(h)
        }
    }

    deinit {
        stop()
    }
}

/**
 * Registering with the PS5 at [host], with the PSN account ID (base64) and the 8-digit PIN the PS5
 * shows (Settings › System › Remote Play › Link Device). [done] gets the console, or nil, on the main thread.
 */
final class PsRegist {
    private var handle: OpaquePointer?
    private let box: Box

    private final class Box {
        let host: String
        let done: (PsConsole?) -> Void
        init(_ h: String, _ d: @escaping (PsConsole?) -> Void) {
            host = h
            done = d
        }
    }

    init?(host: String, accountIdB64: String, pin: UInt32, done: @escaping (PsConsole?) -> Void) {
        guard Ps5.available, let id = Data(base64Encoded: accountIdB64.trimmingCharacters(in: .whitespaces)), id.count == 8 else { return nil }
        box = Box(host, done)
        let user = Unmanaged.passUnretained(box).toOpaque()
        var h: OpaquePointer?
        let err: Int32 = id.withUnsafeBytes { idp in
            vit_ps_regist_start(&h, host, idp.bindMemory(to: UInt8.self).baseAddress, pin, { result, reg, user in
                guard let user else { return }
                let box = Unmanaged<PsRegist.Box>.fromOpaque(user).takeUnretainedValue()
                var console: PsConsole?
                if result == Int32(VIT_PS_REGIST_OK), let r = reg?.pointee {
                    let nick = withUnsafeBytes(of: r.nickname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                    console = PsConsole(host: box.host, nickname: nick,
                                        mac: withUnsafeBytes(of: r.mac) { Data($0) },
                                        registKey: withUnsafeBytes(of: r.regist_key) { Data($0) },
                                        rpKey: withUnsafeBytes(of: r.rp_key) { Data($0) })
                }
                DispatchQueue.main.async { box.done(console) }
            }, user)
        }
        guard err == 0, let h else { return nil }
        handle = h
    }

    func stop() {
        if let h = handle {
            handle = nil
            // (not on chiaki's own thread: it joins it)
            DispatchQueue.global().async { [box] in
                _ = box
                vit_ps_regist_free(h)
            }
        }
    }

    deinit {
        stop()
    }
}
