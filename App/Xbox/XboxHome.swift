import Foundation

/** An Xbox the account can stream from. */
struct XboxConsole: Equatable {
    let serverId: String
    let name: String
    let type: String
    let powerState: String

    var asleep: Bool { ["connectedstandby", "off"].contains(powerState.lowercased()) }
    var title: String { name.isEmpty ? serverId : name }

    private static let d = UserDefaults.standard

    /** The console chosen in Setup (kept with the sign-in; signing out forgets it). */
    static var saved: XboxConsole? {
        get {
            guard let id = d.string(forKey: "xbox_console_id") else { return nil }
            return XboxConsole(serverId: id, name: d.string(forKey: "xbox_console_name") ?? "", type: d.string(forKey: "xbox_console_type") ?? "", powerState: "")
        }
        set {
            d.set(newValue?.serverId, forKey: "xbox_console_id")
            d.set(newValue?.name, forKey: "xbox_console_name")
            d.set(newValue?.type, forKey: "xbox_console_type")
        }
    }
}

/** One network candidate: its line, its media id and line index. */
struct IceLine: Equatable {
    let candidate: String
    let mid: String
    let index: Int
}

/**
 * Xbox Remote Play's web API ("xHome" on Microsoft's gssv servers), as xbox.com's player uses it and
 * as the Android app's XboxHome: the consoles, and a session's steps (start, wait for the console,
 * the WebRTC offer and network candidates, keep-alive, stop).
 */
final class XboxHome: @unchecked Sendable {
    /** Remote Play's token and its regions' addresses (the default first). */
    struct Login {
        let gsToken: String
        let baseUris: [String]
    }

    private let login: Login
    private let resolution: Int

    /** The region whose console list wasn't empty (else the default). */
    private(set) var baseUri: String
    private var sessionPath: String?

    init(_ login: Login, resolution: Int) {
        self.login = login
        self.resolution = resolution
        baseUri = login.baseUris.first ?? ""
    }

    /** Microsoft picks the stream's size by the client's system: "android" 720p, "windows" 1080p. */
    static func osName(_ resolution: Int) -> String { resolution >= 1080 ? "windows" : "android" }

    private var osName: String { Self.osName(resolution) }

    private var deviceInfo: String {
        XboxHttp.json([
            "appInfo": ["env": [
                "clientAppId": "www.xbox.com", "clientAppType": "browser", "clientAppVersion": "29.9.35",
                "clientSdkVersion": "10.6.8", "httpEnvironment": "prod", "sdkInstallId": "",
            ]],
            "dev": [
                "hw": ["make": "Microsoft", "model": "unknown", "platformType": "desktop", "sdktype": "web"],
                "os": ["name": osName, "ver": "22631.2715", "platform": "desktop"],
                "displayInfo": [
                    "dimensions": ["widthInPixels": 1920, "heightInPixels": 1080],
                    "pixelDensity": ["dpiX": 1, "dpiY": 1],
                ] as [String: Any],
                "browser": ["browserName": "edge", "browserVersion": "140.0.3485.66"],
            ] as [String: Any],
        ] as [String: Any])
    }

    private var headers: [String: String] { ["Authorization": "Bearer \(login.gsToken)", "X-MS-Device-Info": deviceInfo] }

    private func get(_ path: String, base: String? = nil) async throws -> String {
        try await XboxHttp.call("GET", "\(base ?? baseUri)/\(path)", headers: headers)
    }

    @discardableResult
    private func post(_ path: String, _ body: [String: Any]) async throws -> String {
        try await XboxHttp.call("POST", "\(baseUri)/\(path)", body: XboxHttp.json(body), headers: headers)
    }

    /** The consoles, from the first region that has any. */
    func consoles() async throws -> [XboxConsole] {
        for base in login.baseUris {
            let list: [[String: Any]]
            do {
                list = (try XboxHttp.object(try await get("v6/servers/home?mr=50", base: base))["results"] as? [[String: Any]]) ?? []
            } catch {
                if base == login.baseUris.last { throw error }
                continue
            }
            if list.isEmpty { continue }
            baseUri = base
            return list.compactMap { o in
                guard let id = o["serverId"] as? String else { return nil }
                return XboxConsole(serverId: id, name: (o["deviceName"] as? String) ?? "", type: (o["consoleType"] as? String) ?? "",
                                   powerState: (o["powerState"] as? String) ?? "")
            }
        }
        return []
    }

    /** Start a session with the console (it then gets ready: [state]). */
    func play(_ serverId: String) async throws {
        let tz = TimeZone.current.secondsFromGMT() / 60
        let o = try XboxHttp.object(try await post("v5/sessions/home/play", [
            "clientSessionId": "", "titleId": "", "systemUpdateGroup": "",
            "settings": [
                "nanoVersion": "V3;WebrtcTransport.dll", "enableTextToSpeech": false, "highContrast": 0,
                "locale": "en-US", "useIceConnection": false, "timezoneOffsetMinutes": tz,
                "sdkType": "web", "osName": osName,
            ] as [String: Any],
            "serverId": serverId, "fallbackRegionNames": [String](),
        ]))
        guard var p = o["sessionPath"] as? String else { throw XboxFailure("no session from Microsoft") }
        while p.hasPrefix("/") { p.removeFirst() }
        sessionPath = p
    }

    private func session() throws -> String {
        guard let s = sessionPath else { throw XboxFailure("no session") }
        return s
    }

    /** The session's state ("Provisioning", "ReadyToConnect", "Provisioned", "Failed") and its error text. */
    func state() async throws -> (String, String?) {
        let s = try session()
        let o = try XboxHttp.object(try await get("\(s)/state"))
        let msg = (o["errorDetails"] as? [String: Any])?["message"] as? String
        return ((o["state"] as? String) ?? "", msg?.isEmpty == false ? msg : nil)
    }

    /** The console asks for the user's transfer token (state ReadyToConnect). */
    func connect(_ userToken: String) async throws {
        let s = try session()
        try await post("\(s)/connect", ["userToken": userToken])
    }

    /** Seconds between keep-alives (from the session's configuration). */
    func keepAliveSeconds() async -> Int {
        guard let s = sessionPath, let o = try? XboxHttp.object(try await get("\(s)/configuration")) else { return 20 }
        return min(300, max(5, (o["keepAlivePulseInSeconds"] as? Int) ?? 20))
    }

    /** Send the WebRTC offer; the console's answer SDP. */
    func exchangeSdp(_ offer: String) async throws -> String {
        let range = { (a: Int, b: Int) in ["minVersion": a, "maxVersion": b] }
        let cfg: [String: Any] = [
            "chatConfiguration": [
                "bytesPerSample": 2, "expectedClipDurationMs": 20, "format": ["codec": "opus", "container": "webm"],
                "numChannels": 1, "sampleFrequencyHz": 24000,
            ] as [String: Any],
            "chat": range(1, 1), "control": range(1, 3), "input": range(1, 8), "message": range(1, 1),
        ]
        let s = try session()
        try await post("\(s)/sdp", ["messageType": "offer", "sdp": offer, "configuration": cfg])
        let answer = try XboxHttp.object(try await poll("\(s)/sdp"))
        if let st = answer["status"] as? String, !st.isEmpty, st != "success" { throw XboxFailure("the console refused the stream: \(st)") }
        guard let sdp = answer["sdp"] as? String else { throw XboxFailure("no answer from the console") }
        return sdp
    }

    /** Send this phone's network candidates; the console's. */
    func exchangeIce(_ mine: [IceLine]) async throws -> [IceLine] {
        let a = mine.map { ["candidate": $0.candidate, "messageType": "iceCandidate", "sdpMLineIndex": String($0.index), "sdpMid": $0.mid] }
        let s = try session()
        try await post("\(s)/ice", ["messageType": "iceCandidate", "candidate": a])
        let text = try await poll("\(s)/ice")
        guard let got = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [] }
        return got.map { o in
            let index: Int
            if let i = o["sdpMLineIndex"] as? Int { index = i } else { index = Int((o["sdpMLineIndex"] as? String) ?? "0") ?? 0 }
            return IceLine(candidate: (o["candidate"] as? String) ?? "", mid: (o["sdpMid"] as? String) ?? "0", index: index)
        }
    }

    /** GET [path] each second until it carries an exchangeResponse (a JSON string), and return that. */
    private func poll(_ path: String, timeout: TimeInterval = 30) async throws -> String {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            try Task.checkCancellation()
            let body = try await get(path)
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let o = try XboxHttp.object(body)
                if let r = o["exchangeResponse"] as? String, !r.isEmpty { return r }
                if let m = (o["errorDetails"] as? [String: Any])?["message"] as? String, !m.isEmpty { throw XboxFailure(m) }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw XboxFailure("the console didn't answer")
    }

    func keepAlive() async throws {
        let s = try session()
        try await post("\(s)/keepalive", [:])
    }

    /** End the session (quietly: the console may have ended it already). */
    func stop() async {
        guard let s = sessionPath else { return }
        sessionPath = nil
        _ = try? await XboxHttp.call("DELETE", "\(baseUri)/\(s)", headers: headers)
    }

    // ---- the console's network candidates

    /** A candidate's line is one to leave out: the end marker, or a TCP-type line marked UDP. */
    static func skip(_ c: String) -> Bool {
        c.trimmingCharacters(in: .whitespaces).isEmpty || c.contains("end-of-candidates")
            || (c.range(of: "UDP", options: .caseInsensitive) != nil && c.contains("tcptype"))
    }

    /**
     * The console's network candidates, with the extra ones its Teredo (IPv6 over IPv4) address
     * stands for: its IPv4 addresses, at its port and at 3074, as xbox.com's player adds them.
     */
    static func withTeredo(_ c: [IceLine]) -> [IceLine] {
        var out: [IceLine] = []
        for t in c {
            out.append(t)
            var line = t.candidate
            if line.hasPrefix("a=") { line.removeFirst(2) }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 6, let h = teredo(parts[4]) else { continue }
            let port = Int(parts[5]) ?? 9002
            var adds = [(h.client, h.port), (h.server, port), (h.client, port)]
            if port != 3074 { adds += [(h.server, 3074), (h.client, 3074)] }
            var n = 100
            for (a, p) in adds {
                out.append(IceLine(candidate: "a=candidate:\(n) 1 UDP 100 \(a) \(p) typ host", mid: t.mid, index: t.index))
                n += 1
            }
        }
        return out
    }

    /** A Teredo address (2001:0::/32, RFC 4380): its server's IPv4, the client's IPv4, and the client's port. */
    static func teredo(_ ip: String) -> (server: String, client: String, port: Int)? {
        guard ip.contains(":"), let hx = expand(ip), hx[0] == 0x2001, hx[1] == 0 else { return nil }
        let server = "\(hx[2] >> 8).\(hx[2] & 255).\(hx[3] >> 8).\(hx[3] & 255)"
        let c6 = hx[6] ^ 0xffff, c7 = hx[7] ^ 0xffff
        let client = "\(c6 >> 8).\(c6 & 255).\(c7 >> 8).\(c7 & 255)"
        return (server, client, hx[5] ^ 0xffff)
    }

    /** An IPv6 address's 8 groups. */
    static func expand(_ ip: String) -> [Int]? {
        var s = ip
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        let head = halves[0].split(separator: ":").map(String.init)
        let tail = halves.count == 2 ? halves[1].split(separator: ":").map(String.init) : []
        let zeros = 8 - head.count - tail.count
        guard zeros >= 0, halves.count == 2 || zeros == 0 else { return nil }
        var out: [Int] = []
        for g in head + Array(repeating: "0", count: zeros) + tail {
            guard g.count <= 4, let v = Int(g, radix: 16) else { return nil }
            out.append(v)
        }
        return out.count == 8 ? out : nil
    }
}
