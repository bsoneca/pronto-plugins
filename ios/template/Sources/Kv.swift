import Foundation

/// The store behind the `__native_kv_*` bridges (native/bridges.cue): text kept under a namespace and a key.
protocol Kv: AnyObject, Sendable {
    func get(_ namespace: String, _ key: String) -> String?
    func set(_ namespace: String, _ key: String, _ value: String)
    func del(_ namespace: String, _ key: String)
    func clear(_ namespace: String)
    func keys(_ namespace: String) -> [String]
}

/// The contract's behaviour in memory: what a sealed store must match, and what a headless engine keeps.
final class MemoryKv: Kv, @unchecked Sendable {
    private let lock = NSLock()
    private var spaces: [String: [String: String]] = [:]

    func get(_ namespace: String, _ key: String) -> String? {
        lock.withLock { spaces[namespace]?[key] }
    }

    func set(_ namespace: String, _ key: String, _ value: String) {
        lock.withLock { spaces[namespace, default: [:]][key] = value }
    }

    func del(_ namespace: String, _ key: String) {
        lock.withLock { _ = spaces[namespace]?.removeValue(forKey: key) }
    }

    func clear(_ namespace: String) {
        lock.withLock { _ = spaces.removeValue(forKey: namespace) }
    }

    func keys(_ namespace: String) -> [String] {
        lock.withLock { Array(spaces[namespace]?.keys ?? [:].keys) }
    }
}
