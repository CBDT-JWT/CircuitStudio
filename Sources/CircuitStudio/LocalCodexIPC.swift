#if os(macOS)
import Foundation

@objc protocol LocalCodexIPC {
    func send(_ message: Data, reply: @escaping (String?) -> Void)
    func receive(reply: @escaping (Data?, String?) -> Void)
}

enum LocalCodexIPCService {
    static let name = "com.circuitstudio.app.CodexBridge"
}
#endif
