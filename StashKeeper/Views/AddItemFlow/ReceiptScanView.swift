//
//  ReceiptScanView.swift
//  StashKeeper
//
//  Entry point for "scan a receipt": capture a photo of a bill, extract
//  its line items via ReceiptScanService, and present them as a checklist
//  the user works through one item at a time. Each checklist row launches
//  the existing AddItemFlowView (in receipt-hint mode) to photograph the
//  actual physical item — this view never adds a StashItem on its own,
//  since a receipt line by itself is just a name and a price, not enough
//  to catalog an item the way the rest of this app does (no photo,
//  category confidence, or expiry estimate). The checklist exists to make
//  working through a big shopping trip's items fast and hard to lose
//  track of, not to skip photographing them.
//

import SwiftUI
import PhotosUI

struct ReceiptScanView: View {

    private enum Stage: Equatable {
        case capture
        case extracting
        case checklist
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .capture
    @State private var extraction: ReceiptExtraction?
    /// Which line items the user has already confirmed via photo, keyed by
    /// index into `extraction.items` — persists across repeated
    /// AddItemFlowView presentations so the checklist reflects progress as
    /// the user works through a long receipt.
    @State private var confirmedIndices: Set<Int> = []
    @State private var activeItemIndex: Int?
    @State private var showingHeuristicNotice = false
    #if os(iOS)
    @State private var showingCamera = false
    #endif
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .capture:
                    captureView
                case .extracting:
                    extractingView
                case .checklist:
                    checklistView
                case .failed(let message):
                    failedView(message)
                }
            }
            .navigationTitle("Scan Receipt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stage == .checklist ? "Done" : "Cancel") { dismiss() }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCaptureView { capturedImages in
                    showingCamera = false
                    guard let first = capturedImages.first else { return }
                    Task { await extract(from: first) }
                } onCancel: {
                    showingCamera = false
                }
                .ignoresSafeArea()
            }
            #endif
            #if os(iOS)
            .fullScreenCover(item: activeItemBinding) { prefill in
                AddItemFlowView(receiptItemHint: prefill)
            }
            #else
            .sheet(item: activeItemBinding) { prefill in
                AddItemFlowView(receiptItemHint: prefill)
            }
            #endif
        }
    }

    // MARK: - Capture

    private var captureView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            Text("Photograph your receipt")
                .font(.title2.weight(.semibold))
            Text("Lay the bill flat and capture the whole thing in good light. Apple Intelligence will pull out each purchased item so you can catalog them one by one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()

            VStack(spacing: 12) {
                #if os(iOS)
                if CameraCaptureView.isCameraAvailable {
                    Button {
                        StashHaptics.impact()
                        showingCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                #endif

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                #if os(iOS)
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.borderedProminent)
                #endif
                .controlSize(.large)
                .onChange(of: selectedPhotoItem) { _, newValue in
                    guard let newValue else { return }
                    Task {
                        if let data = try? await newValue.loadTransferable(type: Data.self) {
                            await extract(from: data)
                        }
                        selectedPhotoItem = nil
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Extracting

    private var extractingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Reading your receipt…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Checklist

    private var checklistView: some View {
        VStack(spacing: 0) {
            if showingHeuristicNotice {
                heuristicNoticeBanner
            }

            if let extraction, !extraction.items.isEmpty {
                List {
                    if !extraction.storeName.isEmpty || extraction.purchaseDate != nil {
                        Section {
                            if !extraction.storeName.isEmpty {
                                Text(extraction.storeName).font(.headline)
                            }
                            if let date = extraction.purchaseDate {
                                Text(date, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        ForEach(Array(extraction.items.enumerated()), id: \.offset) { index, item in
                            checklistRow(item: item, index: index)
                        }
                    } header: {
                        Text("\(confirmedIndices.count) of \(extraction.items.count) cataloged")
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Items Found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Couldn't identify any purchased items on this receipt. You can still add items normally from the Dashboard.")
                )
            }
        }
    }

    private func checklistRow(item: ReceiptLineItem, index: Int) -> some View {
        let isConfirmed = confirmedIndices.contains(index)
        return Button {
            StashHaptics.impact()
            activeItemIndex = index
        } label: {
            HStack {
                Image(systemName: isConfirmed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isConfirmed ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline)
                        .strikethrough(isConfirmed)
                        .foregroundStyle(isConfirmed ? .secondary : .primary)
                    if let price = item.price {
                        Text("Qty \(item.quantity) · \(price, format: .number.precision(.fractionLength(2)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "camera")
                    .foregroundStyle(.blue)
            }
        }
        .buttonStyle(.plain)
    }

    private var activeItemBinding: Binding<AddItemFlowView.ReceiptItemPrefill?> {
        Binding(
            get: {
                guard let index = activeItemIndex, let extraction, extraction.items.indices.contains(index) else {
                    return nil
                }
                let item = extraction.items[index]
                let currency = extraction.currency.isEmpty ? "INR" : extraction.currency
                return AddItemFlowView.ReceiptItemPrefill(
                    name: item.name,
                    priceAmount: item.price,
                    priceCurrency: currency,
                    category: item.category
                )
            },
            set: { newValue in
                if newValue == nil, let index = activeItemIndex {
                    // Sheet dismissed — mark this line confirmed. We can't
                    // tell from here whether the user actually saved an
                    // item or just backed out, so this is optimistic; the
                    // worst case is a checklist row shown as done when the
                    // user changed their mind, which they can still
                    // re-open and photograph again since tapping a
                    // confirmed row still works.
                    confirmedIndices.insert(index)
                    activeItemIndex = nil
                }
            }
        )
    }

    // MARK: - Failure

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                stage = .capture
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var heuristicNoticeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Apple Intelligence isn't available, so items were extracted with simpler logic — double-check names and prices before confirming.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    // MARK: - Extraction

    private func extract(from imageData: Data) async {
        stage = .extracting
        do {
            let result = try await ReceiptScanService.shared.extractLineItems(from: imageData)
            if ReceiptScanService.shared.lastExtractionWasHeuristic {
                showingHeuristicNotice = true
            }
            extraction = result
            stage = .checklist
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't read this receipt. Please try again.")
        }
    }
}
