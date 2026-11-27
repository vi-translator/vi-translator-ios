import XCTest
@testable import VITranslator

/** The Xbox client's pure parts: Teredo addresses, the console's candidates, the input packets, the stream size. */
final class XboxTests: XCTestCase {
    /** RFC 4380's own example: server 65.54.227.120, client 192.0.2.45, port 40000. */
    func testTeredoDecoding() {
        let t = XboxHome.teredo("2001:0000:4136:e378:8000:63bf:3fff:fdd2")
        XCTAssertEqual(t?.server, "65.54.227.120")
        XCTAssertEqual(t?.client, "192.0.2.45")
        XCTAssertEqual(t?.port, 40000)
        // (the same written short)
        XCTAssertEqual(XboxHome.teredo("2001:0:4136:e378:8000:63bf:3fff:fdd2")?.client, "192.0.2.45")
    }

    func testNotTeredo() {
        XCTAssertNil(XboxHome.teredo("192.168.1.20"))
        XCTAssertNil(XboxHome.teredo("fe80::1"))
        XCTAssertNil(XboxHome.teredo("2001:db8::1"))
        XCTAssertNil(XboxHome.teredo("2001:0:zzzz::1"))
    }

    func testExpand() {
        XCTAssertEqual(XboxHome.expand("2001::1"), [0x2001, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(XboxHome.expand("[fe80::1%en0]"), [0xfe80, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertNil(XboxHome.expand("1::2::3"))
        XCTAssertNil(XboxHome.expand("1:2:3"))
    }

    /** A Teredo candidate gets five IPv4 candidates after it (two at 3074); others are left as they are. */
    func testWithTeredo() {
        let teredo = IceLine(candidate: "a=candidate:1 1 UDP 1 2001:0000:4136:e378:8000:63bf:3fff:fdd2 9002 typ host", mid: "0", index: 0)
        let plain = IceLine(candidate: "a=candidate:2 1 UDP 1 192.168.1.20 9002 typ host", mid: "0", index: 0)
        let out = XboxHome.withTeredo([teredo, plain])
        XCTAssertEqual(out.count, 7)
        XCTAssertEqual(out[0], teredo)
        XCTAssertEqual(out[1].candidate, "a=candidate:100 1 UDP 100 192.0.2.45 40000 typ host")
        XCTAssertEqual(out[2].candidate, "a=candidate:101 1 UDP 100 65.54.227.120 9002 typ host")
        XCTAssertEqual(out[3].candidate, "a=candidate:102 1 UDP 100 192.0.2.45 9002 typ host")
        XCTAssertEqual(out[4].candidate, "a=candidate:103 1 UDP 100 65.54.227.120 3074 typ host")
        XCTAssertEqual(out[5].candidate, "a=candidate:104 1 UDP 100 192.0.2.45 3074 typ host")
        XCTAssertEqual(out[6], plain)
        // (at 3074 already: three)
        let at3074 = IceLine(candidate: "candidate:1 1 UDP 1 2001:0:4136:e378:8000:63bf:3fff:fdd2 3074 typ host", mid: "0", index: 0)
        XCTAssertEqual(XboxHome.withTeredo([at3074]).count, 4)
    }

    func testSkippedCandidates() {
        XCTAssertTrue(XboxHome.skip("a=end-of-candidates"))
        XCTAssertTrue(XboxHome.skip(""))
        XCTAssertTrue(XboxHome.skip("candidate:3 1 udp 1 10.0.0.2 9 typ host tcptype active"))
        XCTAssertFalse(XboxHome.skip("candidate:2 1 UDP 1 192.168.1.20 9002 typ host"))
    }

    /** Microsoft picks the stream's size by the client's system. */
    func testOsName() {
        XCTAssertEqual(XboxHome.osName(1080), "windows")
        XCTAssertEqual(XboxHome.osName(720), "android")
    }

    func testInputPackets() {
        let meta = XboxInput.clientMetadata(seq: 0, ms: 12.5)
        XCTAssertEqual(meta.count, 15)
        XCTAssertEqual(meta[0], 8)
        XCTAssertEqual(meta[1], 0)
        let m = XboxInput.metadata(seq: 7, ms: 1000, epochMs: 0x01020304)
        XCTAssertEqual(m.count, 43)
        XCTAssertEqual(Array(m[0..<2]), [1, 0])
        XCTAssertEqual(Array(m[2..<6]), [7, 0, 0, 0])
        XCTAssertEqual(m[14], 1)
        XCTAssertEqual(Array(m[15..<19]), [4, 3, 2, 1])
        XCTAssertEqual(Array(m[19..<23]), [0xe8, 0x03, 0, 0])
    }

    /** The greetings are valid JSON objects, sent as strings inside the message. */
    func testGreetings() throws {
        let g = XboxInput.greetings(installId: "x")
        XCTAssertEqual(g.count, 6)
        for (target, content) in g {
            XCTAssertTrue(target.hasPrefix("/streaming/"))
            let text = XboxHttp.json(content)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        XCTAssertTrue(XboxHttp.json(g[0].1).contains("\"systemUis\":[10,19,31,27,32,-44,40,41,-43]"))
    }

    func testForm() {
        XCTAssertEqual(XboxHttp.form([("scope", "xboxlive.signin openid"), ("a", "b+c")]), "scope=xboxlive.signin%20openid&a=b%2Bc")
    }
}
