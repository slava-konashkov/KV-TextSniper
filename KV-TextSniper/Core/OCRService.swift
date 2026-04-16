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
            request.usesLanguageCorrection = true

            // Pick the newest revision available on this OS — revision 3
            // (macOS 13+) adds strong CJK support.
            if #available(macOS 13.0, *) {
                let revisions = Array(VNRecognizeTextRequest.supportedRevisions).sorted()
                if let newest = revisions.last {
                    request.revision = newest
                }
            }

            let langs = Self.languages(for: request)
            request.recognitionLanguages = langs
            Log.ocr.notice("recognize: revision=\(request.revision) languages=\(langs.count)")

            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])

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

            // Join top candidates from each observation; Vision returns them
            // roughly in reading order (top to bottom, left to right).
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            let text  = lines.joined(separator: "\n")
            Log.ocr.notice("recognize: \(observations.count) observation(s), \(text.count) char(s)")
            completion(text.isEmpty ? nil : text)
        }
    }

    /// Returns the set of languages supported by `request` on the current OS,
    /// ordered so that the user's preferred languages come first, followed by
    /// common CJK scripts, followed by everything else. Feeding Vision an
    /// unsupported language string causes it to throw, so we always filter
    /// against `supportedRecognitionLanguages`.
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

        let cjkFallback = ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR"]
        var ordered: [String] = []

        for preferred in Locale.preferredLanguages {
            if supported.contains(preferred), !ordered.contains(preferred) {
                ordered.append(preferred)
            }
        }
        for lang in cjkFallback where supported.contains(lang) && !ordered.contains(lang) {
            ordered.append(lang)
        }
        for lang in supported where !ordered.contains(lang) {
            ordered.append(lang)
        }
        return ordered
    }
}
