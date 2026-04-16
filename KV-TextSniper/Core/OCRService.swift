//
//  OCRService.swift
//  KV-TextSniper
//
//  Text recognition via Apple's Vision framework. Vision ships with
//  models for many scripts — including Chinese (simplified + traditional),
//  Japanese, Korean, Cyrillic, Latin, Arabic, Thai and more — depending on
//  the macOS version.
//
//  We query `supportedRecognitionLanguages` at runtime and pass the full
//  set to the request, so the same binary adapts to whatever the host OS
//  supports.
//

import Vision
import CoreGraphics
import CoreImage
import os

final class OCRService {

    private let queue = DispatchQueue(label: "com.kv.textsniper.ocr", qos: .userInitiated)

    /// Runs OCR on `image` and calls `completion` on a background queue with
    /// the recognised text (or nil on failure).
    func recognizeText(in image: CGImage, completion: @escaping (String?) -> Void) {
        let dispatchTime = CFAbsoluteTimeGetCurrent()
        queue.async {
            let queueWait = CFAbsoluteTimeGetCurrent() - dispatchTime
            Log.ocr.notice("recognize: enter (image \(image.width)x\(image.height), queue-wait \(String(format: "%.3f", queueWait), privacy: .public)s)")

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Language correction applies a dictionary/LM pass on top of the
            // raw recognition result. On multi-script inputs (e.g. English
            // code on a system that also has Cyrillic or CJK as preferred
            // languages) this is what stops Vision from flipping visually
            // confusable glyphs — Latin `k` → Cyrillic `к`, `e` → `е`, and
            // so on — into the wrong script, because the LM knows which
            // letters form valid tokens.
            request.usesLanguageCorrection = true

            // Pick the newest revision available on this OS — revision 3
            // (macOS 13+) adds strong CJK support.
            if #available(macOS 13.0, *) {
                let revisions = Array(VNRecognizeTextRequest.supportedRevisions).sorted()
                if let newest = revisions.last {
                    request.revision = newest
                }
            }

            // Language handling has two modes:
            //
            //  - macOS 13+: let Vision auto-detect the dominant script in the
            //    image and pick the matching model. This matters for users who
            //    don't list a particular language in System Preferred Languages
            //    (common for CJK: the person types Chinese from a Russian-or-
            //    English system). Providing an explicit priority list would
            //    force Vision to read Chinese glyphs through an English LM and
            //    output Latin-looking garbage.
            //
            //  - macOS 12: no auto-detect; fall back to the priority list.
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
                Log.ocr.notice("recognize: revision=\(request.revision) auto-detect=on")
            } else {
                let langs = Self.languages(for: request)
                request.recognitionLanguages = langs
                Log.ocr.notice("recognize: revision=\(request.revision) languages=\(langs.joined(separator: ","), privacy: .public)")
            }

            // Preprocess: Lanczos upscale (cleaner glyph edges than bicubic
            // on rasterised text) plus a mild unsharp mask to counteract the
            // inevitable softening. Vision's accuracy on HiDPI-native captures
            // — where CGWindowListCreateImage returns 1 pixel per screen
            // point, so 14pt text is only ~14px tall — climbs sharply after
            // this stage.
            let ocrImage = Self.preprocessedForOCR(image)
            if ocrImage !== image {
                Log.ocr.notice("recognize: preprocessed \(image.width)x\(image.height) → \(ocrImage.width)x\(ocrImage.height)")
            }
            let handler = VNImageRequestHandler(cgImage: ocrImage, orientation: .up, options: [:])

            let perfStart = CFAbsoluteTimeGetCurrent()
            do {
                try handler.perform([request])
            } catch {
                Log.ocr.error("recognize: perform failed: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            let perfElapsed = CFAbsoluteTimeGetCurrent() - perfStart
            Log.ocr.notice("recognize: perform done in \(String(format: "%.3f", perfElapsed), privacy: .public)s")

            guard let observations = request.results, !observations.isEmpty else {
                Log.ocr.notice("recognize: no observations")
                completion(nil)
                return
            }

            // Group observations into reading order: top-to-bottom primary,
            // left-to-right secondary. Vision's own ordering is mostly good,
            // but for multi-column layouts (e.g. an IDE screenshot with line
            // numbers in the gutter and code to the right) it sometimes
            // returns every number first and every code line afterwards,
            // producing "1 2 3 … import AppKit import os …" in the output.
            // Explicit grouping-by-Y stitches them back into real lines.
            let lines = Self.linesInReadingOrder(observations)
            let text = lines.map { line in
                line.compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
            }.joined(separator: "\n")
            Log.ocr.notice("recognize: \(observations.count) observation(s), \(lines.count) line(s), \(text.count) char(s)")
            completion(text.isEmpty ? nil : text)
        }
    }

    /// Returns the language list to feed Vision, in priority order — seeded
    /// exclusively from the user's system-wide Preferred Languages list.
    ///
    /// Vision weights results by this order (first wins ties), and a captured
    /// region is overwhelmingly likely to contain text in a single language —
    /// almost always the user's primary one. Padding the list with unrelated
    /// scripts (Chinese, Arabic, Thai, …) just makes Vision split probability
    /// mass across glyphs that don't exist in the image, which measurably
    /// degrades accuracy for Latin/Cyrillic text.
    ///
    /// Matching is loose: a preferred tag like `"ru"` resolves to Vision's
    /// `"ru-RU"`, `"zh-Hans"` resolves to `"zh-Hans-CN"`, etc.
    private static func languages(for request: VNRecognizeTextRequest) -> [String] {
        let supported: [String]
        if #available(macOS 12.0, *) {
            supported = (try? request.supportedRecognitionLanguages()) ?? []
        } else {
            supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
                for: .accurate,
                revision: VNRecognizeTextRequestRevision1
            )) ?? []
        }

        guard !supported.isEmpty else { return ["en-US"] }

        // One-shot log of what Vision actually reports as supported — the
        // exact tags vary by macOS version (e.g. "zh-Hans" vs "zh-Hans-CN"),
        // and a mismatch breaks naive contains-checks below.
        Log.ocr.notice("recognize: supported languages (\(supported.count)) = \(supported.joined(separator: ","), privacy: .public)")

        var ordered: [String] = []

        func addMatch(for preferred: String) {
            if supported.contains(preferred), !ordered.contains(preferred) {
                ordered.append(preferred)
                return
            }
            let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if let match = supported.first(where: { $0 == base || $0.hasPrefix(base + "-") }),
               !ordered.contains(match) {
                ordered.append(match)
            }
        }

        for preferred in Locale.preferredLanguages {
            addMatch(for: preferred)
        }

        // CJK fallback. Han ideographs, kana and hangul look nothing at all
        // like Latin or Cyrillic glyphs, so adding these to the tail of the
        // list has no measurable cost when the capture is non-CJK — Vision
        // simply never assigns probability to them. But when the capture IS
        // CJK and the user hasn't listed a CJK language in System Preferred
        // Languages, this turns "garbage-out" into proper recognition. Cost
        // of getting it wrong is asymmetric, so we always include them.
        // Uses addMatch so "zh-Hans" also picks up Vision's "zh-Hans-CN".
        for lang in ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR"] {
            addMatch(for: lang)
        }

        // Safety net only — fires when none of the user's preferred languages
        // is supported by Vision on this OS (rare; usually a new locale on an
        // older macOS). Without this we'd hand Vision an empty array.
        if ordered.isEmpty {
            ordered.append(supported.contains("en-US") ? "en-US" : supported[0])
        }

        return ordered
    }

    /// Sharpen (and, for small captures, upscale) the image before handing it
    /// to Vision. Lanczos + unsharp consistently beats CGContext bicubic for
    /// rasterised text: edges stay crisp instead of softening into grey halos.
    private static func preprocessedForOCR(_ image: CGImage) -> CGImage {
        var ci = CIImage(cgImage: image)

        // 2× Lanczos upscale for small captures — the typical HiDPI-native
        // case where one screen point is one pixel.
        if image.width < 1500 {
            ci = ci.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: 2.0,
                kCIInputAspectRatioKey: 1.0
            ])
        }

        // Mild unsharp mask. Radius/intensity tuned to crispen typical UI
        // text (12–18pt body, 10pt code) without introducing ringing on
        // anti-aliased glyph edges.
        ci = ci.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 1.2,
            kCIInputIntensityKey: 0.4
        ])

        return Self.ciContext.createCGImage(ci, from: ci.extent) ?? image
    }

    /// Shared Core Image context. Creating one per call is wasteful (each
    /// constructor spins up a Metal/OpenGL pipeline), and `CIContext` is
    /// documented as thread-safe for rendering.
    private static let ciContext = CIContext(options: nil)

    /// Groups Vision observations into lines in natural reading order
    /// (top → bottom, left → right within each line). Two observations
    /// land on the same line when their vertical mid-points are closer
    /// than half the shorter of their heights.
    private static func linesInReadingOrder(_ observations: [VNRecognizedTextObservation]) -> [[VNRecognizedTextObservation]] {
        // Vision's boundingBox uses normalised coords with origin at the
        // bottom-left; greater Y means higher up in the image, which is
        // earlier in reading order.
        let sorted = observations.sorted { a, b in
            let tol = min(a.boundingBox.height, b.boundingBox.height) * 0.5
            if abs(a.boundingBox.midY - b.boundingBox.midY) < tol {
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return a.boundingBox.midY > b.boundingBox.midY
        }

        var lines: [[VNRecognizedTextObservation]] = []
        for obs in sorted {
            if let anchor = lines.last?.first {
                let tol = min(anchor.boundingBox.height, obs.boundingBox.height) * 0.5
                if abs(anchor.boundingBox.midY - obs.boundingBox.midY) < tol {
                    lines[lines.count - 1].append(obs)
                    continue
                }
            }
            lines.append([obs])
        }
        return lines
    }
}
