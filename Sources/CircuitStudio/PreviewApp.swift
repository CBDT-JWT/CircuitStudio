import SwiftUI

// Compiled only for deterministic layout review; production uses DocumentGroup.
#if CIRCUITSTUDIO_PREVIEW
@main struct CircuitStudioPreviewApp: App {
    @State private var document = CircuitFile({
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--blank") { return Circuit() }
        if arguments.contains("--illustration") { return Circuit(purpose: .illustration) }
        if arguments.contains("--paper-system") { return PaperExample.system.make() }
        if arguments.contains("--paper-flow") { return PaperExample.flow.make() }
        if arguments.contains("--paper-device") { return PaperExample.device.make() }
        return CircuitTemplate.commonSource.make()
    }())
    var body: some Scene {
        WindowGroup {
            WorkspaceView(document: $document, fileURL: nil)
                .task {
                    #if os(macOS)
                    if let destination = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-marketing=") })?.split(separator: "=", maxSplits: 1).last {
                        try? await Task.sleep(for: .seconds(1.5))
                        captureMarketingScreenshot(String(destination))
                    }
                    #endif
                    #if os(iOS)
                    if ProcessInfo.processInfo.arguments.contains("--verify-spice") {
                        await verifyMobileSpice()
                    }
                    #endif
                }
        }.commands {
            StudioCommands()
            #if os(macOS)
            CommandGroup(after: .appInfo) {
                Button("Save store screenshot") { captureStoreScreenshot() }
            }
            #endif
        }
        #if os(macOS)
            .defaultSize(width: 1240, height: 800)
        #endif
    }
    #if os(macOS)
    @MainActor private func captureMarketingScreenshot(_ destination: String) {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let frameView = window.contentView?.superview else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1440, height: 900)), display: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            frameView.layoutSubtreeIfNeeded()
            guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: destination), options: .atomic) }
        }
    }
    @MainActor private func captureStoreScreenshot() {
        guard let window = NSApplication.shared.keyWindow, let frameView = window.contentView?.superview else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1280, height: 800)), display: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            frameView.layoutSubtreeIfNeeded()
            guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            guard let original = bitmap.cgImage,
                  let context = CGContext(data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            let rect = CGRect(x: 0, y: 0, width: 2560, height: 1600)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
            context.draw(original, in: rect)
            guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: "/tmp/circuitstudio-mac-store-capture.png"), options: .atomic)
        }
    }
    #endif
    #if os(iOS)
    private func verifyMobileSpice() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spice-verification.json")
        let data = await Task.detached(priority: .userInitiated) {
            var checks: [[String: Any]] = []
            for analysis in Analysis.allCases {
                do {
                    var circuit = CircuitTemplate.commonSource.make(); circuit.simulation.analysis = analysis
                    let result = try SimulationEngine.run(circuit)
                    guard let output = result.waveform("VOUT"), !output.values.isEmpty, output.values.count == result.axis.count else { throw CircuitError.message("Missing VOUT samples") }
                    if analysis == .op, (result.operatingPoints["M1"]?["gm"] ?? 0) <= 0 { throw CircuitError.message("Missing MOS operating point") }
                    checks.append(["analysis": analysis.rawValue, "passed": true, "samples": result.axis.count,
                                   "engine": result.engine, "firstReal": output.values[0].real,
                                   "firstImaginary": output.values[0].imaginary,
                                   "mosOperatingPoint": result.operatingPoints["M1"] ?? [:]])
                } catch { checks.append(["analysis": analysis.rawValue, "passed": false, "error": error.localizedDescription]) }
            }
            do {
                let result = try SimulationEngine.run(CircuitTemplate.rcFilter.make())
                guard let output = result.waveform("VOUT") else { throw CircuitError.message("Missing RC output") }
                for (frequency, value) in zip(result.axis, output.values) {
                    let expected = Complex(1) / Complex(1, 2 * .pi * frequency * 1e-4)
                    guard abs(value.real - expected.real) < 1e-9, abs(value.imaginary - expected.imaginary) < 1e-9 else { throw CircuitError.message("RC result differs from analytic transfer function") }
                }
                checks.append(["analysis": "RC analytic verification", "passed": true, "samples": result.axis.count])
            } catch { checks.append(["analysis": "RC analytic verification", "passed": false, "error": error.localizedDescription]) }
            do {
                var circuit = CircuitTemplate.inverter.make(); circuit.simulation.analysis = .dc
                let dc = try SimulationEngine.run(circuit)
                guard let output = dc.waveform("VOUT"), let first = output.values.first, let last = output.values.last, first.real > 1.79, last.real < 0.01 else { throw CircuitError.message("Inverter DC rails are incorrect") }
                checks.append(["analysis": "PMOS / NMOS inverter", "passed": true, "samples": dc.axis.count, "lowInputOutput": first.real, "highInputOutput": last.real])
            } catch { checks.append(["analysis": "PMOS / NMOS inverter", "passed": false, "error": error.localizedDescription]) }
            let report: [String: Any] = ["platform": "iOS", "allPassed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
            return (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        }.value
        try? data.write(to: url, options: .atomic)
    }
    #endif
}
#endif
