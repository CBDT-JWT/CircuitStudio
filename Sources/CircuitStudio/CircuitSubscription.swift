import SwiftUI
import StoreKit
import Observation

@MainActor @Observable final class CircuitSubscription {
    var signedTransaction: String?
    var checking = false
    var error: String?
    var productIDs: [String] { Bundle.main.object(forInfoDictionaryKey: "CircuitAIProductIDs") as? [String] ?? [] }
    var serviceURL: String {
        let configured = Bundle.main.object(forInfoDictionaryKey:"CircuitAIServiceURL") as? String ?? ""
        return configured.isEmpty ? RelayCredentials.defaultEndpoint : configured
    }
    var privateRelay = false
    #if DEBUG
    private var privateRelayToken=""
    #endif
    var canRequest: Bool {
        #if DEBUG
        privateRelay || signedTransaction != nil
        #else
        signedTransaction != nil
        #endif
    }
    var isConfigured: Bool { !serviceURL.isEmpty && !productIDs.isEmpty }
    var monthlyPrice = ""
    var activationStatus = ""
    var activating = false
    func refreshRelay() {
        #if DEBUG
        Task { await activatePrivateRelay() }
        #endif
    }

    #if DEBUG
    func activatePrivateRelay() async {
        activating = true; defer { activating = false }
        let token=await Task.detached { RelayCredentials.token }.value
        privateRelayToken=token;privateRelay = !token.isEmpty
        guard privateRelay else { return }
        do {
            var request = URLRequest(url:URL(string:RelayCredentials.endpoint)!.appendingPathComponent("entitlement"))
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
            let (data,response) = try await URLSession.shared.data(for:request)
            guard let http=response as? HTTPURLResponse,http.statusCode == 200 else {
                throw CircuitError.message("服务器访问码未通过验证，请在服务设置中重新连接。")
            }
            struct Entitlement:Decodable { var active:Bool;var remaining:Int }
            let result=try JSONDecoder().decode(Entitlement.self,from:data)
            guard result.active else { throw CircuitError.message("服务器访问码已停用。") }
            activationStatus="已连接你的服务器";error=nil
        } catch { activationStatus="服务器连接失败";self.error=error.localizedDescription }
    }
    #endif

    func refresh() async {
        guard !serviceURL.isEmpty && !productIDs.isEmpty else { signedTransaction = nil; return }
        checking = true
        defer { checking = false }
        var evidence: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID), transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil, let expiration = transaction.expirationDate, expiration > Date() else { continue }
            evidence = result.jwsRepresentation
        }
        if !Task.isCancelled {
            signedTransaction = evidence
            if evidence != nil { await activate() } else { activationStatus = "" }
        }
    }
    func watch() async {
        #if DEBUG
        await activatePrivateRelay()
        if privateRelay { return }
        #endif
        guard !serviceURL.isEmpty && !productIDs.isEmpty else { return }
        do {
            let products = try await Product.products(for:productIDs)
            monthlyPrice = products.first?.displayPrice ?? ""
        } catch { self.error = "订阅商品暂时无法加载，请稍后重试。" }
        await refresh()
        for await result in Transaction.updates {
            if Task.isCancelled { return }
            guard case .verified(let transaction) = result, productIDs.contains(transaction.productID) else { continue }
            await refresh()
            await transaction.finish()
        }
    }
    func activate() async {
        guard let signedTransaction else { return }
        activating = true; defer { activating = false }
        do {
            var request = URLRequest(url: URL(string:serviceURL)!.appendingPathComponent("entitlement"))
            request.timeoutInterval = 60
            request.setValue("StoreKit \(signedTransaction)",forHTTPHeaderField:"Authorization")
            let (data,response) = try await URLSession.shared.data(for:request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                struct Failure: Decodable { var error: String }
                throw CircuitError.message((try? JSONDecoder().decode(Failure.self,from:data).error) ?? "订阅已购买，服务连接暂不可用，请稍后重试。")
            }
            struct Entitlement: Decodable { var active: Bool; var remaining: Int }
            let result = try JSONDecoder().decode(Entitlement.self,from:data)
            guard result.active else { throw CircuitError.message("订阅尚未生效，请恢复购买。") }
            activationStatus = "已自动连接"; error = nil
        } catch { activationStatus = "等待连接"; self.error = error.localizedDescription }
    }
    func restore() async {
        do { error = nil; try await AppStore.sync(); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func configuration() throws -> CircuitAIConfiguration {
        #if DEBUG
        if privateRelay { return CircuitAIConfiguration(endpoint:RelayCredentials.endpoint,accessToken:privateRelayToken) }
        #endif
        guard isConfigured else { throw CircuitError.message("AI subscriptions are not configured in this build.") }
        guard let signedTransaction else { throw CircuitError.message("An active AI subscription is required.") }
        return CircuitAIConfiguration(endpoint: serviceURL, signedTransaction: signedTransaction)
    }
}
