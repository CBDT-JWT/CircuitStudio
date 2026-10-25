import SwiftUI
import StoreKit
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct CircuitAssistantView: View {
    @Bindable var store: EditorStore
    var initialImage: Data? = nil
    var externalContext: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Explain"
    @State private var language = "中文"
    @State private var subscription = CircuitSubscription()
    @State private var subscriptionSheet = false
    @State private var redeemSheet = false
    @State private var relaySheet = false
    @State private var question = "请解读这个电路的功能、信号路径及主要元件的作用，说明假设，并建议需要运行的仿真。"
    @State private var answer = ""
    @State private var error: String?
    @State private var isExplaining = false
    @State private var explanationTask: Task<Void, Never>?
    @State private var importing = false
    @State private var visionResult: CircuitVisionResult?
    @State private var isRecognizing = false
    @State private var visionTask: Task<Void, Never>?
    @State private var cloudAnswer = ""
    @State private var cloudTask: Task<Void, Never>?
    @State private var isCloudRecognizing = false
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

    private var modelURL: URL? { Bundle.main.url(forResource: "CircuitSymbols", withExtension: "mlmodelc") }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if initialImage != nil && subscription.isConfigured {
                        Picker("Assistant task", selection: $tab) { Text("Explain").tag("Explain"); Text("Recognize image").tag("Recognize") }.pickerStyle(.segmented)
                    }
                    if initialImage == nil || (subscription.isConfigured && tab == "Explain") { explanationContent } else { recognitionContent }
                    if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(20)
            }.navigationTitle("Circuit assistant")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 640, minHeight: 540)
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 25_000_000 else { throw CircuitError.message("Choose an image smaller than 25 MB.") }
                recognize(try Data(contentsOf: url))
            } catch { self.error = error.localizedDescription }
        }
        #if os(iOS)
        .onChange(of: photo) { _, item in
            cloudTask?.cancel(); isCloudRecognizing = false; cloudAnswer = ""
            visionTask?.cancel(); visionResult = nil; error = nil
            guard let item else { isRecognizing = false; return }
            isRecognizing = true
            visionTask = Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw CircuitError.message("Could not load this photo.") }
                    try Task.checkCancellation()
                    await performRecognition(data)
                } catch { if !Task.isCancelled { self.error = error.localizedDescription; isRecognizing = false } }
            }
        }
        #endif
        .onChange(of: store.circuit) { _, _ in explanationTask?.cancel(); isExplaining = false; answer = "" }
        .task { await subscription.watch() }
        .task { if let initialImage { tab = "Recognize"; recognize(initialImage) } }
        .offerCodeRedemption(isPresented: $redeemSheet) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
            Task { await subscription.refresh() }
        }
        .sheet(isPresented: $relaySheet) { RelaySettingsView(saved: { subscription.refreshRelay() }) }
        .sheet(isPresented: $subscriptionSheet) {
            SubscriptionStoreView(productIDs: subscription.productIDs)
                .subscriptionStorePolicyDestination(url: URL(string: "https://www.weitao-jiang.cn/static/circuit-studio/privacy.html")!, for: .privacyPolicy)
                .subscriptionStorePolicyDestination(url: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!, for: .termsOfService)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { subscriptionSheet = false } } }
                .onInAppPurchaseCompletion { _, result in
                    if case .success(.success(let verification)) = result, case .verified(let transaction) = verification {
                        await subscription.refresh(); await transaction.finish(); subscriptionSheet = false
                    } else if case .success(.pending) = result { subscription.activationStatus = "购买等待 Apple 批准" }
                    else if case .failure(let error) = result { subscription.error = error.localizedDescription }
                }
                .onDisappear { Task { await subscription.refresh() } }
        }
        .onDisappear { explanationTask?.cancel(); visionTask?.cancel(); cloudTask?.cancel() }
    }

    private var explanationContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Explain the circuit on your canvas").font(.headline)
            Text("Uses component values and actual pin connections. CircuitAI explanations are relayed through your configured server.").font(.callout).foregroundStyle(.secondary)
            subscriptionContent
            Text("Tap Explain to send this circuit's connections, parameters, and your question to the service. The server applies the access code's call allowance.").font(.caption).foregroundStyle(.secondary)
            Picker("Answer language", selection: $language) { Text("中文").tag("中文"); Text("English").tag("English") }.pickerStyle(.segmented)
            TextField("Ask about this circuit", text: $question, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
            Button(action: explain) { if isExplaining { Label("Explaining…", systemImage: "hourglass") } else { Label("Explain circuit", systemImage: "sparkles") } }
                .buttonStyle(.borderedProminent).disabled(isExplaining || !subscription.canRequest || !subscription.isConfigured || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.circuit.components.isEmpty || !store.supportsSimulation)
            if isExplaining { ProgressView() }
            if !answer.isEmpty { Text(answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Text("AI explanations can contain errors. Numerical results require a simulation; this answer does not run one.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var recognitionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Offline symbol recognition · Experimental").font(.headline)
            Text("Choose a cropped, clear schematic. The small model locates symbols; OCR reads labels separately. It has been trained on synthetic native symbols.").font(.callout).foregroundStyle(.secondary)
            Text("Wires, pin roles, rotation, and the association of values to components are not reconstructed. Results are a preview and do not change your circuit.").font(.callout).foregroundStyle(.secondary)
            if modelURL == nil { Label("The experimental detector is not bundled with this build.", systemImage: "info.circle") }
            HStack {
                Button { importing = true } label: { Label("Choose image…", systemImage: "photo") }
                #if os(iOS)
                PhotosPicker(selection: $photo, matching: .images) { Label("Photo library", systemImage: "photo.on.rectangle") }
                #endif
            }.buttonStyle(.bordered).disabled(isRecognizing || modelURL == nil)
            if isRecognizing { ProgressView("Recognizing on this device…") }
            if let result = visionResult {
                CircuitRecognitionPreview(result: result)
                Text("\(result.symbols.count) symbol candidates · \(result.texts.count) text regions").font(.headline)
                if result.symbols.isEmpty { Text("No symbols passed the confidence threshold. Try a tighter crop or a clearer image.").foregroundStyle(.secondary) }
                ForEach(result.symbols) { symbol in HStack { Text(symbol.kind.title); Spacer(); Text(symbol.confidence, format: .percent.precision(.fractionLength(0))).monospacedDigit() } }
                if !result.texts.isEmpty {
                    Divider(); Text("Recognized text").font(.headline)
                    ForEach(result.texts) { text in Text(text.text).textSelection(.enabled) }
                }
                if subscription.isConfigured {
                    Divider()
                    subscriptionContent
                    Text("Cloud recognition sends this image to CircuitAI for an explanation and suggested connections. Review all inferred connections before drawing or simulating them.").font(.caption).foregroundStyle(.secondary)
                    Button(action: recognizeCloud) { Label(isCloudRecognizing ? "Analyzing image…" : "Analyze image with CircuitAI", systemImage: "cloud") }
                        .buttonStyle(.borderedProminent).disabled(isCloudRecognizing || !subscription.canRequest)
                    if isCloudRecognizing { ProgressView() }
                    if !cloudAnswer.isEmpty { Text(cloudAnswer).textSelection(.enabled) }
                }
            }
        }
    }

    private func explain() {
        error = nil; answer = ""
        do {
            let context = try externalContext ?? CircuitAssistantContext.make(store.circuit)
            let input = question, outputLanguage = language
            let configuration = try subscription.configuration()
            _ = try CircuitAIService.makeRequest(context: context, question: input, language: outputLanguage, configuration: configuration)
            isExplaining = true
            explanationTask = Task {
                defer { if !Task.isCancelled { isExplaining = false } }
                do {
                    let response = try await CircuitAIService.ask(context: context, question: input, language: outputLanguage, configuration: configuration)
                    try Task.checkCancellation()
                    answer = response
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private var subscriptionContent: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("AI 电路解读 · 订阅后即可使用电路助手").font(.subheadline.weight(.medium))
            Text("订阅后自动连接，支持恢复购买；取消续订后可用至本期结束。价格以 App Store 购买页面为准。").font(.caption).foregroundStyle(.secondary)
            if subscription.checking || subscription.activating { ProgressView("正在验证订阅并连接…") }
            if !subscription.activationStatus.isEmpty { Text(subscription.activationStatus).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(subscription.signedTransaction == nil ? (subscription.monthlyPrice.isEmpty ? "查看 AI 月度订阅" : "订阅 AI · \(subscription.monthlyPrice) / 月") : "管理订阅") { subscriptionSheet = true }
                Button("恢复购买") { Task { await subscription.restore() } }.disabled(subscription.checking)
                Button("兑换优惠码") { redeemSheet = true }
            }
            if let error = subscription.error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("重新连接") { Task { await subscription.refresh() } }
            }
            #if DEBUG
            Button("开发者服务设置") { relaySheet = true }.font(.caption)
            #endif
        }
    }
    private func recognizeCloud() {
        error = nil; cloudAnswer = ""
        do {
            guard let result = visionResult else { return }
            let configuration = try subscription.configuration()
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { throw CircuitError.message("Could not prepare the image.") }
            CGImageDestinationAddImage(destination, result.image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CircuitError.message("Could not prepare the image.") }
            let imageBase64 = (data as Data).base64EncodedString(), outputLanguage = language
            isCloudRecognizing = true
            cloudTask = Task {
                defer { if !Task.isCancelled { isCloudRecognizing = false } }
                do {
                    let response = try await CircuitAIService.ask(imageBase64: imageBase64, question: "Identify the circuit's components, visible values, and likely function. Describe connections you can actually trace; flag unclear junctions, crossing wires, polarity, and pin roles. Do not invent missing values. No simulation has been run.", language: outputLanguage, configuration: configuration)
                    try Task.checkCancellation(); cloudAnswer = response
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func recognize(_ data: Data) {
        cloudTask?.cancel(); isCloudRecognizing = false; cloudAnswer = ""
        visionTask?.cancel(); visionResult = nil; error = nil; isRecognizing = true
        visionTask = Task { await performRecognition(data) }
    }
    private func performRecognition(_ data: Data) async {
        defer { if !Task.isCancelled { isRecognizing = false } }
        guard let modelURL else { error = "The detector is unavailable in this build."; return }
        do {
            let worker = Task.detached(priority: .userInitiated) { try CircuitVision.recognize(data, modelURL: modelURL) }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            visionResult = result
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct CircuitRecognitionPreview: View {
    let result: CircuitVisionResult
    var body: some View {
        Image(decorative: result.image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ForEach(result.symbols) { symbol in
                        Rectangle().stroke(Color.orange, lineWidth: 2)
                            .frame(width: symbol.bounds.width * proxy.size.width, height: symbol.bounds.height * proxy.size.height)
                            .position(x: symbol.bounds.midX * proxy.size.width, y: symbol.bounds.midY * proxy.size.height)
                    }
                }
            }
            .accessibilityLabel("Schematic image with \(result.symbols.count) candidate symbols highlighted")
    }
}
