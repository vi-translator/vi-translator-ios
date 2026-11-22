import Foundation
import UIKit

/**
 * Whether the app may use the GPU now. iOS forbids GPU work from an app in the background: work
 * sent then fails, or never finishes, and whatever waits on it (the reading, the preview) would wait
 * forever. Turned off the moment iOS says the app goes to the background, on again as it comes back.
 */
enum Gpu {
    private static let lock = NSLock()
    private static var on = true
    private static var observers: [NSObjectProtocol] = []

    static var allowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    private static func set(_ v: Bool) {
        lock.lock()
        on = v
        lock.unlock()
    }

    /** Once, at start. */
    static func watch() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in set(false) })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in set(true) })
    }
}
