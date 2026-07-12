//
//  BarcodeScanner.swift
//  StashKeeper
//
//  Detects and decodes barcodes/QR codes from a captured photo using
//  Vision's VNDetectBarcodesRequest. This runs alongside the object
//  detection pipeline — if a photo contains a barcode (e.g. a product
//  label), we get a fast, deterministic product identifier (UPC/EAN) that
//  we can look up directly, which is far more reliable than visual
//  classification alone for packaged/branded goods.
//

import Foundation
@preconcurrency import Vision
import ImageIO
import CoreGraphics

struct DetectedBarcode: Sendable, Equatable {
    let payload: String
    let symbology: String
    /// Normalized bounding box (Vision convention, origin bottom-left) so we
    /// can associate a barcode with the nearby detected item region.
    let normalizedBoundingBox: CGRect
}

actor BarcodeScanner {

    /// Scans the full image for any barcodes/QR codes. Returns an empty
    /// array if none are found — this is a normal, expected outcome for
    /// most photos, not an error.
    func scan(imageData: Data) async throws -> [DetectedBarcode] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNBarcodeObservation]) ?? []
                let barcodes = observations.compactMap { observation -> DetectedBarcode? in
                    guard let payload = observation.payloadStringValue else { return nil }
                    return DetectedBarcode(
                        payload: payload,
                        symbology: observation.symbology.rawValue,
                        normalizedBoundingBox: observation.boundingBox
                    )
                }
                continuation.resume(returning: barcodes)
            }
            // Restrict to symbologies actually used on retail packaging to
            // reduce false positives from incidental patterns in the photo.
            request.symbologies = [.ean13, .ean8, .upce, .code128, .code39, .qr, .itf14, .dataMatrix]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Finds the barcode, if any, whose bounding box overlaps or is nearest
    /// to a given detected item region — used to associate a scanned
    /// barcode with the correct item when a photo has multiple items.
    func nearestBarcode(to regionBox: CGRect, in barcodes: [DetectedBarcode]) -> DetectedBarcode? {
        guard !barcodes.isEmpty else { return nil }
        if let overlapping = barcodes.first(where: { $0.normalizedBoundingBox.intersects(regionBox) }) {
            return overlapping
        }
        // Fall back to closest center-to-center distance.
        return barcodes.min { lhs, rhs in
            distance(lhs.normalizedBoundingBox, regionBox) < distance(rhs.normalizedBoundingBox, regionBox)
        }
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}
