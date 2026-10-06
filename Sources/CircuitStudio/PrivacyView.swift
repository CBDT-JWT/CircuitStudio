import SwiftUI

enum AppPrivacy {
    static let sections: [(String, String)] = [
        ("No developer data collection", "Circuit Studio does not require an app account, operate a developer server, include advertising or analytics, or track you across apps and websites."),
        ("Your documents", "Circuit diagrams, figures, labels, models and previews are stored in the files you create. We do not receive these files. If you save them in iCloud Drive, Apple handles storage and synchronization under your Apple account and settings."),
        ("Local simulation", "SPICE analyses run on your device using the bundled ngspice engine. Circuit data and simulation results are not sent to a remote simulation service."),
        ("Export and sharing", "You choose when and where to export or share. CircuitikZ exports include editable circuit data for re-import. Files shared with another app or service are handled according to that recipient's privacy practices."),
        ("Settings and file access", "Appearance preferences are stored locally. File access is granted through system document pickers. Circuit Studio does not request access to your contacts, location, microphone or camera."),
        ("Support", "Support correspondence is voluntary and separate from app usage. Avoid including confidential circuit data unless you intend to share it with the developer.")
    ]
    static func url(for key: String) -> URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    static var license: String {
        Bundle.main.url(forResource: "ngspice-COPYING", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "ngspice is distributed under its bundled modified BSD license."
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Circuit Studio · Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(AppPrivacy.sections, id: \.0) { title, text in
                        VStack(alignment: .leading, spacing: 7) { Text(title).font(.headline); Text(text).font(.body).foregroundStyle(.secondary) }
                    }
                    if let url = AppPrivacy.url(for: "CSPrivacyPolicyURL") { Link("Privacy policy on the web", destination: url) }
                    if let url = AppPrivacy.url(for: "CSSupportURL") { Link("Contact and support", destination: url) }
                    DisclosureGroup("ngspice acknowledgements") { Text(AppPrivacy.license).font(.footnote).textSelection(.enabled) }
                }.frame(maxWidth: 640, alignment: .leading).padding(24)
            }.navigationTitle("Privacy policy")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 600, height: 560)
        #endif
    }
}
