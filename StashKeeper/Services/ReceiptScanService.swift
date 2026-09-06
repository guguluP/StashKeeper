//
//  ReceiptScanService.swift
//  StashKeeper
//
//  Extracts line items from a photographed supermarket receipt/bill.
//  Pipeline: VisionAnalyzer's global OCR pass reads all text on the
//  receipt (no object/region detection needed — a receipt is one flat
//  document, not a photo of several physical objects) -> the OCR lines
//  are ordered top-to-bottom to preserve the receipt's actual line order
//  -> Foundation Models is asked to parse that into structured line items
//  via guided generation.
//
//  Mirrors ItemIntelligenceService's tiering: on-device AFM first, Private
//  Cloud Compute for a retry on failure, and a zero-AI heuristic regex
//  fallback (ReceiptHeuristicParser, below) for devices that can't run
//  Apple Intelligence at all — so a bill can still be captured and turned
//  into a checklist even without any AI tier available, just with less
//  cleanup of abbreviated product names and no category guessing.
//

import Foundation
import FoundationModels

enum ReceiptScanError: Error, LocalizedError {
    case noTextFound
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .noTextFound:
            return "Couldn't find any readable text on this photo. Try a clearer, well-lit shot of the receipt."
        case .invalidImage:
            return "That photo couldn't be read."
        }
    }
}

@MainActor
final class ReceiptScanService {

    static let shared = ReceiptScanService()

    private let visionAnalyzer = VisionAnalyzer()
    private init() {}

    /// True if the most recent extraction used the zero-AI heuristic
    /// fallback rather than AFM — surfaced so the UI can disclose reduced
    /// accuracy, matching the transparency pattern used everywhere else
    /// AI degrades to a heuristic tier in this app.
    private(set) var lastExtractionWasHeuristic = false

    func extractLineItems(from imageData: Data) async throws -> ReceiptExtraction {
        let observations = try await visionAnalyzer.analyze(imageData: imageData)

        // A receipt is a single flat document, not a photo with several
        // distinct physical objects — so region-based detection isn't
        // useful here, only the whole-image OCR pass matters. Order lines
        // top-to-bottom (Vision's boundingBox origin is bottom-left, so
        // descending Y = reading order) since that ordering is the
        // strongest signal for "these lines belong to the same row" that
        // a receipt's dense, uniform-size text otherwise lacks.
        let orderedLines = observations.globalRecognizedText
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }

        guard !orderedLines.isEmpty else {
            throw ReceiptScanError.noTextFound
        }

        // Never touch PrivateCloudComputeLanguageModel without the
        // entitlement-safe helper — direct construction can fatal-trap.
        let onDeviceReady = PreferredModelRouter.onDeviceModel(for: .contentTagging).isAvailable
        guard onDeviceReady || PreferredModelRouter.isPrivateCloudComputeAvailable else {
            lastExtractionWasHeuristic = true
            return ReceiptHeuristicParser.parse(orderedLines)
        }

        let (model, tier) = PreferredModelRouter.resolve(
            preferCloud: false,
            useCase: .contentTagging
        )

        let instructions = Instructions {
            """
            You extract individual purchased line items from a photographed
            supermarket/retail receipt. You may receive both the raw OCR
            text (top-to-bottom reading order) and, when available, the
            receipt photo itself. OCR is imperfect — lines may be split
            oddly, have misread characters, or run together. Use your
            judgment (and the photo when attached) to reconstruct sensible
            item rows from this noisy input.

            Only extract actual purchased products. Skip subtotal, tax
            (GST/VAT), discount, rounding, total, change, payment method,
            loyalty program, and store contact/address lines — those are
            not products.
            """
        }

        let linesText = orderedLines.map(\.text).joined(separator: "\n")
        let receiptPhoto = AFMImageSupport.modelSupportsVision(model)
            ? AFMImageSupport.attachment(from: imageData)
            : nil

        let prompt = Prompt {
            """
            Parse this receipt into structured line items.

            OCR text (top-to-bottom):
            \(linesText)
            """
            if let receiptPhoto {
                "Receipt photo (use to correct OCR mistakes and recover missed lines):"
                receiptPhoto
            }
        }

        let options = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0.2,
            maximumResponseTokens: 2048
        )

        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            session.prewarm()
            let response = try await session.respond(
                to: prompt,
                generating: ReceiptExtraction.self,
                options: options
            )
            lastExtractionWasHeuristic = false
            return response.content
        } catch {
            let (retryModel, _) = PreferredModelRouter.resolve(
                preferCloud: tier != .privateCloudCompute,
                useCase: .contentTagging
            )
            do {
                let retrySession = LanguageModelSession(model: retryModel, instructions: instructions)
                retrySession.prewarm()
                let response = try await retrySession.respond(
                    to: prompt,
                    generating: ReceiptExtraction.self,
                    options: GenerationOptions(
                        samplingMode: .greedy,
                        temperature: 0.1,
                        maximumResponseTokens: 2048
                    )
                )
                lastExtractionWasHeuristic = false
                return response.content
            } catch {
                lastExtractionWasHeuristic = true
                return ReceiptHeuristicParser.parse(orderedLines)
            }
        }
    }
}

/// Zero-AI fallback for receipt parsing, mirroring HeuristicItemNamer's
/// philosophy: simple, explainable rules rather than an attempt to
/// imitate AFM's text understanding. Recognizes a line as a product row
/// only when it contains a price-shaped number, reusing
/// PriceHintExtractor's regex — anything without a plausible price gets
/// skipped rather than guessed at, since a bare product name with no
/// price signal is too ambiguous to separate from a header/footer line
/// using regex alone.
enum ReceiptHeuristicParser {
    static func parse(_ lines: [OCRLine]) -> ReceiptExtraction {
        var items: [ReceiptLineItem] = []

        for line in lines {
            let hints = PriceHintExtractor.extractPriceHints(from: [line])
            guard let priceHint = hints.first else { continue }

            // Strip the matched price text back out of the line to get
            // just the product name portion — imperfect, but keeps this
            // tier simple and predictable rather than attempting fuzzy
            // reconstruction of an abbreviated product name.
            var namePart = line.text
            namePart = namePart.replacingOccurrences(of: priceHint.rawText, with: "")
            namePart = namePart.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-:")))

            guard namePart.count >= 2 else { continue }

            let digits = priceHint.rawText.filter { $0.isNumber || $0 == "." }

            items.append(ReceiptLineItem(
                name: namePart.localizedCapitalized,
                quantity: 1,
                priceAmount: digits,
                category: "Other"
            ))
        }

        return ReceiptExtraction(storeName: "", purchaseDateISO: "", items: items, currency: "INR")
    }
}
