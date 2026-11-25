import Foundation
import JavaScriptCore

/// The terminal's JS engine on JavaScriptCore (PRONTO-1443): omnishell's engine contract (`start`, `dispatchAction`, a tree
/// stream) over the bridges the terminal owes the interpreter (native/bridges.cue), the same JS artifact Android's QuickJS runs.
/// One serial queue runs all JS, and every bridge answers by a later call on it.
final class TerminalEngine: @unchecked Sendable {
    /// What the host chooses: where the app's cluster is, the address the terminal opens first, and the clock.
    struct Config: @unchecked Sendable {
        var base = "https://host.invalid"
        var start = "/"
        var bundle: Bundle = .main
        var kv: Kv = MemoryKv()
        /// The clock behind timers: run `work` after `seconds`, answering a way to cancel. A test hands one it winds by hand.
        var schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> @Sendable () -> Void = { seconds, work in
            let sleeping = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { work() }
            }
            return { sleeping.cancel() }
        }
        var log: @Sendable (String, String) -> Void = { level, text in NSLog("pronto %@: %@", level, text) }
        var onReload: @Sendable () -> Void = {}
        var onExit: @Sendable () -> Void = {}
        var onOpen: @Sendable (String) -> Void = { _ in }
    }

    /// The scripts the engine evaluates, in order: JavaScriptCore's gaps, SES, then the terminal bundle when the host has one.
    private static let scripts = ["prelude.js", "ses.umd.min.js", "terminal.js"]

    private let queue = DispatchQueue(label: "pronto-jscore")
    private let config: Config
    private let context: JSContext
    private var timers: [Int: @Sendable () -> Void] = [:]
    private var continuation: AsyncStream<String>.Continuation?
    /// The screen as a DivKit card, whenever it changed.
    let tree: AsyncStream<String>
    /// The first script error: the screen cannot go on, so the host locks rather than show what a half-run update left.
    private(set) var failure: String?

    init(_ config: Config = Config()) {
        self.config = config
        context = queue.sync { JSContext() }
        var kept: AsyncStream<String>.Continuation?
        tree = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { kept = $0 }
        continuation = kept
        queue.sync {
            context.exceptionHandler = { [weak self] _, error in
                let text = error?.toString() ?? "unknown"
                self?.failure = self?.failure ?? text
                config.log("error", "script failed: \(text)")
            }
            bridges()
        }
    }

    /// Evaluates the scripts: the prelude, SES and the bundle, and boots the shell. Without a bundle the engine is headless
    /// (as Android's HostEngine without a screen) and only locks down.
    func start() {
        queue.sync {
            for name in Self.scripts {
                guard let source = script(name) else { continue }
                _ = context.evaluateScript(source + "\n;undefined", withSourceURL: URL(string: "pronto:\(name)"))
            }
            if script("terminal.js") == nil {
                _ = context.evaluateScript("lockdown({ errorTaming: \"unsafe\" }); undefined")
            } else {
                _ = context.evaluateScript("__boot(); undefined")
            }
        }
    }

    /// A DivKit action (`pronto://tap/<id>` or `pronto://contextmenu/<id>`): the person's touch, as the page's own handler takes it.
    func dispatchAction(_ url: String) {
        guard let parts = URLComponents(string: url), parts.scheme == "pronto", let kind = parts.host else { return }
        call("__onTap", kind, String(parts.path.dropFirst()))
    }

    func input(_ id: String, _ value: String) { call("__onInput", id, value) }
    func back() { call("__goBack") }
    func link(_ url: String) { call("__onLink", url) }
    func resize(_ dp: Int, _ hdp: Int) { call("__onResize", dp, hdp) }

    /// The text of a script's value, for a host that asks the page a question.
    func evaluate(_ source: String) -> String? {
        queue.sync { context.evaluateScript(source)?.toString() }
    }

    func close() {
        queue.sync {
            timers.values.forEach { $0() }
            timers = [:]
            continuation?.finish()
        }
    }

    private func script(_ name: String) -> String? {
        guard let url = config.bundle.url(forResource: name, withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func call(_ function: String, _ args: Any...) {
        queue.async { [context] in
            _ = context.objectForKeyedSubscript(function)?.call(withArguments: args)
        }
    }

    private func bind(_ name: String, _ block: Any) {
        context.setObject(block, forKeyedSubscript: name as NSString)
    }

    private static func json(_ value: Any) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    /// The bridges (native/bridges.cue) this host defines so far: the network and the passkeys come with their steps.
    private func bridges() {
        let config = self.config
        bind("__native_log", { (level: String, text: String) -> Any? in config.log(level, text); return nil } as @convention(block) (String, String) -> Any?)
        bind("__native_emit", { [weak self] (card: String) -> Any? in self?.continuation?.yield(card); return nil } as @convention(block) (String) -> Any?)
        bind("__native_base", { () -> Any? in config.base } as @convention(block) () -> Any?)
        bind("__native_start", { () -> Any? in config.start } as @convention(block) () -> Any?)
        bind("__native_reload", { () -> Any? in config.onReload(); return nil } as @convention(block) () -> Any?)
        bind("__native_exit", { () -> Any? in config.onExit(); return nil } as @convention(block) () -> Any?)
        bind("__native_open", { (url: String) -> Any? in config.onOpen(url); return nil } as @convention(block) (String) -> Any?)
        bind("__native_asset", { [weak self] (path: String) -> Any? in
            guard let text = self?.asset(path) else {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: "no asset \(path)", in: JSContext.current())
                return nil
            }
            return text
        } as @convention(block) (String) -> Any?)
        bind("__native_uuid", { () -> Any? in UUID().uuidString.lowercased() } as @convention(block) () -> Any?)
        bind("__native_random", { (count: Int) -> Any? in
            var generator = SystemRandomNumberGenerator()
            return Self.json((0..<max(count, 0)).map { _ in Int(generator.next() as UInt8) })
        } as @convention(block) (Int) -> Any?)
        bind("__native_locale", { () -> Any? in Locale.current.identifier(.bcp47) } as @convention(block) () -> Any?)
        bind("__native_zone", { () -> Any? in TimeZone.current.identifier } as @convention(block) () -> Any?)
        bind("__native_timer", { [weak self] (id: Int, ms: Int) -> Any? in self?.arm(id, ms); return nil } as @convention(block) (Int, Int) -> Any?)
        bind("__native_clear", { [weak self] (id: Int) -> Any? in self?.timers.removeValue(forKey: id)?(); return nil } as @convention(block) (Int) -> Any?)
        bind("__native_kv_get", { (ns: String, key: String) -> Any? in config.kv.get(ns, key) ?? NSNull() } as @convention(block) (String, String) -> Any?)
        bind("__native_kv_set", { (ns: String, key: String, value: String) -> Any? in config.kv.set(ns, key, value); return nil } as @convention(block) (String, String, String) -> Any?)
        bind("__native_kv_del", { (ns: String, key: String) -> Any? in config.kv.del(ns, key); return nil } as @convention(block) (String, String) -> Any?)
        bind("__native_kv_clear", { (ns: String) -> Any? in config.kv.clear(ns); return nil } as @convention(block) (String) -> Any?)
        bind("__native_kv_keys", { (ns: String) -> Any? in Self.json(config.kv.keys(ns)) } as @convention(block) (String) -> Any?)
    }

    /// A file the program ships, by its path under the bundle's `shell` or `messages` folder.
    private func asset(_ path: String) -> String? {
        guard !path.contains(".."), let root = config.bundle.resourceURL else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// One wake of the page's timer: later, on the JS queue, `__onTimer(id)`.
    private func arm(_ id: Int, _ ms: Int) {
        timers[id] = config.schedule(Double(ms) / 1000) { [weak self] in
            self?.queue.async {
                guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                _ = self.context.objectForKeyedSubscript("__onTimer")?.call(withArguments: [id])
            }
        }
    }
}
