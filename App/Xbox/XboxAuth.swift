import Foundation
import Security

/** One secret in the iOS Keychain (this device only, readable once the phone was unlocked after a restart). */
enum Keychain {
    private static let service = "app.vitranslator.xbox"

    static func get(_ account: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
        guard let value else { return }
        var add = q
        add[kSecValueData] = Data(value.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        if st != errSecSuccess { NSLog("Keychain: not saved (\(st))") }
    }
}

/**
 * Signing in to Xbox without a password page in the app: Microsoft's device code (the user types a
 * short code at microsoft.com/link on any device), as xbox.com's own client and the open-source Xbox
 * players (XStreaming, Greenlight) do, and as the Android app. The app keeps only Microsoft's refresh
 * token (in the Keychain); from it come the Xbox tokens for Remote Play when a stream starts.
 */
enum XboxAuth {
    // xbox.com's web client
    private static let clientId = "1f907974-e22b-4810-a9de-d9647380c97e"
    private static let scope = "xboxlive.signin openid profile offline_access"
    private static let aad = "https://login.microsoftonline.com/consumers/oauth2/v2.0"

    struct DeviceCode: Equatable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let interval: Int
        let expiresAt: Date
    }

    /** Signed out by Microsoft (the refresh token no longer works): sign in again. */
    struct SignedOut: LocalizedError {
        var errorDescription: String? { "signed out of Microsoft" }
    }

    /** the current access token and when it ends (in memory: made again from the refresh token) */
    private static let lock = NSLock()
    private static var access: (String, Date)?

    /** A new code for the user to type. */
    static func requestCode() async throws -> DeviceCode {
        let o = try XboxHttp.object(try await XboxHttp.call("POST", "\(aad)/devicecode", body: XboxHttp.form([("client_id", clientId), ("scope", scope)]), form: true))
        guard let dc = o["device_code"] as? String, let uc = o["user_code"] as? String else { throw XboxFailure("no code from Microsoft") }
        let interval = min(30, max(1, (o["interval"] as? Int) ?? 5))
        return DeviceCode(deviceCode: dc, userCode: uc, verificationUri: (o["verification_uri"] as? String) ?? "https://www.microsoft.com/link",
                          interval: interval, expiresAt: Date().addingTimeInterval(Double((o["expires_in"] as? Int) ?? 900)))
    }

    /**
     * Waits for the user to enter [dc] (polling as Microsoft asks, RFC 8628): true once signed in,
     * false if the code expired or was declined. Cancelling the task stops it.
     */
    static func waitForSignIn(_ dc: DeviceCode) async -> Bool {
        var interval = dc.interval
        while !Task.isCancelled && Date() < dc.expiresAt {
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if Task.isCancelled { return false }
            do {
                let o = try XboxHttp.object(try await XboxHttp.call("POST", "\(aad)/token", body: XboxHttp.form([
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"), ("client_id", clientId), ("device_code", dc.deviceCode),
                ]), form: true))
                save(o)
                return true
            } catch let e as HttpError {
                let err = ((try? XboxHttp.object(e.body))?["error"] as? String) ?? ""
                switch err {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                default: return false
                }
            } catch {
                // (no network for a moment: keep waiting)
            }
        }
        return false
    }

    static var signedIn: Bool { Keychain.get("refresh") != nil }

    /** Forget the sign-in (and the console chosen with it). */
    static func signOut() {
        Keychain.set("refresh", nil)
        lock.lock()
        access = nil
        lock.unlock()
        XboxConsole.saved = nil
    }

    private static func save(_ o: [String: Any]) {
        if let rt = o["refresh_token"] as? String, !rt.isEmpty { Keychain.set("refresh", rt) }
        if let at = o["access_token"] as? String {
            lock.lock()
            access = (at, Date().addingTimeInterval(Double((o["expires_in"] as? Int) ?? 3600)))
            lock.unlock()
        }
    }

    /** A current Microsoft access token, refreshed when it has under a minute left. */
    static func accessToken() async throws -> String {
        guard let refresh = Keychain.get("refresh") else { throw SignedOut() }
        lock.lock()
        let a = access
        lock.unlock()
        if let a, a.1.timeIntervalSinceNow > 60 { return a.0 }
        let o: [String: Any]
        do {
            o = try XboxHttp.object(try await XboxHttp.call("POST", "\(aad)/token", body: XboxHttp.form([
                ("client_id", clientId), ("grant_type", "refresh_token"), ("refresh_token", refresh), ("scope", scope),
            ]), headers: ["Cache-Control": "no-store, must-revalidate, no-cache"], form: true))
        } catch let e as HttpError where e.code == 400 || e.code == 401 {
            signOut()
            throw SignedOut()
        }
        save(o)
        guard let at = o["access_token"] as? String else { throw SignedOut() }
        return at
    }

    /** The token the console's /connect step asks for (Microsoft's "transfer token", from login.live.com with the same refresh token). */
    static func transferToken() async throws -> String {
        _ = try await accessToken()
        guard let refresh = Keychain.get("refresh") else { throw SignedOut() }
        let o = try XboxHttp.object(try await XboxHttp.call("POST", "https://login.live.com/oauth20_token.srf", body: XboxHttp.form([
            ("client_id", clientId),
            ("scope", "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"),
            ("grant_type", "refresh_token"), ("refresh_token", refresh),
        ]), form: true))
        guard let t = o["access_token"] as? String else { throw XboxFailure("no transfer token from Microsoft") }
        return t
    }

    private static let xblHeaders = [
        "x-xbl-contract-version": "1", "Cache-Control": "no-cache",
        "Origin": "https://www.xbox.com", "Referer": "https://www.xbox.com/",
    ]

    /** An Xbox Live token for [relyingParty] and the user hash (uhs) that goes with it. */
    static func xsts(_ relyingParty: String) async throws -> (token: String, uhs: String) {
        let msa = try await accessToken()
        let user = try XboxHttp.object(try await XboxHttp.call("POST", "https://user.auth.xboxlive.com/user/authenticate", body: XboxHttp.json([
            "Properties": ["AuthMethod": "RPS", "RpsTicket": "d=" + msa, "SiteName": "user.auth.xboxlive.com"],
            "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT",
        ] as [String: Any]), headers: xblHeaders))
        guard let ut = user["Token"] as? String else { throw XboxFailure("no Xbox user token") }
        let x = try XboxHttp.object(try await XboxHttp.call("POST", "https://xsts.auth.xboxlive.com/xsts/authorize", body: XboxHttp.json([
            "Properties": ["SandboxId": "RETAIL", "UserTokens": [ut]] as [String: Any],
            "RelyingParty": relyingParty, "TokenType": "JWT",
        ] as [String: Any]), headers: xblHeaders))
        guard let t = x["Token"] as? String else { throw XboxFailure("no Xbox token") }
        let xui = ((x["DisplayClaims"] as? [String: Any])?["xui"] as? [[String: Any]])?.first
        return (t, (xui?["uhs"] as? String) ?? "")
    }

    /** Remote Play's own token and the regions it offers (the default first). */
    static func streaming() async throws -> XboxHome.Login {
        let gssv = try await xsts("http://gssv.xboxlive.com/").token
        let o = try XboxHttp.object(try await XboxHttp.call("POST", "https://xhome.gssv-play-prod.xboxlive.com/v2/login/user",
                                                            body: XboxHttp.json(["token": gssv, "offeringId": "xhome"]),
                                                            headers: ["Cache-Control": "no-store, must-revalidate, no-cache", "x-gssv-client": "XboxComBrowser"]))
        let regions = ((o["offeringSettings"] as? [String: Any])?["regions"] as? [[String: Any]]) ?? []
        let uris = regions
            .sorted { (($0["isDefault"] as? Bool) ?? false) && !(($1["isDefault"] as? Bool) ?? false) }
            .compactMap { ($0["baseUri"] as? String).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } }
        guard let gs = o["gsToken"] as? String, !uris.isEmpty else { throw XboxFailure("no Remote Play token from Microsoft") }
        return XboxHome.Login(gsToken: gs, baseUris: uris)
    }

    /** Wake the console from sleep (Xbox's own remote power-on). */
    static func wake(_ serverId: String) async throws {
        let (token, uhs) = try await xsts("http://xboxlive.com")
        _ = try await XboxHttp.call("POST", "https://xccs.xboxlive.com/commands", body: XboxHttp.json([
            "destination": "Xbox", "type": "Power", "command": "WakeUp",
            "sessionId": UUID().uuidString.lowercased(), "sourceId": "com.microsoft.smartglass",
            "parameters": [String](), "linkedXboxId": serverId,
        ] as [String: Any]), headers: [
            "Authorization": "XBL3.0 x=\(uhs);\(token)", "skillplatform": "RemoteManagement",
            "x-xbl-contract-version": "4", "x-xbl-client-name": "XboxApp", "x-xbl-client-type": "UWA",
            "x-xbl-client-version": "39.39.22001.0", "Accept-Language": "en-US",
        ])
    }
}
