//
//  BarcodeLookupTelemetry.swift
//  StashKeeper
//
//  A small, purely local diagnostic log of barcode lookup outcomes — which
//  tier resolved a barcode, or that none did. This exists to answer a
//  concrete question we couldn't otherwise answer: are barcode failures
//  mostly detection (Vision never reads the barcode) or lookup (Vision
//  reads it fine, but no database recognizes the product)? Without this,
//  that's guesswork; with it, ItemDetailView (or a future debug screen)
//  can surface the real miss rate and which barcodes are missing.
//
//  Nothing here ever leaves the device — this is UserDefaults-backed, not
//  analytics. It's a bounded ring buffer (most recent N entries) so it
//  can't grow unbounded over months of use.
//

import Foundation

nonisolated enum BarcodeLookupOutcome: Codable, Equatable {
    case hit(source: String)
    case miss
}

nonisolated struct BarcodeLookupEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    let barcode: String
    let outcome: BarcodeLookupOutcome
    let timestamp: Date
}

actor BarcodeLookupTelemetry {

    static let shared = BarcodeLookupTelemetry()

    private let defaults = UserDefaults.standard
    private let key = "StashKeeper.barcodeLookupTelemetry"
    private let maxEntries = 200

    func record(barcode: String, outcome: BarcodeLookupOutcome) {
        var entries = allEntries()
        entries.append(BarcodeLookupEntry(barcode: barcode, outcome: outcome, timestamp: .now))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    func allEntries() -> [BarcodeLookupEntry] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([BarcodeLookupEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Miss count over the recorded window, and which barcodes missed —
    /// the direct answer to "is lookup actually the bottleneck, and for
    /// what."
    func missSummary() -> (missCount: Int, totalCount: Int, missedBarcodes: [String]) {
        let entries = allEntries()
        let misses = entries.filter { $0.outcome == .miss }
        return (misses.count, entries.count, misses.map(\.barcode))
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
