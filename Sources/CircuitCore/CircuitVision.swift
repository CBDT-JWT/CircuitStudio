import Foundation
import CoreGraphics
import CoreML
import Vision
import ImageIO

public struct CircuitSymbolDetection: Identifiable, Sendable {
    public let id: UUID
    public let kind: ComponentKind
    public let confidence: Float
    /// Normalized image coordinates, top-left origin.
    public let bounds: CGRect
}
public struct CircuitTextDetection: Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let confidence: Float
    public let bounds: CGRect
}
public struct CircuitVisionResult: Sendable {
    public let symbols: [CircuitSymbolDetection]
    public let texts: [CircuitTextDetection]
    public let image: CGImage
}

/// This experimental detector finds symbols and text, not electrical topology.
/// Keeping it read-only prevents unverified wiring/values entering a document.
public enum CircuitVision {
    public static let confidenceThreshold: Float = 0.35
    public static func recognize(_ imageData: Data, modelURL: URL) throws -> CircuitVisionResult {
        try Task.checkCancellation()
        let image = try previewImage(imageData)
        let compiledURL: URL
        let temporary: Bool
        if modelURL.pathExtension == "mlmodelc" { compiledURL = modelURL; temporary = false }
        else { compiledURL = try MLModel.compileModel(at: modelURL); temporary = true }
        defer { if temporary { try? FileManager.default.removeItem(at: compiledURL) } }
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
        let model = try VNCoreMLModel(for: MLModel(contentsOf: compiledURL, configuration: configuration))
        let symbolsRequest = VNCoreMLRequest(model: model)
        symbolsRequest.imageCropAndScaleOption = .scaleFill
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate; textRequest.usesLanguageCorrection = false
        textRequest.recognitionLanguages = ["en-US", "zh-Hans"]
        textRequest.minimumTextHeight = 0.005
        try Task.checkCancellation()
        try VNImageRequestHandler(cgImage: image).perform([symbolsRequest, textRequest])
        try Task.checkCancellation()
        guard let observations = symbolsRequest.results as? [VNRecognizedObjectObservation] else { throw CircuitError.message("This model must output labeled object bounding boxes.") }
        let candidates = observations.compactMap { observation -> CircuitSymbolDetection? in
            guard let label = observation.labels.first, label.confidence >= confidenceThreshold, let kind = ComponentKind(rawValue: label.identifier) else { return nil }
            return CircuitSymbolDetection(id: UUID(), kind: kind, confidence: label.confidence, bounds: topLeft(observation.boundingBox))
        }
        let symbols = suppressOverlaps(candidates).sorted { $0.bounds.minY == $1.bounds.minY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.minY < $1.bounds.minY }
        let texts = (textRequest.results ?? []).compactMap { observation -> CircuitTextDetection? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return CircuitTextDetection(id: UUID(), text: candidate.string, confidence: candidate.confidence, bounds: topLeft(observation.boundingBox))
        }
        return CircuitVisionResult(symbols: symbols, texts: texts, image: image)
    }
    public static func previewImage(_ data: Data) throws -> CGImage {
        guard data.count <= 25_000_000 else { throw CircuitError.message("Choose an image smaller than 25 MB.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw CircuitError.message("Could not read this image. Use a PNG, JPEG, or HEIC image.") }
        return image
    }
    public static func topLeft(_ bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX, y: 1 - bounds.maxY, width: bounds.width, height: bounds.height)
    }
    /// The exported detector performs per-class NMS. Remove competing labels for
    /// the same glyph as well, keeping the strongest candidate across classes.
    public static func suppressOverlaps(_ candidates: [CircuitSymbolDetection]) -> [CircuitSymbolDetection] {
        var selected: [CircuitSymbolDetection] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            guard candidate.bounds.width > 0, candidate.bounds.height > 0 else { continue }
            let duplicate = selected.contains { previous in
                let intersection = previous.bounds.intersection(candidate.bounds)
                guard !intersection.isNull else { return false }
                let area = intersection.width * intersection.height
                let union = previous.bounds.width * previous.bounds.height + candidate.bounds.width * candidate.bounds.height - area
                return area / max(1e-9, union) > 0.45
            }
            if !duplicate { selected.append(candidate) }
        }
        return selected
    }
}
