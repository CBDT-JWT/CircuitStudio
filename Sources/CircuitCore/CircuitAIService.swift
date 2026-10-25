import Foundation

public struct CircuitAIConfiguration: Sendable {
    public var endpoint: String
    public var signedTransaction: String
    public var accessToken: String = ""
    public init(endpoint: String, signedTransaction: String) { self.endpoint = endpoint; self.signedTransaction = signedTransaction }
    public init(endpoint: String, accessToken: String) { self.endpoint = endpoint; self.signedTransaction = ""; self.accessToken = accessToken }
}

/// Requests go to the app owner's subscription gateway. The provider key and
/// model selection live on that server, never in the app or circuit document.
public enum CircuitAIService {
    public static func makeRequest(context: String?, imageBase64: String? = nil, question: String, language: String, configuration: CircuitAIConfiguration) throws -> URLRequest {
        let endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: endpoint), let host = base.host, !host.isEmpty,
              base.user == nil, base.password == nil, base.fragment == nil, base.query == nil else { throw CircuitError.message("The AI service URL is not configured correctly.") }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard base.scheme == "https" || (base.scheme == "http" && local) else { throw CircuitError.message("The AI service requires HTTPS.") }
        guard !configuration.signedTransaction.isEmpty || (!configuration.accessToken.isEmpty && configuration.accessToken.utf8.count <= 200 && !configuration.accessToken.contains(where: { $0.isWhitespace })) else { throw CircuitError.message("An active AI subscription is required.") }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 2_000 else { throw CircuitError.message("Enter a question of at most 2,000 UTF-8 bytes.") }
        var body: [String: Any] = ["question": question, "language": language]
        if let imageBase64 {
            guard imageBase64.utf8.count <= 5_000_000 else { throw CircuitError.message("Crop or resize this image before cloud recognition.") }
            body["imageBase64"] = imageBase64
        } else {
            guard let context else { throw CircuitError.message("Circuit data is required.") }
            body["context"] = context
        }
        var request = URLRequest(url: base.appendingPathComponent(imageBase64 == nil ? "explain" : "recognize"))
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.accessToken.isEmpty ? "StoreKit \(configuration.signedTransaction)" : "Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    public static func ask(context: String? = nil, imageBase64: String? = nil, question: String, language: String, configuration: CircuitAIConfiguration) async throws -> String {
        let request = try makeRequest(context: context, imageBase64: imageBase64, question: question, language: language, configuration: configuration)
        let settings = URLSessionConfiguration.ephemeral; settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CircuitError.message("The AI service returned an invalid response.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_000_000 else { throw CircuitError.message("The AI service response exceeded 1 MB.") }
            data.append(byte)
        }
        if !(200..<300).contains(response.statusCode) {
            struct Failure: Decodable { var error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "The AI service returned HTTP \(response.statusCode)."
            throw CircuitError.message(String(message.prefix(300)))
        }
        return try decodeResponse(data)
    }
    public static func decodeResponse(_ data: Data) throws -> String {
        struct Response: Decodable { let answer: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CircuitError.message("The AI service did not return a text answer.") }
        return response.answer
    }
}
