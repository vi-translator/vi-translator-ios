import UIKit
import XCTest
@testable import VITranslator

/** The capture card's format choice (the card itself needs a USB-C iPad: see docs/device-test-plan.md). */
final class CaptureTests: XCTestCase {
    private func m(_ w: Int, _ h: Int, _ fps: Double) -> CaptureCard.Mode { CaptureCard.Mode(width: w, height: h, maxFps: fps) }

    func testPrefers1080pAt30OrMore() {
        let modes = [m(3840, 2160, 30), m(1280, 720, 60), m(1920, 1080, 30), m(1920, 1080, 60), m(640, 480, 60)]
        XCTAssertEqual(CaptureCard.best(modes), 3)
        XCTAssertEqual(CaptureCard.best([m(1920, 1080, 5), m(1920, 1080, 30)]), 1)
    }

    func testWithout1080pTheNearestFromAbove720() {
        XCTAssertEqual(CaptureCard.best([m(640, 480, 60), m(1280, 720, 60), m(1600, 900, 30), m(3840, 2160, 60)]), 2)
        XCTAssertEqual(CaptureCard.best([m(640, 480, 60), m(3840, 2160, 30), m(2560, 1440, 30)]), 2)
        XCTAssertEqual(CaptureCard.best([m(640, 480, 30), m(320, 240, 60)]), 0)
        XCTAssertNil(CaptureCard.best([]))
    }

    func testNotOfferedWhereUnsupported() {
        // (the Simulator has no external cameras; on an iPhone the option is hidden)
        if UIDevice.current.userInterfaceIdiom == .phone { XCTAssertFalse(CaptureCard.supported) }
        XCTAssertTrue(CaptureCard.cards().isEmpty)
    }
}
