import Vision
import CoreGraphics
import Foundation

struct VisionResult: Sendable {
    var ocrText: String
    var classifications: [String]
    var featurePrint: Data?
}

enum VisionService {
    /// OCR + classify + feature print (spec §5).
    static func analyze(cgImage: CGImage,
                        languages: [String] = ["tr-TR", "en-US"]) -> VisionResult {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true
        textReq.recognitionLanguages = languages

        let classReq = VNClassifyImageRequest()
        let fpReq = VNGenerateImageFeaturePrintRequest()

        do { try handler.perform([textReq, classReq, fpReq]) }
        catch { return VisionResult(ocrText: "", classifications: [], featurePrint: nil) }

        let ocr = (textReq.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        // Düzeltilmiş filtre (spec §5): anlamlı precision/recall + confidence eşiği.
        let classes = (classReq.results ?? [])
            .filter { $0.confidence > 0.3 && $0.hasMinimumPrecision(0.5, forRecall: 0.5) }
            .prefix(8)
            .map { $0.identifier }

        var fpData: Data?
        if let obs = fpReq.results?.first {
            fpData = try? NSKeyedArchiver.archivedData(withRootObject: obs,
                                                       requiringSecureCoding: true)
        }
        return VisionResult(ocrText: ocr, classifications: Array(classes), featurePrint: fpData)
    }

    /// Feature print mesafesi (küçük = benzer). Same Vibe + dedup.
    static func distance(_ a: Data, _ b: Data) -> Float? {
        guard
            let oa = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: a),
            let ob = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: b)
        else { return nil }
        var dist: Float = 0
        do { try oa.computeDistance(&dist, to: ob); return dist } catch { return nil }
    }
}
