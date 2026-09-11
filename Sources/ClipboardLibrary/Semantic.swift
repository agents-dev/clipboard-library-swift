import Foundation
import CoreML
import Vision

protocol EmbeddingService { func text(_ text: String) throws -> Data; func image(_ data: Data) throws -> Data }
final class MobileCLIP: EmbeddingService {
    static let shared = MobileCLIP()
    private let lock = NSLock()
    private var textModel: MLModel?
    private var imageModel: MLModel?
    private var tokenizer: CLIPTokens?
    private func model(_ name: String) throws -> MLModel {
        guard let url = Bundle.module.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Resources") else { throw NSError(domain: "MobileCLIP model missing", code: 1) }
        let config = MLModelConfiguration(); config.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: config)
    }
    func text(_ text: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        if textModel == nil { textModel = try model("mobileclip_s0_text") }
        if tokenizer == nil { tokenizer = try CLIPTokens() }
        let tokens = try tokenizer!.encode(text)
        let input = try MLMultiArray(shape: [1,77], dataType: .int32)
        for i in 0..<77 { input[i] = NSNumber(value: tokens[i]) }
        let output = try textModel!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": input]))
        guard let array = output.featureValue(for: "final_emb_1")?.multiArrayValue else { throw NSError(domain: "MobileCLIP output", code: 2) }
        return normalized(array)
    }
    func image(_ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if imageModel == nil { imageModel = try model("mobileclip_s0_image") }
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: imageModel!))
        request.imageCropAndScaleOption = .centerCrop
        try VNImageRequestHandler(data: data).perform([request])
        guard let result = request.results?.first as? VNCoreMLFeatureValueObservation, let array = result.featureValue.multiArrayValue else { throw NSError(domain: "MobileCLIP image output", code: 3) }
        return normalized(array)
    }
    private func normalized(_ array: MLMultiArray) -> Data {
        var values = (0..<array.count).map { array[$0].floatValue }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { values = values.map { $0 / norm } }
        return values.withUnsafeBytes { Data($0) }
    }
}
struct CLIPTokens {
    let vocabulary: [String: Int]
    let ranks: [String: Int]
    let bytes: [UInt8: String]
    init() throws {
        let root = Bundle.module.url(forResource: "clip-vocab", withExtension: "json")!.deletingLastPathComponent()
        vocabulary = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: root.appendingPathComponent("clip-vocab.json")))
        let merges = try String(contentsOf: root.appendingPathComponent("clip-merges.txt"), encoding: .utf8).split(separator: "\n").dropFirst()
        ranks = Dictionary(uniqueKeysWithValues: merges.enumerated().map { (String($0.element), $0.offset) })
        let direct = Array(33...126) + Array(161...172) + Array(174...255)
        var mapping: [UInt8: String] = [:]; var extra = 256
        for b in 0...255 { let value: Int; if direct.contains(b) { value = b } else { value = extra; extra += 1 }; mapping[UInt8(b)] = String(UnicodeScalar(value)!) }
        bytes = mapping
    }
    func encode(_ text: String) throws -> [Int] {
        let text = String(text.prefix(10000)).lowercased()
        let regex = try NSRegularExpression(pattern: "'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+")
        var tokens: [Int] = [49406]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            var word = text[range].utf8.map { bytes[$0]! }; guard !word.isEmpty else { continue }; word[word.count-1] += "</w>"
            while word.count > 1 {
                let best = (0..<word.count-1).compactMap { i -> (Int,Int)? in ranks[word[i] + " " + word[i+1]].map { (i,$0) } }.min { $0.1 < $1.1 }
                guard let (index, _) = best else { break }
                word[index] += word[index+1]; word.remove(at: index+1)
            }
            tokens.append(contentsOf: word.compactMap { vocabulary[$0] })
            if tokens.count >= 76 { break }
        }
        tokens = Array(tokens.prefix(76)); tokens.append(49407)
        return tokens + Array(repeating: 0, count: 77-tokens.count)
    }
}
