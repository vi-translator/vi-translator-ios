import Foundation
import UIKit

/**
 * VI Translator's shared core (the Rust crate vi-translator-ffi, linked from
 * ViTranslatorCore.xcframework, called through its UniFFI bindings in Generated/): the same
 * reading, translating and TV page as the desktop app. Its settings, translation memory and
 * connected TVs live in the app's Application Support folder.
 *
 * Every call may block (files, network): never on the main thread, except the quick ones noted.
 */
final class CoreHost: @unchecked Sendable {
    /** the TV page's port, as the desktop app's */
    static let port: UInt16 = 8791

    let engine: Engine
    private let listener: Listener
    let version: String = coreVersion()

    /** told when the lines read and translated change, and the core's status line (on the core's threads) */
    var linesChanged: (() -> Void)? {
        get { listener.lines }
        set { listener.lines = newValue }
    }

    var statusChanged: ((String) -> Void)? {
        get { listener.status }
        set { listener.status = newValue }
    }

    init(recognizer: TextRecognizer) throws {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let data = base.appendingPathComponent("vit", isDirectory: true)
        let db = base.appendingPathComponent("vit-db", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try fm.createDirectory(at: db, withIntermediateDirectories: true)
        listener = Listener()
        engine = try Engine(dataDir: data.path, dbDir: db.path, recognizer: recognizer, listener: listener)
    }

    /** The languages it translates into (quick). */
    lazy var languages: [Language] = ViTranslatorCore.languages()

    func language(_ code: String) -> Language? { languages.first { $0.code == code } }

    func prepare(game: String, language: String) throws {
        do {
            try engine.prepare(game: game, language: language)
        } catch let e as CoreError {
            throw CoreFailure(e.reason)
        }
    }

    /** One whole frame (RGBA, top row first): the core crops its areas, has Vision read them, translates. The ms to wait. */
    func processFrame(_ rgba: Data, width: Int, height: Int) throws -> UInt64 {
        try engine.processFrame(rgba: rgba, width: UInt32(width), height: UInt32(height))
    }

    func noPicture() {
        _ = try? engine.noPicture()
    }

    func lines(max: Int) -> [RecentLine] { engine.recentLines(max: UInt32(max)) }

    func configJson() -> String { engine.configJson() }

    func updateConfig(_ patch: String) throws {
        do {
            try engine.updateConfig(patch: patch)
        } catch let e as CoreError {
            throw CoreFailure(e.reason)
        }
    }

    func takeSnapshot(_ rgba: Data, width: Int, height: Int) throws -> String {
        do {
            return try engine.takeSnapshot(rgba: rgba, width: UInt32(width), height: UInt32(height))
        } catch let e as CoreError {
            throw CoreFailure(e.reason)
        }
    }

    @discardableResult
    func startServer() throws -> UInt16 {
        do {
            return try engine.startTvServer(port: Self.port)
        } catch let e as CoreError {
            throw CoreFailure(e.reason)
        }
    }

    func stopServer() { engine.stopTvServer() }

    /** TVs waiting to be connected on the home network (a few seconds). */
    func findTvs() -> [FoundTv] { engine.findTvs().filter { !$0.connected } }

    /** Connect the TV at [address] ("192.168.1.30:8792", or an IP alone) with the 6-digit code it shows. */
    func pairTv(address: String, code: String) -> PairResult {
        do {
            _ = try engine.pairTv(address: address.trimmingCharacters(in: .whitespaces), code: code.trimmingCharacters(in: .whitespaces), deviceName: Self.deviceName())
            return .ok
        } catch PairError.WrongCode {
            return .wrongCode
        } catch PairError.TooMany {
            return .newCode
        } catch PairError.NotSharing {
            return .notSharing
        } catch {
            return .unreachable
        }
    }

    func pairedTvs() -> [TvInfo] { engine.listTvs() }

    func forgetTv(_ id: String) { _ = engine.removeTv(id: id) }

    /** The name the TVs show for this phone ("iPhone", "iPad": iOS gives apps no more). Set on the main thread at start. */
    static var device = "iPhone"

    static func deviceName() -> String { String(device.prefix(60)) }

    private final class Listener: EngineListener, @unchecked Sendable {
        var lines: (() -> Void)?
        var status: ((String) -> Void)?

        func onTranslation(line: TranslatedLine) { lines?() }
        func onScreen(layoutJson: String?) {}
        func onStatus(message: String) { status?(message) }
        func onEvent(name: String, json: String) {}
    }
}

enum PairResult {
    case ok
    /** the code isn't the one the TV shows */
    case wrongCode
    /** too many wrong codes: the TV shows a new one */
    case newCode
    /** no TV app answered at that address */
    case unreachable
    /** this phone isn't on a home network */
    case notSharing
}

struct CoreFailure: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

extension CoreError {
    var reason: String {
        switch self {
        case let .Failed(reason): return reason
        }
    }
}
