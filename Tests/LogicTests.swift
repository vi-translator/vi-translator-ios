import CoreVideo
import UIKit
import XCTest
@testable import VITranslator

/** The app's own logic, without a console: parsing, the PSN account ID, addresses, the dictionaries. */
final class LogicTests: XCTestCase {
    func testNalUnitsSplitOnBothStartCodes() {
        let b: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9, 9]
        let units = b.withUnsafeBufferPointer { H264Decoder.nalUnits($0) }
        XCTAssertEqual(units.map { Array($0) }, [[0x67, 1, 2], [0x68, 3], [0x65, 9, 9, 9]])
    }

    func testAccountIdIsEightBytesLittleEndian() {
        // 0x0102030405060708
        let id = Psn.accountIdOf("72623859790382856")
        XCTAssertEqual(id.flatMap { Data(base64Encoded: $0) }.map { Array($0) }, [8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertNil(Psn.accountIdOf("not a number"))
        XCTAssertTrue(Ps5.validAccount(id!))
        XCTAssertFalse(Ps5.validAccount("abc"))
    }

    func testSignInCodeFromTheRedirectAddress() {
        XCTAssertEqual(Psn.code(in: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=v3.AbC%2Bd&cid=x"), "v3.AbC+d")
        XCTAssertNil(Psn.code(in: "https://remoteplay.dl.playstation.net/remoteplay/redirect?error=access_denied"))
    }

    func testAddresses() {
        XCTAssertTrue(Ps5.validAddress("192.168.1.20"))
        XCTAssertTrue(Ps5.validAddress(" 10.0.0.1 "))
        XCTAssertFalse(Ps5.validAddress("192.168.1.256"))
        XCTAssertFalse(Ps5.validAddress("192.168.1"))
        XCTAssertFalse(Ps5.validAddress("12345678"))
        XCTAssertFalse(Ps5.validAddress("1234 5678"))
        XCTAssertFalse(Ps5.validAddress("ps5..local"))
        XCTAssertFalse(Ps5.validAddress("-ps5.local"))
        XCTAssertTrue(Ps5.validAddress("ps5.local"))
        XCTAssertTrue(Ps5.validAddress("PS5-123"))
        XCTAssertTrue(Ps5.looksLikePin("1234 5678"))
        XCTAssertFalse(Ps5.looksLikePin("192.168.1.20"))
        XCTAssertEqual(Ps5.digitsOnly("١٢٣٤ ٥٦٧٨"), "12345678")
        XCTAssertEqual(Ps5.digitsOnly("۱۲۳۴-۵۶۷۸"), "12345678")
        XCTAssertEqual(Ps5.asciiDigits("١٩٢.١٦٨.١.٢٠"), "192.168.1.20")
    }

    func testWakeCredentialIsTheRegistKeyInHex() {
        let c = PsConsole(host: "h", nickname: "", mac: Data(count: 6), registKey: Data("0123abcd".utf8) + Data(count: 8), rpKey: Data(count: 16))
        XCTAssertEqual(c.credential, 0x0123abcd)
        XCTAssertEqual(c.name, "PS5")
    }

    func testWordsAndBoxes() {
        let s = "MISSION  PASSED  "
        XCTAssertEqual(VisionRecognizer.wordRanges(s).map { String(s[$0]) }, ["MISSION", "PASSED"])
        // Vision's origin is the bottom left: the top quarter of a 100x100 picture
        let r = VisionRecognizer.pixels(CGRect(x: 0.1, y: 0.75, width: 0.5, height: 0.25), 100, 100)
        XCTAssertEqual(r, CGRect(x: 10, y: 0, width: 50, height: 25))
    }

    func testInterfaceLanguages() {
        I18n.load("en")
        XCTAssertEqual(I18n.langs.count, 33)
        XCTAssertEqual(I18n.fromLocale(Locale(identifier: "zh_TW")), "zh-Hant")
        XCTAssertEqual(I18n.fromLocale(Locale(identifier: "es_ES")), "es-ES")
        XCTAssertEqual(I18n.fromLocale(Locale(identifier: "es_AR")), "es-MX")
        XCTAssertEqual(I18n.fromLocale(Locale(identifier: "pt_PT")), "pt-BR")
        XCTAssertEqual(I18n.fromLocale(Locale(identifier: "ar_SA")), "ar")
        I18n.load("ar")
        XCTAssertTrue(I18n.rtl)
        XCTAssertNotEqual(L("Start translating"), "Start translating")
        XCTAssertEqual(L("Waking {name}…", ("name", "PS5")).contains("PS5"), true)
        I18n.load("en")
        XCTAssertEqual(L("Waking {name}…", ("name", "PS5")), "Waking PS5…")
    }

    func testEveryLanguageHasItsDictionary() {
        I18n.load("en")
        for l in I18n.langs where l.code != "en" {
            XCTAssertNotNil(Bundle.main.url(forResource: l.code, withExtension: "json", subdirectory: "i18n"), l.code)
        }
    }

    func testSettingsJsonKeepsNestedChangesInPlace() {
        let c = Cfg(core: nil)
        c.set(Cfg.parse(#"{"profile":"gta6","builtins":[{"id":"gta6","name":"GTA VI","game":"gta6","areas":[{"id":"a","x":0.1}]}],"areas":[{"id":"a","x":0.1}]}"#))
        XCTAssertTrue(c.locked())
        XCTAssertEqual(c.profileGame(), "gta6")
        // (a built-in profile can't be changed: a copy of it can, and keeps its changes)
        c.copyProfile(c.activeProfile()!)
        XCTAssertFalse(c.locked())
        XCTAssertEqual(c.profiles().count, 1)
        XCTAssertEqual(Cfg.d(c.areaList().first, "x"), 0.1)
        c.areaList().first?["x"] = 0.5
        c.touched("areas")
        XCTAssertEqual(Cfg.d(c.areaList().first, "x"), 0.5)
        let saved = (c.profiles().first?["areas"] as? NSArray)?.firstObject as? NSDictionary
        XCTAssertEqual(Cfg.d(saved, "x"), 0.5)
        // the built-in one is as it was
        XCTAssertEqual(Cfg.d((c.builtins().first?["areas"] as? NSArray)?.firstObject as? NSDictionary, "x"), 0.1)
    }

    func testFontsAreBundled() {
        XCTAssertNotNil(UIFont(name: "Tajawal-Bold", size: 12))
        XCTAssertNotNil(UIFont(name: "Tajawal-Regular", size: 12))
        XCTAssertFalse(UIFont.fontNames(forFamilyName: "Lalezar").isEmpty)
    }

    func testCropOfAnImageKeepsTheTopRowFirst() {
        // a 4x4 picture: the top half white, the bottom half black
        let w = 4, h = 4
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<2 { for x in 0..<w { for c in 0..<3 { px[(y * w + x) * 4 + c] = 255 } } }
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        let img = Reader.cgImage(Data(px), w, h)!
        let all = Reader.rgba(of: img)!
        XCTAssertEqual(all.0[0], 255)
        XCTAssertEqual(all.0[(3 * w) * 4], 0)
        let bottom = Reader.rgba(of: img, crop: CGRect(x: 0, y: 2, width: 4, height: 2))!
        XCTAssertEqual(bottom.2, 2)
        XCTAssertEqual(bottom.0[0], 0)
    }

    func testBlackPictures() {
        XCTAssertTrue(XboxPlayer.isBlack(Data(count: 64 * 36 * 4), 64, 36))
        var d = Data(count: 64 * 36 * 4)
        d[100 * 4] = 200
        XCTAssertFalse(XboxPlayer.isBlack(d, 64, 36))
    }
}
