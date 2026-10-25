import SwiftUI

enum AppPrivacy {
    static let sections: [(String, String)] = [
        ("No tracking", "Drawing and simulation do not require an app account. Circuit Studio does not include advertising or analytics, or track you across apps and websites."),
        ("Software updates", "The direct-download Mac build checks a signed GitHub release feed and downloads signed updates. It does not send circuit documents or simulation results. Automatic checking can be disabled in settings. Sparkle system profiling is disabled."),
        ("Your documents", "Circuit diagrams, figures, labels, models and previews are stored in the files you create. If you save them in iCloud Drive, Apple handles storage and synchronization under your Apple account and settings. Choosing a cloud AI feature sends the selected circuit context or image as described below."),
        ("Local simulation", "SPICE analyses run on your device using the bundled ngspice engine. Circuit data and simulation results are not sent to a remote simulation service."),
        ("AI features", "Offline symbol recognition and OCR process selected images on your device. CircuitAI sends the current circuit, relevant waveform data, messages and selected images through the developer relay to DeepSeek after your consent. Successful replies and tool arguments are cached to prevent duplicate requests; entries older than 24 hours are removed when further requests are processed. Replies may repeat information from the circuit. DeepSeek handles submitted content under its own privacy practices."),
        ("Subscriptions and offer codes", "App Store purchases and offer-code redemption are handled by Apple. The service verifies signed subscription transactions with Apple and stores subscription identifiers and usage counters. The developer does not receive your payment-card details. Offer codes are generated and managed by the developer in App Store Connect."),
        ("Export and sharing", "You choose when and where to export or share. CircuitikZ exports include editable circuit data for re-import. Files shared with another app or service are handled according to that recipient's privacy practices."),
        ("Settings and file access", "Appearance preferences are stored locally. File access is granted through system document pickers. Circuit Studio does not request access to your contacts, location, microphone or camera."),
        ("Support", "Support correspondence is voluntary and separate from app usage. Avoid including confidential circuit data unless you intend to share it with the developer.")
    ]
    static func url(for key: String) -> URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    static var sparkleLicense: String { Bundle.main.url(forResource: "Sparkle-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Sparkle is distributed under its bundled MIT license." }
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
                    DisclosureGroup("Fonts, Markdown and public model notices") {
                        Text("Metropolis fonts: Unlicense. Markdown-it and KaTeX: MIT. GF180MCU and SKY130 public model packets: Apache-2.0. Their license files and source notices are included with the app. The editor and schematic symbols are independently implemented for Circuit Studio.").font(.footnote).textSelection(.enabled)
                    }
                    DisclosureGroup("ngspice acknowledgements") { Text(AppPrivacy.license).font(.footnote).textSelection(.enabled) }; DisclosureGroup("Sparkle acknowledgements") { Text(AppPrivacy.sparkleLicense).font(.footnote).textSelection(.enabled) }
                }.frame(maxWidth: 640, alignment: .leading).padding(24)
            }.navigationTitle("Privacy policy")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 600, height: 560)
        #endif
    }
}
