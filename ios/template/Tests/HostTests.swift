import XCTest

// The generated project is what ios/host.cue says (PRONTO-1442): the app's bundle id, its versions
// and its label are read back from the built bundle.
final class HostTests: XCTestCase {
    func testBundleIdIsTheSpec() {
        XCTAssertEqual(Bundle(for: HostTests.self).bundleIdentifier, "__BUNDLE_ID__.tests")
        let host = Bundle.main
        XCTAssertEqual(host.bundleIdentifier, "__BUNDLE_ID__")
    }

    func testVersionsAreTheSpec() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "__MARKETING_VERSION__")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "__BUILD_NUMBER__")
    }

    func testLabelIsShown() {
        let label = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        XCTAssertEqual(label?.isEmpty, false)
    }
}
