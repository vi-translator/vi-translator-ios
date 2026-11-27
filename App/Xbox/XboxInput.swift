import Foundation

/** The input channel's packets (little-endian), and the message channel's greetings: pure, for the tests. */
enum XboxInput {
    /** A packet's 14-byte header: its kind (bits), its number, the time in ms. */
    static func header(_ type: UInt16, seq: UInt32, ms: Double) -> Data {
        var d = Data()
        d.append(le: type)
        d.append(le: seq)
        d.append(le: ms.bitPattern)
        return d
    }

    /** Who this client is (ClientMetadata, 8): no touch points. 15 bytes. */
    static func clientMetadata(seq: UInt32, ms: Double) -> Data {
        var d = header(8, seq: seq, ms: ms)
        d.append(0)
        return d
    }

    /** One frame's timings (Metadata, 1; made up: this client draws nothing), which the console takes as a sign of life. 43 bytes. */
    static func metadata(seq: UInt32, ms: Double, epochMs: UInt32) -> Data {
        var d = header(1, seq: seq, ms: ms)
        d.append(1)
        let now = UInt32(truncatingIfNeeded: Int64(ms))
        d.append(le: epochMs)
        for _ in 0..<5 { d.append(le: now) }
        d.append(le: epochMs)
        return d
    }

    /** The six messages xbox.com's player sends after the console's HandshakeAck. */
    static func greetings(installId: String) -> [(String, [String: Any])] {
        [
            ("/streaming/systemUi/configuration", ["version": [0, 2, 0], "systemUis": [10, 19, 31, 27, 32, -44, 40, 41, -43]]),
            ("/streaming/properties/clientappinstallidchanged", ["clientAppInstallId": installId]),
            ("/streaming/characteristics/orientationchanged", ["orientation": 0]),
            ("/streaming/characteristics/touchinputenabledchanged", ["touchInputEnabled": false]),
            ("/streaming/characteristics/clientdevicecapabilities", [:]),
            ("/streaming/characteristics/dimensionschanged", [
                "horizontal": 1920, "vertical": 1080, "preferredWidth": 1920, "preferredHeight": 1080,
                "safeAreaLeft": 0, "safeAreaTop": 0, "safeAreaRight": 1920, "safeAreaBottom": 1080,
                "supportsCustomResolution": true,
            ]),
        ]
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le v: T) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}
