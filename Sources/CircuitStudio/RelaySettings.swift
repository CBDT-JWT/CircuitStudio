import SwiftUI
import Security

enum RelayCredentials {
    static let defaultEndpoint = "https://www.weitao-jiang.cn/api/circuit-ai/"
    static var endpoint: String { UserDefaults.standard.string(forKey:"CircuitRelayEndpoint") ?? defaultEndpoint }
    static var hasToken:Bool {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.circuitstudio.relay",kSecAttrAccount as String:endpoint,kSecMatchLimit as String:kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary,nil)==errSecSuccess
    }
    static var token: String {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.circuitstudio.relay",kSecAttrAccount as String:endpoint,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data:data,encoding:.utf8) ?? ""
    }
    static func save(endpoint: String, token: String) throws {
        _ = try CircuitAIService.makeRequest(context:"{}",question:"Check",language:"English",configuration:.init(endpoint:endpoint,accessToken:token))
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.circuitstudio.relay",kSecAttrAccount as String:endpoint]
        let attributes: [String:Any] = [kSecValueData as String:Data(token.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _,new in new } as CFDictionary,nil) == errSecSuccess else { throw CircuitError.message("无法将访问码保存到系统钥匙串。") }
        } else if status != errSecSuccess { throw CircuitError.message("无法更新系统钥匙串中的访问码。") }
        UserDefaults.standard.set(endpoint,forKey:"CircuitRelayEndpoint")
    }
    static func remove() {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.circuitstudio.relay",kSecAttrAccount as String:endpoint]
        SecItemDelete(query as CFDictionary)
    }
}

struct RelaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = RelayCredentials.endpoint
    @State private var token = ""
    @State private var error: String?
    @State private var status = ""
    @State private var checking = false
    var saved: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("CircuitAI 电路解读") {
                    Text("填写服务地址和管理员提供的 App 访问码。CircuitAI API Key 由管理员保存在服务器后台。").font(.callout)
                    TextField("服务地址",text:$endpoint).autocorrectionDisabled()
                    SecureField("App 访问码",text:$token).autocorrectionDisabled()
                    if RelayCredentials.hasToken { Text("此设备已保存访问码。留空可继续使用。").font(.caption).foregroundStyle(.secondary) }
                    Button(checking ? "正在检查…" : "保存并检查连接") { save() }.disabled(checking)
                    if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Link("打开管理后台",destination:URL(string:RelayCredentials.defaultEndpoint+"admin")!)
                    Button("移除此设备访问码",role:.destructive) { RelayCredentials.remove(); saved(); dismiss() }
                }
            }.formStyle(.grouped).navigationTitle("AI 服务设置")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.frame(minWidth:380,minHeight:400)
    }
    private func save() {
        error = nil; status = ""
        let endpoint = endpoint.trimmingCharacters(in:.whitespacesAndNewlines)
        let access = token.isEmpty && endpoint == RelayCredentials.endpoint ? RelayCredentials.token : token.trimmingCharacters(in:.whitespacesAndNewlines)
        do {
            _ = try CircuitAIService.makeRequest(context:"{}",question:"Check",language:"English",configuration:.init(endpoint:endpoint,accessToken:access))
            checking = true
            Task {
                defer { checking = false }
                do {
                    var request = URLRequest(url:URL(string:endpoint)!.appendingPathComponent("entitlement")); request.timeoutInterval = 20
                    request.setValue("Bearer \(access)",forHTTPHeaderField:"Authorization")
                    let (_,response) = try await URLSession.shared.data(for:request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CircuitError.message("访问码未通过服务器验证，请检查后台设置。") }
                    try RelayCredentials.save(endpoint:endpoint,token:access);saved()
                    status = "已连接，访问码有效。"
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
