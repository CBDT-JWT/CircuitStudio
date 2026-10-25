import Foundation
import Testing
import CoreGraphics
import CoreVideo
import ImageIO
@testable import CircuitCore

private let handwritingRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let handwritingModel: Result<CircuitHandwritingRecognizer, Error> = Result {
    let override = ProcessInfo.processInfo.environment["CIRCUIT_HANDWRITING_TEST_MODEL"].map { URL(fileURLWithPath: $0) }
    return try CircuitHandwritingRecognizer(modelURL: override ?? handwritingRoot.appendingPathComponent("Resources/Models/CircuitHandwriting.mlmodel"))
}

@Test func handwritingNetworkRejectsWireAndUnknownLabels() throws {
    let model = try handwritingModel.get()
    let line = [CircuitInkStroke([Point(0, 0), Point(80, 0)])]
    let prediction = try model.classify(line)
    #expect(!prediction.accepted)
    #expect(try model.recognize(line).components.isEmpty)
    #expect(CircuitHandwritingRecognizer.kind(for: "other", preferredMOS: .pmos) == nil)
    #expect(CircuitHandwritingRecognizer.kind(for: "unknown", preferredMOS: nil) == nil)
    #expect(CircuitHandwritingRecognizer.kind(for: "mos", preferredMOS: .pmos) == .pmos)
    #expect(CircuitHandwritingRecognizer.kind(for: "mos", preferredMOS: nil) == .nmos)
}

@Test func handwritingNetworkConvertsSeveralSymbolsAndRetainsInputIndices() throws {
    let model = try handwritingModel.get()
    let resistor = CircuitInkStroke([Point(0, 0), Point(15, 0), Point(20, -8), Point(28, 8), Point(36, -8), Point(44, 8), Point(52, -8), Point(60, 8), Point(65, 0), Point(80, 0)])
    let mos = [CircuitInkStroke([Point(160, -20), Point(160, 20)]), CircuitInkStroke([Point(130, 0), Point(160, 0)]), CircuitInkStroke([Point(173, -22), Point(173, 22)]), CircuitInkStroke([Point(173, -20), Point(188, -20), Point(188, -40)]), CircuitInkStroke([Point(173, 20), Point(188, 20), Point(188, 40)])]
    let capacitor = [CircuitInkStroke([Point(260, -8), Point(296, -8)]), CircuitInkStroke([Point(278, -36), Point(278, -8)]), CircuitInkStroke([Point(260, 8), Point(296, 8)]), CircuitInkStroke([Point(278, 8), Point(278, 36)])]
    let ink = [resistor] + mos + capacitor
    let result = try model.recognize(ink)
    #expect(result.components.map(\.kind) == [.resistor, .nmos, .capacitor])
    #expect(Set(result.components.flatMap(\.strokeIndices)) == Set(ink.indices))
    #expect(result.components.allSatisfy { $0.value.isEmpty })
    let pmos = try model.recognize(mos, preferredMOS: .pmos)
    #expect(pmos.components.map(\.kind) == [.pmos])
    #expect(pmos.components[0].anchors.keys.sorted() == ["D", "G", "S"])
}

@Test func handwritingNetworkRejectsMalformedCoordinates() throws {
    let model = try handwritingModel.get()
    #expect(throws: CircuitError.self) { try model.recognize([CircuitInkStroke([Point(.nan, 0)])]) }
    #expect(throws: CircuitError.self) { try model.recognize(Array(repeating: CircuitInkStroke([]), count: 501)) }
    #expect(try model.recognize([]).components.isEmpty)
}

@Test func neuralMOSRecognitionSurvivesDirectionScaleAndHandwritingSlant() throws {
    let model = try handwritingModel.get()
    let paths = [[Point(-15, -20), Point(-15, 20)], [Point(-40, 0), Point(-15, 0)], [Point(0, -22), Point(0, 22)], [Point(0, -20), Point(15, -20), Point(15, -40)], [Point(0, 20), Point(15, 20), Point(15, 40)]]
    for rotation in [0, 90, 180, 270] {
        for slant in [-12.0, 0, 12] {
            for scale in [0.65, 1, 1.8] {
                let angle = (Double(rotation) + slant) * .pi / 180
                let ink = paths.map { path in CircuitInkStroke(path.map { p in Point(300 + (p.x * cos(angle) - p.y * sin(angle)) * scale, 200 + (p.x * sin(angle) + p.y * cos(angle)) * scale) }) }
                let result = try model.recognize(ink)
                #expect(result.components.map(\.kind) == [.nmos], "rotation=\(rotation), slant=\(slant), scale=\(scale)")
            }
        }
    }
}

@Test func partlyErasedStrokeKeepsItsUnrecognizedVisibleRanges() {
    #expect(CircuitInkResult.completeStrokeOrigins([0, 0, 1], consuming: [0, 2]) == nil)
    #expect(CircuitInkResult.completeStrokeOrigins([0, 0, 1], consuming: [0, 1, 2]) == [0, 1])
    #expect(CircuitInkResult.completeStrokeOrigins([0, 0, 1], consuming: [2]) == [1])
    #expect(CircuitInkResult.completeStrokeOrigins([0], consuming: [1]) == nil)
}

private struct HandwritingFixture: Decodable { let file: String; let label: String; let source: String }

@Test func exportedHandwritingNetworkMatchesHeldOutWriterFixtures() throws {
    let model = try handwritingModel.get()
    let folder = try #require(Bundle.module.resourceURL).appendingPathComponent("Handwriting")
    let fixtures = try JSONDecoder().decode([HandwritingFixture].self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    var accepted = 0, correct = 0
    for fixture in fixtures {
        #expect(["drafter_15", "drafter_16", "drafter_17"].contains(fixture.source.components(separatedBy: "/")[0]))
        let source = try #require(CGImageSourceCreateWithURL(folder.appendingPathComponent(fixture.file) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 96, 96, kCVPixelFormatType_OneComponent8, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let prediction = try model.classify(pixelBuffer: pixels)
        if prediction.accepted { accepted += 1; if prediction.label == fixture.label { correct += 1 } }
    }
    #expect(accepted >= 10)
    #expect(Double(correct) / Double(max(1, accepted)) >= 0.9)
}
