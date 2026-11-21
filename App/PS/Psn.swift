import Foundation
import SwiftUI
import WebKit

/**
 * The PSN account ID, which registering with a PS5 needs (as the Android app's Psn): the user signs
 * in on Sony's own page (Remote Play's sign-in, as chiaki-ng does it), which sends back a code; the
 * code gives a token, and the token's details give the account's number (8 bytes, little-endian,
 * in base64). The app keeps only the account ID: no password, and the token is dropped.
 */
enum Psn {
    // Sony's Remote Play app (the PC one), as used by chiaki-ng (gui/include/psnaccountid.h)
    private static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    private static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    private static let tokenUrl = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"

    static var loginUrl: String {
        "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?service_entity=urn:service-entity:psn" +
            "&response_type=code&client_id=\(clientId)&redirect_uri=\(enc(redirect))&scope=\(enc(scope))" +
            "&request_locale=en_US&ui=pr&service_logo=ps&layout_type=popup&smcid=remoteplay&prompt=always&PlatformPrivacyWs1=minimal"
    }

    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static var basic: String {
        "Basic " + Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
    }

    /** The sign-in code in the address Sony's page ended on, or nil. */
    static func code(in address: String) -> String? {
        guard let r = address.range(of: #"[?&]code=([^&#\s]+)"#, options: .regularExpression) else { return nil }
        let part = address[r].drop { $0 != "=" }.dropFirst()
        return String(part).removingPercentEncoding ?? String(part)
    }

    /** The account ID (base64) for the code Sony's page redirected with. */
    static func accountId(code: String) async throws -> String {
        let body = "grant_type=authorization_code&code=\(enc(code))&scope=\(enc(scope))&redirect_uri=\(enc(redirect))"
        let tokenJson = try await http(tokenUrl, form: body)
        guard let token = (try JSONSerialization.jsonObject(with: tokenJson) as? [String: Any])?["access_token"] as? String else {
            throw CoreFailure("PSN gave no token")
        }
        let infoJson = try await http("\(tokenUrl)/\(enc(token))", form: nil)
        let info = try JSONSerialization.jsonObject(with: infoJson) as? [String: Any]
        let userId = (info?["user_id"] as? String) ?? (info?["user_id"] as? NSNumber)?.stringValue
        guard let userId, let id = accountIdOf(userId) else { throw CoreFailure("PSN gave no account") }
        return id
    }

    /** The account's number (decimal) as Remote Play's account ID: 8 bytes little-endian, base64. */
    static func accountIdOf(_ userId: String) -> String? {
        guard var n = UInt64(userId.trimmingCharacters(in: .whitespaces)) else { return nil }
        var b = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            b[i] = UInt8(n & 0xff)
            n >>= 8
        }
        return Data(b).base64EncodedString()
    }

    private static func http(_ url: String, form: String?) async throws -> Data {
        guard let u = URL(string: url) else { throw CoreFailure("bad address") }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.setValue(basic, forHTTPHeaderField: "Authorization")
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(form.utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CoreFailure("PSN answered \(status): \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        return data
    }
}

/**
 * Sony's sign-in page, in the app: when it sends back to the redirect address with ?code=, the
 * code is taken (never loaded) and turned into the account ID. [done] gets it, or an error.
 */
struct PsnLoginView: UIViewRepresentable {
    let done: (Result<String, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        if let u = URL(string: Psn.loginUrl) { web.load(URLRequest(url: u)) }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let done: (Result<String, Error>) -> Void
        private var finished = false

        init(_ d: @escaping (Result<String, Error>) -> Void) { done = d }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url?.absoluteString, url.hasPrefix(Psn.redirect) else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            caught(url)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url?.absoluteString, url.hasPrefix(Psn.redirect) {
                webView.stopLoading()
                caught(url)
            }
        }

        private func caught(_ url: String) {
            if finished { return }
            finished = true
            guard let code = Psn.code(in: url), !code.isEmpty else {
                let err = URLComponents(string: url)?.queryItems?.first { $0.name == "error_description" || $0.name == "error" }?.value
                done(.failure(CoreFailure(err ?? "no code")))
                return
            }
            Task { @MainActor in
                do {
                    done(.success(try await Psn.accountId(code: code)))
                } catch {
                    done(.failure(error))
                }
            }
        }
    }
}
