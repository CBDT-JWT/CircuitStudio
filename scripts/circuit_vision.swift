// Local dataset generation, Core ML training, and held-out evaluation.
// Compiled by scripts/circuit_vision.py; never included in the mobile app.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CreateML
import CoreML
import Vision

struct VisionBox: Codable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var rect: CGRect { CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height) }
}
struct VisionAnnotation: Codable { var label: String; var coordinates: VisionBox }
struct VisionSample: Codable { var image: String; var annotations: [VisionAnnotation] }

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    mutating func number(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
    mutating func integer(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
}

@main struct CircuitVisionTool {
    static let kinds: [ComponentKind] = [.resistor, .capacitor, .inductor, .voltageSource, .acVoltage, .pulseSource, .currentSource, .diode, .nmos, .pmos, .npn, .pnp, .opAmp, .ground, .vdd, .vss]
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw CircuitError.message("Usage: dataset DIRECTORY [COUNT] | train DIRECTORY MODEL [ITERATIONS] | evaluate DIRECTORY MODEL OUTPUT") }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        switch args[0] {
        case "dataset": try dataset(at: directory, count: args.count > 2 ? Int(args[2]) ?? 600 : 600)
        case "train":
            guard args.count >= 3 else { throw CircuitError.message("A model output path is required.") }
            let source = MLObjectDetector.DataSource.directoryWithImagesAndJsonAnnotation(at: directory.appendingPathComponent("train"))
            let validation = MLObjectDetector.DataSource.directoryWithImagesAndJsonAnnotation(at: directory.appendingPathComponent("validation"))
            let iterations = args.count > 3 ? Int(args[3]) ?? 400 : 400
            let parameters = MLObjectDetector.ModelParameters(validation: .dataSource(validation), batchSize: 16, maxIterations: iterations, algorithm: .transferLearning(.objectPrint(revision: 1)))
            let detector = try MLObjectDetector(trainingData: source, parameters: parameters, annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .center))
            let modelURL = URL(fileURLWithPath: args[2])
            try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try detector.write(to: modelURL, metadata: MLModelMetadata(author: "Circuit Studio", shortDescription: "Experimental circuit symbol detector. Synthetic native symbols only; no wire, pin, orientation, or value reconstruction.", version: "0.2"))
            print("Training metrics: \(detector.trainingMetrics)")
            print("Validation metrics: \(detector.validationMetrics)")
            print("Saved \(modelURL.path)")
        case "evaluate":
            guard args.count >= 4 else { throw CircuitError.message("Model and report paths are required.") }
            try evaluate(directory: directory, modelURL: URL(fileURLWithPath: args[2]), reportURL: URL(fileURLWithPath: args[3]))
        default: throw CircuitError.message("Unknown command: \(args[0])")
        }
    }

    static func dataset(at root: URL, count: Int) throws {
        guard count >= 60, count <= 20_000 else { throw CircuitError.message("Use 60–20,000 training images.") }
        guard !FileManager.default.fileExists(atPath: root.path) else { throw CircuitError.message("Dataset directory already exists. Choose another output directory.") }
        var random = SeededRandom(state: 20261007)
        for (split, amount) in [("train", count), ("validation", max(30, count / 5)), ("test", max(30, count / 5))] {
            let folder = root.appendingPathComponent(split)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var samples: [VisionSample] = []
            for i in 0..<amount {
                var circuit = Circuit(title: "Synthetic \(split) \(i)")
                circuit.theme = SymbolTheme.allCases[random.integer(0...3)]
                let cols = random.integer(2...4), rows = random.integer(1...3)
                let spacingX = random.number(110...170), spacingY = random.number(115...180)
                let width = Double(cols) * spacingX + 70, height = Double(rows) * spacingY + 70
                for row in 0..<rows { for col in 0..<cols {
                    if random.integer(0...9) == 0 { continue }
                    let kind = kinds[random.integer(0...(kinds.count - 1))]
                    let p = Point(80 + Double(col) * spacingX + random.number(-12...12), 75 + Double(row) * spacingY + random.number(-12...12))
                    _ = circuit.add(kind, at: p)
                    let j = circuit.components.count - 1
                    circuit.components[j].rotation = 90 * random.integer(0...3)
                    circuit.components[j].flipX = random.integer(0...1) == 1
                    circuit.components[j].showName = random.integer(0...3) != 0
                    circuit.components[j].showValue = random.integer(0...2) == 0
                    // Continue pin leads beyond the annotated symbol; vary surrounding wires.
                    for pin in circuit.components[j].pins where random.integer(0...3) != 0 {
                        let start = circuit.components[j].world(pin.offset)
                        let direction = (start - p) * (1 / max(1, start.distance(to: p)))
                        let end = start + (direction == .zero ? Point(0, -1) : direction) * random.number(12...32)
                        circuit.wires.append(Wire(points: [start, end]))
                    }
                } }
                // Include connected diagrams as well as isolated symbols. Wire
                // routing avoids symbol bodies; these are visual training sheets,
                // not assertions that the random circuits are electrically valid.
                if random.integer(0...2) != 0 {
                    for j in 1..<max(1, circuit.components.count) {
                        let a = circuit.components[j - 1], b = circuit.components[j]
                        if a.position.distance(to: b.position) < 220,
                           let ap = a.pins.last, let bp = b.pins.first {
                            circuit.connect(a.id, ap.name, b.id, bp.name)
                        }
                    }
                }
                let scale = random.number(0.8...1.35)
                let pixelWidth = Int(ceil(width * scale)), pixelHeight = Int(ceil(height * scale))
                guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CircuitError.message("Could not allocate dataset image.") }
                context.setFillColor(CGColor(gray: random.number(0.95...1), alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                context.translateBy(x: 0, y: Double(pixelHeight)); context.scaleBy(x: scale, y: -scale)
                CircuitRenderer.draw(circuit, in: context)
                guard let image = context.makeImage() else { throw CircuitError.message("Could not render dataset image.") }
                let name = String(format: "sample-%05d.png", i)
                let imageURL = folder.appendingPathComponent(name)
                guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CircuitError.message("Could not save dataset image.") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CircuitError.message("Could not encode dataset image.") }
                let annotations = circuit.components.map { component in
                    let bounds = symbolBounds(component, theme: circuit.theme)
                    return VisionAnnotation(label: component.kind.rawValue, coordinates: VisionBox(x: bounds.center.x * scale, y: bounds.center.y * scale, width: bounds.width * scale, height: bounds.height * scale))
                }
                samples.append(VisionSample(image: name, annotations: annotations))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(samples).write(to: folder.appendingPathComponent("annotations.json"))
            print("\(split): \(samples.count) images, \(samples.reduce(0) { $0 + $1.annotations.count }) symbols")
        }
        // Templates are evaluated separately from randomized symbol sheets.
        let templates = root.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        var samples: [VisionSample] = []
        for template in CircuitTemplate.allCases where template != .blank {
            let circuit = template.make()
            let bounds = circuit.bounds, scale = 1.3, name = "\(template.id.replacingOccurrences(of: " ", with: "-" )).png"
            try CircuitExport.raster(circuit, scale: scale, transparent: false).write(to: templates.appendingPathComponent(name))
            let annotations = circuit.components.filter { kinds.contains($0.kind) }.map { component in
                let box = symbolBounds(component, theme: circuit.theme)
                return VisionAnnotation(label: component.kind.rawValue, coordinates: VisionBox(x: (box.center.x - bounds.minX) * scale, y: (box.center.y - bounds.minY) * scale, width: box.width * scale, height: box.height * scale))
            }
            samples.append(VisionSample(image: name, annotations: annotations))
        }
        try JSONEncoder().encode(samples).write(to: templates.appendingPathComponent("annotations.json"))
    }

    static func symbolBounds(_ component: Component, theme: SymbolTheme) -> Bounds {
        var points: [Point] = []
        for primitive in Symbols.geometry(component, theme: theme) {
            switch primitive {
            case .reference(let path): points += path.sampledPoints
            case .line(let p), .polygon(let p, _): points += p
            case .circle(let p, let radius, _): points += [p - Point(radius, radius), p + Point(radius, radius)]
            }
        }
        return Bounds(points, padding: 3)
    }

    static func evaluate(directory: URL, modelURL: URL, reportURL: URL) throws {
        let compiledURL = try MLModel.compileModel(at: modelURL)
        defer { try? FileManager.default.removeItem(at: compiledURL) }
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
        let model = try VNCoreMLModel(for: MLModel(contentsOf: compiledURL, configuration: configuration))
        let samples = try JSONDecoder().decode([VisionSample].self, from: Data(contentsOf: directory.appendingPathComponent("annotations.json")))
        var tp = 0, fp = 0, fn = 0; var milliseconds: [Double] = []; var rows: [[String: Any]] = []
        let threshold = CircuitVision.confidenceThreshold
        for sample in samples {
            let url = directory.appendingPathComponent(sample.image)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CircuitError.message("Could not load \(url.path)") }
            let request = VNCoreMLRequest(model: model); request.imageCropAndScaleOption = .scaleFill
            let start = Date(); try VNImageRequestHandler(cgImage: image).perform([request]); milliseconds.append(Date().timeIntervalSince(start) * 1000)
            let candidates = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { observation -> CircuitSymbolDetection? in
                guard let label = observation.labels.first, label.confidence >= threshold, let kind = ComponentKind(rawValue: label.identifier) else { return nil }
                return CircuitSymbolDetection(id: UUID(), kind: kind, confidence: label.confidence, bounds: CircuitVision.topLeft(observation.boundingBox))
            }
            let detections = CircuitVision.suppressOverlaps(candidates)
            var matched = Set<Int>()
            var imageTP = 0
            for detection in detections {
                let box = detection.bounds
                let rect = CGRect(x: box.minX * Double(image.width), y: box.minY * Double(image.height), width: box.width * Double(image.width), height: box.height * Double(image.height))
                let choices = sample.annotations.indices.filter { !matched.contains($0) && sample.annotations[$0].label == detection.kind.rawValue }
                if let best = choices.max(by: { iou(rect, sample.annotations[$0].coordinates.rect) < iou(rect, sample.annotations[$1].coordinates.rect) }), iou(rect, sample.annotations[best].coordinates.rect) >= 0.5 { matched.insert(best); imageTP += 1 } else { fp += 1 }
            }
            tp += imageTP; fn += sample.annotations.count - matched.count
            rows.append(["image": sample.image, "expected": sample.annotations.count, "detected": detections.count, "matched": imageTP])
        }
        let precision = Double(tp) / Double(max(1, tp + fp)), recall = Double(tp) / Double(max(1, tp + fn))
        let report: [String: Any] = ["dataScope": "Synthetic native symbols; does not measure textbook/paper generalization.", "confidenceThreshold": threshold, "iouThreshold": 0.5, "truePositives": tp, "falsePositives": fp, "falseNegatives": fn, "precision": precision, "recall": recall, "meanLatencyMillisecondsOnThisMac": milliseconds.reduce(0, +) / Double(max(1, milliseconds.count)), "images": rows]
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        print("Precision \(precision), recall \(recall), report \(reportURL.path)")
    }
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        if intersection.isNull { return 0 }
        let area = intersection.width * intersection.height
        return area / max(1e-9, a.width * a.height + b.width * b.height - area)
    }
}
