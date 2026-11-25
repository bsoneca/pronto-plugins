@testable import Host
import JavaScriptCore
import XCTest

/// The JS engine on JavaScriptCore (PRONTO-1443): the globals owed before lockdown(), SES under it and the shared host
/// battery (native/battery.cue), the one conformance suite every native host runs on its own engine.
final class EngineTests: XCTestCase {
    /// A clock the test winds by hand: what a timer asked for, and what was cancelled.
    final class Wind: @unchecked Sendable {
        var pending: [(seconds: TimeInterval, work: @Sendable () -> Void)] = []
        var cancelled = 0
    }

    private func started(_ wind: Wind = Wind()) -> TerminalEngine {
        var config = TerminalEngine.Config()
        config.schedule = { seconds, work in
            wind.pending.append((seconds, work))
            return { wind.cancelled += 1 }
        }
        let engine = TerminalEngine(config)
        engine.start()
        return engine
    }

    private func resource(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: EngineTests.self).url(forResource: name, withExtension: nil), name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// An ES module as a script: its exports are plain declarations the wrapper then returns.
    private func script(_ module: String) -> String {
        module.replacingOccurrences(of: "export function ", with: "function ").replacingOccurrences(of: "export class ", with: "class ")
    }

    private func batteryResults(_ engine: TerminalEngine) throws -> [[String: Any]] {
        let setup = """
        globalThis.__battery = (() => {
        \(script(try resource("passkeys.js")))
        \(script(try resource("battery.js")))
        return { run, passkeys: { optionsToJson, credentialOf } };
        })(); undefined
        """
        _ = engine.evaluate(setup)
        let run = "JSON.stringify(__battery.run({ engine: { eval: (s) => (0, eval)(s) }, passkeys: __battery.passkeys, cases: \(try resource("battery.json")) }))"
        let text = try XCTUnwrap(engine.evaluate(run))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]], text)
    }

    func testHostBatteryPasses() throws {
        let results = try batteryResults(started())
        XCTAssertEqual(results.count, 8)
        let failed = results.filter { $0["ok"] as? Bool != true }.map { "\($0["id"] ?? "?"): \($0["got"] ?? "")" }
        XCTAssertEqual(failed, [])
    }

    func testGlobalsOwedAreThere() throws {
        let engine = started()
        let kinds = engine.evaluate("JSON.stringify(['console', 'queueMicrotask', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Intl', 'Compartment'].map((k) => typeof globalThis[k]))")
        XCTAssertEqual(kinds, "[\"object\",\"function\",\"function\",\"function\",\"function\",\"function\",\"object\",\"function\"]")
        XCTAssertEqual(engine.evaluate("String(Object.isFrozen(Object.prototype))"), "true")
        _ = engine.evaluate("queueMicrotask(() => { globalThis.ran = 'yes'; }); undefined")
        XCTAssertEqual(engine.evaluate("String(globalThis.ran)"), "yes")
    }

    func testTimersRunOnTheClockTheHostGives() {
        let wind = Wind()
        let engine = started(wind)
        _ = engine.evaluate("globalThis.count = 0; globalThis.id = setTimeout((a) => { globalThis.count += a; }, 250, 5); undefined")
        XCTAssertEqual(wind.pending.map(\.seconds), [0.25])
        wind.pending.removeFirst().work()
        XCTAssertEqual(engine.evaluate("String(count)"), "5")
        _ = engine.evaluate("globalThis.later = setTimeout(() => { globalThis.count = -1; }, 10); clearTimeout(later); undefined")
        XCTAssertEqual(wind.cancelled, 1)
        wind.pending.removeFirst().work()
        XCTAssertEqual(engine.evaluate("String(count)"), "5", "a cleared timer does not run")
    }

    func testBridgesAreBounded() {
        let wind = Wind()
        let engine = started(wind)
        XCTAssertEqual(engine.evaluate("String(JSON.parse(__native_random(70000)).length)"), "65536")
        XCTAssertEqual(engine.evaluate("try { __native_asset('prelude.js'); 'read' } catch { 'refused' }"), "refused")
        _ = engine.evaluate("globalThis.ticks = 0; setInterval(() => { globalThis.ticks += 1; }); undefined")
        wind.pending.removeFirst().work()
        XCTAssertEqual(engine.evaluate("String(ticks)"), "1")
        XCTAssertEqual(wind.pending.map(\.seconds), [0.001], "an interval without a delay repeats")
        XCTAssertNil(engine.failure)
    }

    func testIntlAnswersFromTheSystem() {
        let engine = started()
        XCTAssertEqual(engine.evaluate("__native_intl('plural', 'en', '{}', '1')"), "one")
        XCTAssertEqual(engine.evaluate("__native_intl('plural', 'en', '{}', '2')"), "other")
        XCTAssertEqual(engine.evaluate("__native_intl('number', 'en-US', '{\"maximumFractionDigits\":1}', '1234.56')"), "1,234.6")
        XCTAssertEqual(engine.evaluate("__native_intl('date', 'en-US', '{\"timeZone\":\"UTC\",\"year\":\"numeric\",\"month\":\"long\"}', '0')"), "January 1970")
        XCTAssertEqual(engine.evaluate("__native_intl('canonical', 'EN-us', '{}', '')"), "en-US")
    }

    func testActionsReachThePageAndTheTreeStreams() async throws {
        let engine = started()
        _ = engine.evaluate("globalThis.__onTap = (kind, id) => { __native_emit(`card:${kind}:${id}`); }; undefined")
        engine.dispatchAction("pronto://tap/start")
        var cards = engine.tree.makeAsyncIterator()
        let card = await cards.next()
        XCTAssertEqual(card, "card:tap:start")
        engine.close()
    }

    func testColdStartAndOneDispatchAreMeasured() throws {
        let quoted = { (text: String) in try XCTUnwrap(String(bytes: try JSONEncoder().encode(text), encoding: .utf8)) }
        let began = Date()
        let engine = started()
        let cold = Date().timeIntervalSince(began)
        let fold = "(source, events) => { const handler = new Compartment({}).evaluate(source); let state = null; return events.map((e) => { const out = handler(state, e); state = out.state; return out.tree; }); }"
        let source = "(state, event) => { const n = (state === null ? 0 : state.n) + 1; return { state: { n }, tree: `<p>${n}</p>` }; }"
        let dispatchBegan = Date()
        let tree = engine.evaluate("JSON.stringify((\(fold))(\(try quoted(source)), ['tap']))")
        let dispatch = Date().timeIntervalSince(dispatchBegan)
        XCTAssertEqual(tree, "[\"<p>1</p>\"]")
        NSLog("pronto timing: cold start %.1f ms, one handler dispatch %.2f ms", cold * 1000, dispatch * 1000)
    }
}
