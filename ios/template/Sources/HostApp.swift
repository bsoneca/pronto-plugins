import SwiftUI

// The iOS host's first screen (PRONTO-1442): a native label and nothing else. The terminal's
// engine, storage and screens arrive in the steps after it; the label proves the project builds,
// installs and starts on a simulator.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup {
            Text(label)
                .font(.largeTitle)
                .accessibilityIdentifier("host-label")
        }
    }

    // What the launcher shows, from the project's Info.plist (ios/host.cue's `label`).
    private var label: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
    }
}
