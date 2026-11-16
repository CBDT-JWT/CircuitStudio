import Darwin
import Foundation

/// Runs the installed CLI in the logged-in user's environment and relays JSONL over private XPC.
/// It never exposes a listening socket or supplies a shell to the client.
final class CodexProcess: NSObject, LocalCodexIPC, @unchecked Sendable {
    private struct Child {
        let process: Process
        let input: FileHandle
        let output: FileHandle
    }

    private let lock = NSLock()
    private let reads = DispatchQueue(label: "CircuitStudio.CodexBridge.read")
    private let writes = DispatchQueue(label: "CircuitStudio.CodexBridge.write")
    private var child: Child?
    private var stopped = false
    private var pending = Data()
    private let maxResponseBytes = 1_000_000

    func send(_ message: Data, reply: @escaping (String?) -> Void) {
        guard !message.isEmpty, message.count <= 8_000_000, !message.contains(10) else {
            reply("Codex 请求格式或大小无效。")
            return
        }
        let done = Reply(reply)
        writes.async {
            do {
                var line = message
                line.append(10)
                try self.startIfNeeded().input.write(contentsOf: line)
                done.value(nil)
            } catch {
                self.stop()
                done.value(error.localizedDescription)
            }
        }
    }

    func receive(reply: @escaping (Data?, String?) -> Void) {
        let done = Reply(reply)
        reads.async {
            do {
                guard let active = self.lock.withLock({ self.child }) else {
                    throw BridgeError("本机 Codex 已断开，请重新连接。")
                }
                var buffer = [UInt8](repeating: 0, count: 32_768)
                while true {
                    if let newline = self.pending.firstIndex(of: 10) {
                        let message = Data(self.pending[..<newline])
                        self.pending = Data(self.pending[(newline + 1)...])
                        guard message.count <= self.maxResponseBytes else { throw BridgeError("Codex 回复过大。") }
                        done.value(message, nil)
                        return
                    }
                    guard self.pending.count <= self.maxResponseBytes else { throw BridgeError("Codex 回复过大。") }
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(active.output.fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count == -1, errno == EINTR { continue }
                    guard count > 0 else {
                        throw BridgeError("本机 Codex 已结束。请更新 Codex，确认已登录后重试。")
                    }
                    self.pending.append(contentsOf: buffer.prefix(count))
                }
            } catch {
                self.stop()
                done.value(nil, error.localizedDescription)
            }
        }
    }

    func stop() {
        let active = lock.withLock {
            stopped = true
            let active = child
            child = nil
            return active
        }
        guard let active else { return }
        if active.process.isRunning { active.process.terminate() }
        // The child exits and closes the write end of stdout, waking any blocked read.
    }

    private func startIfNeeded() throws -> Child {
        try lock.withLock {
            if let child { return child }
            guard !stopped else { throw BridgeError("本机 Codex 已断开。") }
            let executable = try findCodex()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CircuitStudioCodex-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let input = Pipe()
            let output = Pipe()
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = [
                executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"
            ].joined(separator: ":")
            process.environment = environment
            let config = [
                "features.shell_tool=false", "features.unified_exec=false", "features.hooks=false",
                "features.memories=false", "features.shell_snapshot=false", "features.apps=false",
                "features.plugins=false", "features.multi_agent=false", "features.multi_agent_v2=false",
                "features.skill_mcp_dependency_install=false", "web_search=\"disabled\""
            ]
            process.arguments = config.flatMap { ["-c", $0] } + ["app-server", "--listen", "stdio://"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in try? FileManager.default.removeItem(at: directory) }
            do { try process.run() }
            catch {
                try? FileManager.default.removeItem(at: directory)
                throw BridgeError("无法启动本机 Codex，请确认安装完整。")
            }
            let launched = Child(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
            child = launched
            return launched
        }
    }

    private func findCodex() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundled = ["/Applications", home + "/Applications"].flatMap { applications in [
            applications + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            applications + "/Codex.app/Contents/Resources/codex",
            applications + "/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        ]}
        let candidates = bundled + [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let installed = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BridgeError("没有找到 Codex。请安装 Codex 桌面应用或 Codex CLI，然后重试。")
        }
        return URL(fileURLWithPath: installed)
    }
}

private struct BridgeError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

private struct Reply<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement("""
        anchor apple generic and identifier "com.circuitstudio.app" and certificate leaf[subject.OU] = "Q83556V27Y"
        """)
        let process = CodexProcess()
        connection.exportedInterface = NSXPCInterface(with: LocalCodexIPC.self)
        connection.exportedObject = process
        connection.invalidationHandler = { process.stop() }
        connection.interruptionHandler = { process.stop() }
        connection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
