//
//  VisionAnalyzer.swift
//  StashKeeper
//
//  Uses the Vision framework to detect and classify potentially multiple
//  distinct items within a single photo/video frame. Pipeline:
//
//  1. VNGenerateObjectnessBasedSaliencyImageRequest + rectangle/contour
//     detection propose candidate regions (bounding boxes) likely to
//     contain a distinct object.
//  2. Each region is cropped and run through VNClassifyImageRequest
//     individually, so a photo with three items on a shelf yields three
//     separate label sets instead of one blended-together guess.
//  3. VNRecognizeTextRequest runs both globally (whole image, for
//     packaging/labels near items) and per-region (tighter OCR read on
//     each crop, useful for watch dials, brand text, expiry dates).
//
//  Everything here runs fully on-device. This file avoids UIKit/AppKit
//  entirely (uses ImageIO/CoreGraphics) so it compiles cleanly for both
//  iOS and macOS targets.
//

import Foundation
@preconcurrency import Vision
import ImageIO
import CoreGraphics

/// A single recognized line of text with the spatial/confidence metadata
/// needed to judge what role it likely plays (a large, high-confidence line
/// near the top of a label is probably a product name; a small line with a
/// currency symbol is probably a price) — a flat `[String]` of OCR results
/// throws this signal away and forces the language model to guess blind.
///
/// Explicitly `nonisolated`: constructed inside the nonisolated
/// `VisionAnalyzer` actor's callback closures, which run off the main
/// actor. Under this project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// setting, a plain struct without this annotation would otherwise be
/// implicitly main-actor-isolated and unusable from that context.
nonisolated struct OCRLine: Sendable, Equatable {
    let text: String
    /// Vision's per-observation confidence (0...1) for its top candidate.
    let confidence: Float
    /// Normalized bounding box (Vision convention, origin bottom-left) in
    /// the coordinate space of whatever image/region this was recognized
    /// against.
    let boundingBox: CGRect
    /// Height of the text's bounding box as a fraction of the image/region
    /// height — a cheap proxy for relative font size, since Vision doesn't
    /// report point size directly. Larger text is more likely to be a
    /// product's headline name; smaller text is more likely to be fine
    /// print, ingredients, or disclaimers.
    var relativeHeight: CGFloat { boundingBox.height }
}

/// A single candidate item detected within the source image, with its
/// location so the UI can draw a bounding box overlay.
nonisolated struct DetectedRegion: Identifiable, Sendable {
    let id: UUID
    /// Normalized bounding box (0...1 in both axes, origin bottom-left per
    /// Vision's convention) in the coordinate space of the source image.
    var normalizedBoundingBox: CGRect
    var classificationLabels: [String]
    var recognizedText: [OCRLine]
    /// Vision's confidence that this region contains a distinct object,
    /// independent of what it's classified as.
    var objectnessConfidence: Float
}

nonisolated struct VisionObservations: Sendable {
    /// One entry per distinct item candidate found in the image.
    var regions: [DetectedRegion]

    /// Text recognized anywhere in the full image, useful as extra context
    /// (e.g. a shelf label) even when not tied to one specific region.
    var globalRecognizedText: [OCRLine]
}

enum VisionAnalyzerError: Error {
    case invalidImage
}

/// Extracts price-looking lines out of a set of OCR results using a cheap,
/// deterministic regex pass — done in Swift rather than left entirely to
/// the language model, since regex reliably recognizes "this is shaped like
/// a price" (currency symbol/code plus digits, or a standalone decimal
/// number) far more consistently than asking a small on-device model to
/// spot it inside a wall of unrelated OCR text.
///
/// Explicitly `nonisolated` because this project sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise make
/// this type's static regex properties implicitly main-actor-isolated —
/// this is called from `AddItemFlowView`'s background analysis task, which
/// isn't guaranteed to already be hopped onto the main actor at that point.
nonisolated enum PriceHintExtractor {
    private static let currencyPattern = try? NSRegularExpression(
        pattern: #"(₹|Rs\.?|MRP|INR|\$|USD|€|EUR|£|GBP)\s?[0-9][0-9,]*(\.[0-9]{1,2})?"#,
        options: [.caseInsensitive]
    )
    private static let bareNumberPattern = try? NSRegularExpression(
        pattern: #"^[0-9]{1,6}(\.[0-9]{1,2})?$"#
    )

    /// Scans a set of OCR lines and returns the subset that look like a
    /// price, with the matched currency marker (if any) surfaced
    /// separately so the language model doesn't have to re-derive it.
    static func extractPriceHints(from lines: [OCRLine]) -> [PriceOCRHint] {
        lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let range = NSRange(text.startIndex..., in: text)

            if let match = currencyPattern?.firstMatch(in: text, range: range) {
                let currencyRange = match.range(at: 1)
                let currency = currencyRange.location != NSNotFound
                    ? (text as NSString).substring(with: currencyRange)
                    : nil
                return PriceOCRHint(rawText: text, detectedCurrencyHint: currency)
            }

            // A bare number on its own line (no surrounding words) on a
            // label is very often a price even without a currency symbol
            // — e.g. price tags that print just "249" beneath a rupee
            // symbol rendered as a separate graphic Vision can't OCR.
            if bareNumberPattern?.firstMatch(in: text, range: range) != nil {
                return PriceOCRHint(rawText: text, detectedCurrencyHint: nil)
            }

            return nil
        }
    }
}

actor VisionAnalyzer {

    /// Minimum objectness confidence for a proposed region to be kept.
    private let minObjectnessConfidence: Float = 0.15

    /// Minimum bounding box area (as a fraction of full image area) to avoid
    /// keeping tiny noise detections.
    private let minRegionAreaFraction: CGFloat = 0.02

    /// Runs full multi-item analysis on a single photo/frame.
    func analyze(imageData: Data) async throws -> VisionObservations {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisionAnalyzerError.invalidImage
        }

        async let globalText = recognizeText(cgImage: cgImage, regionOfInterest: nil)
        let candidateBoxes = try await proposeRegions(cgImage: cgImage)

        // If nothing distinct was proposed (e.g. a single centered product
        // shot), fall back to treating the whole image as one region so the
        // rest of the pipeline still works exactly like single-item capture.
        let boxes = candidateBoxes.isEmpty
            ? [DetectedRegionProposal(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1.0)]
            : candidateBoxes

        var regions: [DetectedRegion] = []
        for box in boxes {
            guard let cropped = crop(cgImage: cgImage, normalizedRect: box.boundingBox) else { continue }
            // async let here is scoped to this loop iteration and both
            // children are awaited before the iteration ends, so there's no
            // unstructured-concurrency buildup across iterations — each
            // region's work fully completes before the next one starts.
            async let labels = classify(cgImage: cropped)
            async let text = recognizeText(cgImage: cgImage, regionOfInterest: box.boundingBox)
            let region = DetectedRegion(
                id: UUID(),
                normalizedBoundingBox: box.boundingBox,
                classificationLabels: try await labels,
                recognizedText: try await text,
                objectnessConfidence: box.confidence
            )
            regions.append(region)
        }

        return VisionObservations(
            regions: regions,
            globalRecognizedText: try await globalText
        )
    }

    // MARK: - Region proposal (multi-object detection)

    private struct DetectedRegionProposal {
        let boundingBox: CGRect
        let confidence: Float
    }

    /// Proposes candidate bounding boxes for distinct objects in the image
    /// using saliency + rectangle detection, then merges overlapping boxes.
    private func proposeRegions(cgImage: CGImage) async throws -> [DetectedRegionProposal] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNGenerateObjectnessBasedSaliencyImageRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observation = (request.results as? [VNSaliencyImageObservation])?.first else {
                    continuation.resume(returning: [])
                    return
                }

                let proposals = (observation.salientObjects ?? []).compactMap { salientObject -> DetectedRegionProposal? in
                    let box = salientObject.boundingBox
                    guard box.width * box.height >= self.minRegionAreaFraction,
                          salientObject.confidence >= self.minObjectnessConfidence else { return nil }
                    return DetectedRegionProposal(boundingBox: box, confidence: salientObject.confidence)
                }

                continuation.resume(returning: self.mergeOverlapping(proposals))
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Merges bounding boxes that overlap heavily (likely the same physical
    /// object detected twice) by keeping the higher-confidence box.
    private func mergeOverlapping(_ proposals: [DetectedRegionProposal]) -> [DetectedRegionProposal] {
        var kept: [DetectedRegionProposal] = []
        for proposal in proposals.sorted(by: { $0.confidence > $1.confidence }) {
            let overlapsExisting = kept.contains { existing in
                iou(existing.boundingBox, proposal.boundingBox) > 0.5
            }
            if !overlapsExisting {
                kept.append(proposal)
            }
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (a.width * a.height) + (b.width * b.height) - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    // MARK: - Per-region classification

    /// `VNClassifyImageRequest`'s built-in 1000-class taxonomy includes very
    /// generic, low-information categories (paper/texture/material words
    /// rather than actual object identities) that Vision falls back to
    /// whenever it isn't confident about anything more specific — like a
    /// blurry photo, an unusual angle, or an object outside its training
    /// distribution. When one of these dominates the label list, Foundation
    /// Models has nothing concrete to name the item after and ends up
    /// echoing the generic label back verbatim (e.g. naming an item
    /// "Document" or "Material" instead of admitting uncertainty). These
    /// are demoted rather than dropped outright — kept as a last-resort
    /// signal below any more specific label, never as the sole label.
    /// Not `private` since `HeuristicItemNamer` (the zero-AI fallback tier
    /// for Apple-Intelligence-ineligible devices) reuses this exact list to
    /// apply the same "don't name things after generic taxonomy words"
    /// rule without duplicating it. Explicitly `nonisolated` so it's usable
    /// from that non-actor caller without an `await` — safe since it's an
    /// immutable `Set<String>` literal with no actor-isolated state.
    nonisolated static let genericLowInformationLabels: Set<String> = [
        "document", "paper", "material", "text", "pattern", "texture",
        "object", "still life photography", "close up photography",
        "product", "packaging", "surface", "no person", "indoor"
    ]

    private func classify(cgImage: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNClassificationObservation]) ?? []
                let scored = observations
                    .filter { $0.confidence > 0.12 }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(8)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }

                // Push generic labels to the end rather than filtering them
                // out entirely — if literally nothing else was detected,
                // "material" is still marginally better context than
                // nothing, but a specific label like "wristwatch" or
                // "banana" should always win the naming decision when
                // available.
                let specific = scored.filter { !Self.genericLowInformationLabels.contains($0.lowercased()) }
                let generic = scored.filter { Self.genericLowInformationLabels.contains($0.lowercased()) }
                continuation.resume(returning: specific + generic)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - OCR (global or restricted to a region of interest)

    /// Recognizes text and returns it with confidence + position metadata
    /// intact (see `OCRLine`), rather than collapsing straight to strings.
    /// This lets the language model prompt later distinguish "large,
    /// high-confidence text near the top" (likely the product name/brand)
    /// from "small text with a currency symbol" (likely a price) instead of
    /// reasoning over an undifferentiated bag of words.
    private func recognizeText(cgImage: CGImage, regionOfInterest: CGRect?) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines: [OCRLine] = observations.compactMap { observation in
                    // Consider the top 2 candidates: if the top candidate
                    // looks like a garbled read of a price/number (Vision
                    // frequently confuses similar-looking currency symbols
                    // and digits at small sizes) but a lower-ranked
                    // candidate parses more cleanly as a price, prefer the
                    // cleaner one — this directly targets the accuracy gap
                    // on printed price tags, which are often small, low-
                    // contrast text where the top candidate alone is
                    // unreliable.
                    let candidates = observation.topCandidates(2)
                    guard let top = candidates.first else { return nil }
                    let best = candidates.first(where: { self.looksLikePriceOrNumber($0.string) }) ?? top
                    return OCRLine(
                        text: best.string,
                        confidence: best.confidence,
                        boundingBox: observation.boundingBox
                    )
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            // Default minimumTextHeight (~0.03125 of image height) can miss
            // small price-tag or fine-print text in a wide shelf photo
            // where the item only occupies part of the frame. Lowering it
            // trades a little speed for catching that text — an acceptable
            // cost since this runs once per captured photo, not live.
            request.minimumTextHeight = 0.015
            // Real vocabulary terms that commonly appear on Indian and
            // international price tags/labels, given priority over the
            // built-in dictionary so language-correction doesn't "fix" them
            // into an unrelated dictionary word (a real failure mode of
            // usesLanguageCorrection on price-tag abbreviations).
            request.customWords = ["MRP", "Rs", "incl", "excl", "GST", "SKU", "UPC", "qty", "exp", "mfg"]
            if let regionOfInterest {
                request.regionOfInterest = regionOfInterest
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Cheap heuristic: does this string look like it's mostly a number,
    /// optionally with a currency symbol/decimal — used only to pick between
    /// OCR candidates, not as the final source of truth (the language model
    /// still makes the final price call from the full OCR context).
    private func looksLikePriceOrNumber(_ string: String) -> Bool {
        let digitAndPunctuation = CharacterSet(charactersIn: "0123456789.,₹$€£ ")
        let relevantChars = string.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !relevantChars.isEmpty else { return false }
        let matching = relevantChars.filter { digitAndPunctuation.contains($0) }
        return Double(matching.count) / Double(relevantChars.count) > 0.6
    }

    // MARK: - Cropping

    /// Crops a CGImage to a Vision-space normalized rect (origin bottom-left,
    /// 0...1). Adds a small margin so classification sees a little context
    /// around tightly-cropped objects.
    private func crop(cgImage: CGImage, normalizedRect: CGRect, marginFraction: CGFloat = 0.06) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        var rect = CGRect(
            x: normalizedRect.origin.x * width,
            y: (1 - normalizedRect.origin.y - normalizedRect.height) * height, // flip to top-left origin
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        )

        let marginX = rect.width * marginFraction
        let marginY = rect.height * marginFraction
        rect = rect.insetBy(dx: -marginX, dy: -marginY)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard rect.width > 1, rect.height > 1 else { return cgImage }
        return cgImage.cropping(to: rect)
    }
}
