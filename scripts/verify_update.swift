import Foundation
import CryptoKit

// Verification uses only the public key embedded in the shipping application.
// Sparkle XML signs the first `length` bytes; its footer holds that signature.
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]) else {
    fail("Usage: verify_update.swift PUBLIC_KEY FILE [ARCHIVE_SIGNATURE]")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let bytes = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let signedBytes: Data
let signature: Data
if arguments.count == 4 {
    guard let value = Data(base64Encoded: arguments[3]) else { fail("Invalid archive signature") }
    signature = value
    signedBytes = bytes
} else {
    guard let text = String(data: bytes, encoding: .utf8),
          let footer = text.range(of: "<!-- sparkle-signatures:", options: .backwards) else {
        fail("Missing signed appcast footer")
    }
    let value = String(text[footer.lowerBound...])
    let pattern = #"^<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*$"#
    let expression = try NSRegularExpression(pattern: pattern)
    guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          let signatureRange = Range(match.range(at: 1), in: value),
          let lengthRange = Range(match.range(at: 2), in: value),
          let length = Int(value[lengthRange]),
          length == text[..<footer.lowerBound].utf8.count,
          let decoded = Data(base64Encoded: String(value[signatureRange])) else {
        fail("Malformed signed appcast footer or length")
    }
    signature = decoded
    signedBytes = bytes.prefix(length)
}
guard key.isValidSignature(signature, for: signedBytes) else { fail("Invalid Ed25519 signature") }
print("Verified Ed25519 signature:", URL(fileURLWithPath: arguments[2]).lastPathComponent)
