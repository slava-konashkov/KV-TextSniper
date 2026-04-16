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
            // Language correction applies a language model on top of the raw
            // recognition result — helpful for prose, harmful for code, paths,
            // commands, and other symbol-heavy text where the model "corrects"
            // valid tokens into similar-looking dictionary words. A sniper
            // tool is used far more for the latter than the former.
            request.usesLanguageCorrection = false

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
            Log.ocr.notice("recognize: revision=\(request.revision) languages=\(langs.joined(separator: ","), privacy: .public)")

            // Vision's text recogniser is markedly more accurate on larger
            // glyphs. On HiDPI displays running in "native" mode (a 4K monitor
            // at 1:1, for instance) CGWindowListCreateImage returns one pixel
            // per screen point — so 14pt text lands as ~14px tall, right at
            // the edge of what Vision handles cleanly. A 2× bicubic upscale
            // recovers a lot of accuracy for effectively zero cost.
            let ocrImage = Self.upscaledForOCR(image)
            if ocrImage !== image {
                Log.ocr.notice("recognize: upscaled \(image.width)x\(image.height) → \(ocrImage.width)x\(ocrImage.height)")
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

            // Join top candidates from each observation; Vision returns them
            // roughly in reading order (top to bottom, left to right).
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            let text  = lines.joined(separator: "\n")
            Log.ocr.notice("recognize: \(observations.count) observation(s), \(text.count) char(s)")
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

        // Safety net only — fires when none of the user's preferred languages
        // is supported by Vision on this OS (rare; usually a new locale on an
        // older macOS). Without this we'd hand Vision an empty array.
        if ordered.isEmpty {
            ordered.append(supported.contains("en-US") ? "en-US" : supported[0])
        }

        return ordered
    }

    /// Upscale small captures so Vision sees glyphs at a comfortable pixel
    /// size. Returns the original image when it's already large enough.
    private static func upscaledForOCR(_ image: CGImage) -> CGImage {
        // Fixed 2× scale when the capture is small enough to suggest a HiDPI
        // display running in native mode (one pixel per screen point). Going
        // higher than 2× with bicubic starts to visibly soften glyph edges —
        // the interpolation invents pixels that don't correspond to anything
        // real — and Vision's accuracy drops off rather than improves.
        guard image.width < 1500 else { return image }

        let factor = 2
        let newWidth = image.width * factor
        let newHeight = image.height * factor

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return ctx.makeImage() ?? image
    }
}
