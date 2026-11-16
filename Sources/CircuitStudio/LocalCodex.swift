#if os(macOS)
import Foundation

/// Uses the Codex App Server already running on this Mac.
enum LocalCodex {
    private static let endpoint = URL(string: "ws://127.0.0.1:52419")!
    static let setupCommand = #"""
    (
      set -e
      export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
      cs_codex="$(command -v codex || true)"
      if [ -z "$cs_codex" ]; then
        cs_codex="/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
      fi
      if [ ! -x "$cs_codex" ]; then
        echo "请先安装 Codex CLI 并运行 codex login。"
        exit 1
      fi
      "$cs_codex" login status
      cs_work="$(mktemp -d -t circuitstudio-codex)"
      trap 'rmdir "$cs_work"' EXIT
      cd "$cs_work"
      cs_token="$(/usr/bin/openssl rand -hex 32)"
      cs_hash="$(printf '%s' "$cs_token" | /usr/bin/shasum -a 256 | cut -d ' ' -f 1)"
      printf '\nCircuit Studio 连接码：%s\n\n' "$cs_token"
      "$cs_codex" -c 'features.shell_tool=false' -c 'features.unified_exec=false' \
        -c 'features.hooks=false' -c 'features.memories=false' -c 'features.shell_snapshot=false' \
        -c 'features.apps=false' -c 'features.plugins=false' -c 'features.multi_agent=false' \
        -c 'features.multi_agent_v2=false' -c 'features.skill_mcp_dependency_install=false' \
        -c 'web_search="disabled"' \
        app-server --listen ws://127.0.0.1:52419 --ws-auth capability-token --ws-token-sha256 "$cs_hash"
    )
    """#

    static func validToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func check(token: String) async throws {
        try await connect(token: token, timeout: 8) { socket in
            let account = try await socket.request("account/read", ["refreshToken": false])
            guard account["account"] is [String: Any] else {
                throw CircuitError.message("本机 Codex 尚未登录。请在终端运行 codex login 后重新连接。")
            }
        }
    }

    static func respond(context: String, messages: [CircuitAIMessage], token: String) async throws -> CircuitAIMessage {
        guard let resource = Bundle.main.url(forResource: "codex-tools", withExtension: "json", subdirectory: "EngineeringEditor"),
              let contract = try JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any],
              let instructions = contract["instructions"] as? String,
              let tools = contract["tools"] as? [[String: Any]] else {
            throw CircuitError.message("无法读取 CircuitAI 电路工具定义。")
        }
        let toolNames = tools.compactMap { $0["name"] as? String }
        let input = try turnInput(context: context, messages: messages, tools: tools)
        let answer = try await connect(token: token, timeout: 180) { socket in
            let config = try await socket.request("config/read", ["includeLayers": false])
            guard let settings = config["config"] as? [String: Any] else {
                throw CircuitError.message("无法读取本机 Codex 的连接设置。")
            }
            // A blank map merges with the user's configuration. Explicitly disable each
            // configured connector for this ephemeral circuit session.
            let connectors = (settings["mcp_servers"] as? [String: Any])?.keys.map { $0 } ?? []
            let disabledConnectors = Dictionary(uniqueKeysWithValues: connectors.map { ($0, ["enabled": false]) })
            let result = try await socket.request("thread/start", [
                "config": ["mcp_servers": disabledConnectors],
                "ephemeral": true, "approvalPolicy": "never", "sandbox": "read-only",
                "developerInstructions": instructions + """

                The messages field is the conversation transcript. Use its latest user request and tool receipts.
                To invoke an editor tool, return one tool name and its arguments as a JSON object encoded in the arguments string. For a final answer set tool to an empty string and arguments to "{}". Put Markdown in answer. Do not use other tools.
                """
            ])
            guard let thread = result["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
                throw CircuitError.message("Codex 未能创建对话。")
            }
            return try await socket.turn(threadID: threadID, input: input, toolNames: toolNames)
        }
        return try decode(answer, toolNames: Set(toolNames))
    }

    private static func turnInput(context: String, messages: [CircuitAIMessage], tools: [[String: Any]]) throws -> [[String: Any]] {
        var images: [[String: String]] = []
        let transcript = messages.map { message in
            guard case .array(let parts)? = message.content else { return message }
            var row = message
            let text = parts.compactMap { part -> String? in
                guard case .object(let value) = part else { return nil }
                if value["type"]?.string == "text" { return value["text"]?.string }
                guard case .object(let image)? = value["image_url"], let url = image["url"]?.string,
                      url.hasPrefix("data:image/") else { return nil }
                images.append(["type": "image", "url": url])
                return "[附图 \(images.count)]"
            }
            row.content = .string(text.joined(separator: "\n"))
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "circuit": context, "tools": tools,
            "messages": JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript))
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count + images.reduce(0, { $0 + ($1["url"]?.utf8.count ?? 0) }) <= 7_000_000 else {
            throw CircuitError.message("对话中的电路或图片过大，请减少附件后重试。")
        }
        return [["type": "text", "text": String(decoding: data, as: UTF8.self)]] + images
    }

    static func decode(_ text: String, toolNames: Set<String>) throws -> CircuitAIMessage {
        struct Answer: Decodable { var answer: String; var tool: String; var arguments: String }
        guard let value = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8)) else {
            throw CircuitError.message("Codex 返回的回复格式无效，请重试。")
        }
        if value.tool.isEmpty, !value.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .init(role: "assistant", content: .string(value.answer))
        }
        guard toolNames.contains(value.tool), value.arguments.utf8.count <= 16_000,
              (try? JSONSerialization.jsonObject(with: Data(value.arguments.utf8))) is [String: Any] else {
            throw CircuitError.message("Codex 返回了无效的电路操作。")
        }
        let call = CircuitAIToolCall(id: UUID().uuidString, type: "function",
                                     function: .init(name: value.tool, arguments: value.arguments))
        return .init(role: "assistant", content: .string(value.answer), tool_calls: [call])
    }

    private static func connect<T>(
        token: String, timeout: TimeInterval, operation: (Socket) async throws -> T
    ) async throws -> T {
        guard validToken(token) else { throw CircuitError.message("请输入终端里显示的 64 位连接码。") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1_000_000
        task.resume()
        defer { session.invalidateAndCancel() }
        // URLSession's request timeout is not a deadline for an upgraded socket.
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            do {
                let socket = Socket(task: task)
                _ = try await socket.request("initialize", ["clientInfo": [
                    "name": "circuit_studio", "title": "Circuit Studio", "version": "1.3.8"
                ]])
                try await socket.send(["method": "initialized"])
                return try await operation(socket)
            } catch let error as CircuitError {
                throw error
            } catch {
                try Task.checkCancellation()
                throw CircuitError.message("连接本机 Codex 失败。请确认终端仍在运行、连接码有效，且 Codex CLI 已更新。")
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class Socket {
        let task: URLSessionWebSocketTask
        private var nextID = 0
        private var turnEvents: [[String: Any]] = []

        init(task: URLSessionWebSocketTask) { self.task = task }

        func send(_ value: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: value)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        }

        private func receive() async throws -> [String: Any] {
            try Task.checkCancellation()
            while true {
                let data: Data
                switch try await task.receive() {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: throw CircuitError.message("Codex 返回了未知的消息类型。")
                }
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // Server-initiated approvals and tool requests are outside this client contract.
                if event["method"] is String, let id = event["id"] {
                    try await send(["id": id, "error": ["code": -32601, "message": "Unsupported client request"]])
                } else {
                    return event
                }
            }
        }

        func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            nextID += 1
            let id = nextID
            try await send(["id": id, "method": method, "params": params])
            while true {
                let event = try await receive()
                if event["id"] as? Int == id {
                    if let result = event["result"] as? [String: Any] { return result }
                    let message = (event["error"] as? [String: Any])?["message"] as? String ?? "未知错误"
                    throw CircuitError.message("Codex：\(message.prefix(300))")
                }
                if let method = event["method"] as? String, ["item/completed", "turn/completed"].contains(method),
                   turnEvents.count < 64 {
                    turnEvents.append(event)
                }
            }
        }

        func turn(threadID: String, input: [[String: Any]], toolNames: [String]) async throws -> String {
            let schema: [String: Any] = [
                "type": "object", "additionalProperties": false, "required": ["answer", "tool", "arguments"],
                "properties": [
                    "answer": ["type": "string"],
                    "tool": ["type": "string", "enum": [""] + toolNames],
                    "arguments": ["type": "string"]
                ]
            ]
            let result = try await request("turn/start", ["threadId": threadID, "input": input, "outputSchema": schema])
            guard let turn = result["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
                throw CircuitError.message("Codex 未能开始处理消息。")
            }
            var answer = ""
            while true {
                let event: [String: Any]
                if turnEvents.isEmpty { event = try await receive() }
                else { event = turnEvents.removeFirst() }
                guard let params = event["params"] as? [String: Any], params["threadId"] as? String == threadID else { continue }
                switch event["method"] as? String {
                case "item/completed":
                    if params["turnId"] as? String == turnID, let item = params["item"] as? [String: Any],
                       item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                        answer = text
                    }
                case "turn/completed":
                    guard let done = params["turn"] as? [String: Any], done["id"] as? String == turnID else { continue }
                    guard done["status"] as? String == "completed", !answer.isEmpty else {
                        let message = (done["error"] as? [String: Any])?["message"] as? String ?? "任务未返回回复。"
                        throw CircuitError.message("Codex：\(message.prefix(300))")
                    }
                    return answer
                default: continue
                }
            }
        }
    }
}
#endif
