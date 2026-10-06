import SwiftUI

#if os(macOS) && canImport(Sparkle) && !APP_STORE
import Sparkle

@MainActor @Observable final class AppUpdater {
    static let shared = AppUpdater()
    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheck = false
    var automaticChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    var automaticDownloads: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticDownloads }
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        automaticDownloads = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let enabled = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheck = enabled }
        }
    }

    func check() { controller.checkForUpdates(nil) }
}

struct CheckForUpdatesButton: View {
    @State private var updater = AppUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
    }
}

struct UpdateSettings: View {
    @State private var updater = AppUpdater.shared
    var body: some View {
        Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
        Toggle("Download updates in the background", isOn: $updater.automaticDownloads).disabled(!updater.automaticChecks)
        CheckForUpdatesButton()
        Text("Updates are verified with the app’s signing key before installation.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
#endif
