import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/** An HTTP answer that wasn't 2xx: its status and body. */
struct HttpError: LocalizedError {
    let code: Int
    let body: String
    let host: String

    var errorDescription: String? { "HTTP \(code) from \(host): \(body.prefix(300))" }
}

/** Something that went wrong, in words for the user. */
struct XboxFailure: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/** HTTP for the Xbox services (JSON or a form in, the body as text out), as the Android app's XboxHttp. */
enum XboxHttp {
    static func call(_ method: String, _ url: String, body: String? = nil, headers: [String: String] = [:], form: Bool = false) async throws -> String {
        guard let u = URL(string: url) else { throw XboxFailure("bad address: \(url)") }
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(body.utf8)
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(code) else { throw HttpError(code: code, body: text, host: u.host ?? url) }
        return text
    }

    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func form(_ p: [(String, String)]) -> String {
        p.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&")
    }

    /** A JSON object as text (slashes as they are). */
    static func json(_ o: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func object(_ text: String) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw XboxFailure("unexpected answer: \(text.prefix(200))")
        }
        return o
    }
}
