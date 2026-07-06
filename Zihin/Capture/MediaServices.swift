import AVFoundation
import Foundation
import PDFKit
import Speech
import UIKit

struct VideoEnrichResult: Sendable {
    var frameText: String
    var transcript: String
    var classifications: [String]
    var colors: [String]
    var durationSec: Double
    var featurePrint: Data?
    var posterData: Data?
}

/// LOKAL video dosyası analizi (spec §7): kare OCR + classify + on-device STT.
enum VideoEnrichmentService {
    static func enrich(url: URL, maxFrames: Int = 20) async -> VideoEnrichResult {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1080)

        let count = duration > 0 ? min(maxFrames, max(1, Int(duration))) : 1
        let step = duration > 0 ? duration / Double(count) : 0

        var frameLines = Set<String>()
        var classCount: [String: Int] = [:]
        var colorSet = Set<String>()
        var poster: Data?
        var midFP: Data?

        for i in 0..<count {
            let t = CMTime(seconds: Double(i) * step + step / 2, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image else { continue }
            if i == 0 { poster = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) }
            let v = VisionService.analyze(cgImage: cg)
            for line in v.ocrText.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.count > 1 { frameLines.insert(s) }
            }
            for c in v.classifications { classCount[c, default: 0] += 1 }
            if i == count / 2 {
                midFP = v.featurePrint
                colorSet.formUnion(ColorService.dominantColorNames(cgImage: cg))
            }
        }

        let transcript = await transcribe(url: url)
        return VideoEnrichResult(
            frameText: frameLines.joined(separator: "\n"),
            transcript: transcript,
            classifications: classCount.sorted { $0.value > $1.value }.prefix(8).map { $0.key },
            colors: Array(colorSet),
            durationSec: duration,
            featurePrint: midFP,
            posterData: poster)
    }

    /// YALNIZ on-device STT (spec §5). Cihaz desteklemiyorsa boş döner —
    /// ses ASLA server'a gitmez, gizlilik vaadi mutlak.
    private static func transcribe(url: URL) async -> String {
        let authed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard authed else { return "" }
        let locales = [Locale.current, Locale(identifier: "tr-TR"), Locale(identifier: "en-US")]
        guard let recognizer = locales
            .compactMap({ SFSpeechRecognizer(locale: $0) })
            .first(where: { $0.isAvailable && $0.supportsOnDeviceRecognition })
        else { return "" }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { c.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { c.resume(returning: result?.bestTranscription.formattedString ?? "") }
                }
            }
        }
    }
}

/// Continuation'ın tek kez resume edilmesini garantiler (Sendable closure içinde).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

enum PDFTextExtractor {
    static func extract(url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var out = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string { out += s + "\n" }
        }
        // Taranmış (text'siz) PDF -> sayfa render + OCR: v1.x (spec §5)
        return out
    }
}
