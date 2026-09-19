//
//  AddItemFlowView.swift
//  StashKeeper
//
//  The core capture flow: user selects one or more photos and/or videos ->
//  each source is analyzed (video frames are extracted first) -> Vision
//  proposes item regions per source -> Foundation Models analyzes all
//  regions from a source together -> user reviews detections via tappable
//  bounding box overlays (toggle include/exclude, edit) -> confirmed items
//  are saved as separate StashItems.
//

import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct AddItemFlowView: View {

    enum Stage {
        case capture
        case analyzing(progress: String)
        case review
        case failed(String)
    }

    /// A simple comparable identifier for the current stage, since `Stage`
    /// carries associated values with differing payloads and can't easily
    /// be made `Equatable` for use as an `.animation(value:)` trigger.
    private var stageID: Int {
        switch stage {
        case .capture: return 0
        case .analyzing: return 1
        case .review: return 2
        case .failed: return 3
        }
    }

    /// A single receipt line item's name/price, carried into the capture
    /// flow as a hint when confirming that item via a fresh photo.
    struct ReceiptItemPrefill: Sendable, Identifiable {
        let id = UUID()
        let name: String
        let priceAmount: Double?
        let priceCurrency: String
        let category: String

        var promptDescription: String {
            let priceText = priceAmount.map { "priced around \($0) \(priceCurrency)" } ?? "no clear price"
            return "\"\(name)\" (\(priceText))"
        }
    }

    /// One source image (either a photo directly, or a frame extracted from
    /// a selected video) along with its detected/analyzed candidates.
    struct SourceResult: Identifiable {
        let id = UUID()
        var imageData: Data
        var candidates: [DetectionOverlayView.Candidate]
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]
    @Query private var existingItems: [StashItem]

    /// Set when this flow was launched from the receipt scan checklist to
    /// confirm one specific line item via photo — carries the receipt's
    /// name/price as a soft hint (shown to the user and passed to AFM),
    /// not a hard override, since the photographed item is still the
    /// actual source of truth.
    let receiptItemHint: ReceiptItemPrefill?

    init(receiptItemHint: ReceiptItemPrefill? = nil) {
        self.receiptItemHint = receiptItemHint
    }

    @State private var stage: Stage = .capture
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var sourceResults: [SourceResult] = []
    @State private var editingCandidate: (sourceIndex: Int, candidateIndex: Int)?
    @State private var showingCamera = false

    // Per-candidate editable fields keyed by candidate id, populated on demand.
    @State private var quantityByCandidate: [UUID: Int] = [:]
    @State private var locationByCandidate: [UUID: StorageLocation?] = [:]
    @State private var newLocationNameByCandidate: [UUID: String] = [:]
    @State private var expiryDateByCandidate: [UUID: Date] = [:]
    /// (amount, currencyCode, wasAutoDetected)
    @State private var priceByCandidate: [UUID: (amount: Double, currency: String, autoDetected: Bool)] = [:]
    @State private var barcodeByCandidate: [UUID: String?] = [:]
    @State private var barcodeSourceByCandidate: [UUID: String?] = [:]
    /// Flattened OCR text per candidate, kept around so the cross-photo
    /// duplicate/angle detection pass and the item detail "Text Found on
    /// Item" section can reference it without re-running Vision.
    @State private var recognizedTextByCandidate: [UUID: [String]] = [:]
    /// Tracks whether the user chose to treat a candidate's detected
    /// `existingItemMatch` as "yes, update the existing item" (true) or
    /// "no, this is genuinely a separate new item" (false). Absent entries
    /// default to following the match's own confidence (exact/strong
    /// matches default to merge; weak name-only matches default to saving
    /// as new, since a weak match is meant purely as an FYI, not an
    /// assumption).
    @State private var mergeIntoExistingDecision: [UUID: Bool] = [:]
    /// Recipe suggestions generated when enough fresh produce was detected
    /// in this session — populated asynchronously after the review screen
    /// is already showing (see RecipeSuggestionService), so this stays
    /// empty until/unless suggestions come back. Presented as a banner the
    /// user can tap to see full suggestions, dismissible either way.
    @State private var recipeSuggestions: [RecipeSuggestion] = []
    @State private var showingRecipeSuggestions = false

    private let visionAnalyzer = VisionAnalyzer()
    private let videoFrameExtractor = VideoFrameExtractor()
    private let barcodeScanner = BarcodeScanner()
    private let productLookupService = ProductLookupService()

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .capture:
                    captureStageView
                case .analyzing(let progress):
                    analyzingStageView(progress: progress)
                case .review:
                    reviewStageView
                case .failed(let message):
                    failedStageView(message)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: stageID)
            .navigationTitle("Add Items")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        StashScanActivityController.shared.end()
                        dismiss()
                    }
                }
                if case .review = stage {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save (\(includedCount))") { saveAll() }
                            .fontWeight(.semibold)
                            .disabled(includedCount == 0)
                    }
                }
            }
            .sheet(isPresented: $showingRecipeSuggestions) {
                RecipeSuggestionsSheet(suggestions: recipeSuggestions)
                    .sheetPopIn()
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingCamera) {
                cameraCaptureSheet
                    .ignoresSafeArea()
            }
            #else
            .sheet(isPresented: $showingCamera) {
                cameraCaptureSheet
                    .frame(minWidth: 640, minHeight: 480)
            }
            #endif
        }
        .sheet(item: editingCandidateBinding) { editing in
            candidateEditSheet(sourceIndex: editing.sourceIndex, candidateIndex: editing.candidateIndex)
                .sheetPopIn()
        }
    }

    private var cameraCaptureSheet: some View {
        CameraCaptureView { capturedImages in
            showingCamera = false
            guard !capturedImages.isEmpty else { return }
            Task { await analyzeAllSources(capturedImages) }
        } onCancel: {
            showingCamera = false
        }
    }

    // MARK: - Capture stage

    private var captureStageView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: receiptItemHint == nil ? "camera.viewfinder" : "cart.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.4))

            if let hint = receiptItemHint {
                Text("Photograph: \(hint.name)")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text("From your receipt scan. Take a photo of the actual item so it can be cataloged with an accurate name, category, and expiry.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("Add photos or a video")
                    .font(.title2.weight(.semibold))
                Text("Apple Intelligence identifies every item it can find — even multiple products in one photo — and estimates expiry dates for perishables.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
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

                PhotosPicker(
                    selection: $photoPickerItems,
                    maxSelectionCount: 10,
                    matching: .any(of: [.images, .videos])
                ) {
                    Label("Choose Photos or Video", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                #if os(iOS)
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.borderedProminent)
                #endif
                .controlSize(.large)

                Text("Take a photo now, or select up to 10 photos, or a video panning across your items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .onChange(of: photoPickerItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            Task { await handleSelection(newValue) }
        }
    }

    private func handleSelection(_ items: [PhotosPickerItem]) async {
        stage = .analyzing(progress: "Loading selection…")

        var imageDatas: [Data] = []

        for (index, item) in items.enumerated() {
            stage = .analyzing(progress: "Loading item \(index + 1) of \(items.count)…")

            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }

            if isVideo {
                guard let movie = try? await item.loadTransferable(type: MovieFile.self) else { continue }
                stage = .analyzing(progress: "Extracting best frames from video…")
                if let frames = try? await videoFrameExtractor.extractBestFrames(from: movie.url) {
                    imageDatas.append(contentsOf: frames)
                }
                try? FileManager.default.removeItem(at: movie.url)
            } else {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    imageDatas.append(data)
                }
            }
        }

        guard !imageDatas.isEmpty else {
            stage = .failed("Couldn't load the selected items. Please try again.")
            return
        }

        await analyzeAllSources(imageDatas)
    }

    // MARK: - Analysis

    private func analyzeAllSources(_ imageDatas: [Data]) async {
        var results: [SourceResult] = []
        var totalItemsFoundSoFar = 0

        StashScanActivityController.shared.start(totalPhotoCount: imageDatas.count)

        for (index, imageData) in imageDatas.enumerated() {
            let progressMessage = "Analyzing photo \(index + 1) of \(imageDatas.count)…"
            stage = .analyzing(progress: progressMessage)
            StashScanActivityController.shared.updateProgress(
                photoIndex: index,
                totalPhotoCount: imageDatas.count,
                message: progressMessage,
                itemsFoundSoFar: totalItemsFoundSoFar
            )

            do {
                let observations = try await visionAnalyzer.analyze(imageData: imageData)
                let barcodes = (try? await barcodeScanner.scan(imageData: imageData)) ?? []

                var regionInputs: [RegionAnalysisInput] = []
                for region in observations.regions {
                    var input = RegionAnalysisInput(
                        id: region.id,
                        normalizedBoundingBox: region.normalizedBoundingBox,
                        classificationLabels: region.classificationLabels,
                        recognizedText: region.recognizedText,
                        priceHints: PriceHintExtractor.extractPriceHints(from: region.recognizedText)
                    )

                    if let nearestBarcode = await barcodeScanner.nearestBarcode(
                        to: region.normalizedBoundingBox, in: barcodes
                    ) {
                        input.barcodePayload = nearestBarcode.payload
                        // Barcode lookup only kicks in as a fallback grounding
                        // signal — Apple Intelligence still makes the final
                        // call, but having a real product name/category from
                        // a database dramatically improves accuracy for
                        // packaged goods where visual classification alone
                        // is weak (e.g. two similar-looking snack bags).
                        stage = .analyzing(progress: "Looking up scanned barcode…")
                        input.lookedUpProduct = await productLookupService.lookup(barcode: nearestBarcode.payload)
                    }

                    regionInputs.append(input)
                }

                stage = .analyzing(progress: progressMessage)

                let analyses: [ItemAnalysis]
                var usedHeuristicFallback = false
                do {
                    analyses = try await ItemIntelligenceService.shared.analyzeRegions(
                        regionInputs,
                        globalRecognizedText: observations.globalRecognizedText,
                        existingLocationNames: locations.map(\.name),
                        existingItems: existingItems,
                        expectedItemHint: receiptItemHint?.promptDescription,
                        sourceImageData: imageData
                    )
                    usedHeuristicFallback = ItemIntelligenceService.shared.lastUsedTier == .heuristicOnly
                } catch {
                    // A genuine generation failure (not just "no AI tier
                    // available" — analyzeRegions already routes that case
                    // through HeuristicItemNamer internally and doesn't
                    // throw for it). Fall back to the same zero-AI
                    // heuristic tier here too, so a mid-session failure
                    // degrades exactly the same way an ineligible device
                    // would, rather than a different, cruder fallback path.
                    usedHeuristicFallback = true
                    analyses = regionInputs.map(HeuristicItemNamer.analyze)
                }

                var candidates: [DetectionOverlayView.Candidate] = []
                let existingSnapshots = existingItems.map(InventorySnapshotItem.init)
                for (index2, (region, analysis)) in zip(observations.regions, analyses).enumerated() {
                    let input = regionInputs[index2]
                    let existingMatch = ExistingItemMatcher.findMatch(
                        barcodePayload: input.barcodePayload,
                        recognizedText: region.recognizedText.map(\.text),
                        candidateName: analysis.name,
                        candidateCategory: analysis.category,
                        in: existingSnapshots
                    )
                    let candidate = DetectionOverlayView.Candidate(
                        id: region.id,
                        boundingBox: region.normalizedBoundingBox,
                        analysis: analysis,
                        isIncluded: true,
                        existingItemMatch: existingMatch,
                        isHeuristicEstimate: usedHeuristicFallback
                    )
                    candidates.append(candidate)

                    quantityByCandidate[region.id] = 1
                    expiryDateByCandidate[region.id] = analysis.estimatedExpiryDate ?? .now
                    if !analysis.suggestedLocationHint.isEmpty {
                        let match = locations.first {
                            $0.name.localizedCaseInsensitiveCompare(analysis.suggestedLocationHint) == .orderedSame
                        }
                        locationByCandidate[region.id] = match
                        newLocationNameByCandidate[region.id] = match == nil ? analysis.suggestedLocationHint : ""
                    }
                    if let price = analysis.detectedPrice, !analysis.detectedPriceCurrency.isEmpty {
                        priceByCandidate[region.id] = (price, analysis.detectedPriceCurrency, true)
                    } else if let hint = receiptItemHint, let hintPrice = hint.priceAmount {
                        // The photographed item's packaging didn't yield a
                        // readable price, but the receipt already told us
                        // one — use it rather than leaving price blank,
                        // marked as not-auto-detected-from-this-photo so
                        // the UI can still let the user know where it came
                        // from if it matters.
                        priceByCandidate[region.id] = (hintPrice, hint.priceCurrency, false)
                    }
                    barcodeByCandidate[region.id] = input.barcodePayload
                    barcodeSourceByCandidate[region.id] = input.lookedUpProduct?.source
                    recognizedTextByCandidate[region.id] = region.recognizedText.map(\.text)
                }

                totalItemsFoundSoFar += candidates.filter { $0.isIncluded && !$0.mergedIntoAnotherCandidate }.count
                results.append(SourceResult(imageData: imageData, candidates: candidates))
            } catch {
                // Skip sources Vision couldn't process at all; continue with
                // whatever else was selected rather than failing everything.
                continue
            }
        }

        guard !results.isEmpty else {
            StashScanActivityController.shared.end()
            stage = .failed("Couldn't analyze the selected photos. Please try again.")
            return
        }

        stage = .analyzing(progress: "Checking for repeated items…")
        results = await mergeDuplicateAngles(in: results)

        sourceResults = results
        stage = .review
        StashScanActivityController.shared.finish(totalItemsFound: totalItemsFoundSoFar)

        // Offer recipe suggestions when enough fresh produce was detected
        // across this session's photos — runs after the review screen is
        // already showing, since this is a nice-to-have addition, not
        // something worth delaying the core flow for.
        let allAnalyses = results.flatMap { $0.candidates.filter { $0.isIncluded && !$0.mergedIntoAnotherCandidate }.map(\.analysis) }
        if RecipeSuggestionService.hasEnoughProduceForSuggestion(allAnalyses) {
            Task {
                var fitnessContext: FitnessContext?
                #if os(iOS)
                if let summary = await HealthKitService.shared.fetchTodayFitnessSummary() {
                    fitnessContext = FitnessContext(
                        approximateSteps: summary.approximateSteps,
                        approximateActiveEnergyBurned: summary.approximateActiveEnergyBurned,
                        approximateDietaryEnergyConsumed: summary.approximateDietaryEnergyConsumed
                    )
                }
                #endif
                let suggestions = await RecipeSuggestionService.shared.suggestRecipes(
                    for: allAnalyses,
                    fitnessContext: fitnessContext
                )
                if !suggestions.isEmpty {
                    recipeSuggestions = suggestions
                }
            }
        }
    }

    /// Detects candidates across DIFFERENT source photos that are actually
    /// the same physical item photographed from another angle, and merges
    /// each such group into a single candidate (kept at its first
    /// occurrence's position, with the other photos' image data attached
    /// via `mergedAnglePhotos` so all angles get saved together). Only
    /// considers candidates that are still `isIncluded` and only ever
    /// merges across DIFFERENT sources — two genuinely separate items
    /// sitting next to each other within the SAME photo are never merged,
    /// since those are already known to be distinct regions.
    private func mergeDuplicateAngles(in results: [SourceResult]) async -> [SourceResult] {
        // Flatten every candidate across every source into one indexed list
        // for the model, remembering how to map each flat index back to
        // its (sourceIndex, candidateIndex) origin.
        var flatOrigins: [(sourceIndex: Int, candidateIndex: Int)] = []
        var summaries: [CrossPhotoCandidateSummary] = []

        for (sourceIndex, source) in results.enumerated() {
            for (candidateIndex, candidate) in source.candidates.enumerated() {
                let flatIndex = flatOrigins.count
                flatOrigins.append((sourceIndex, candidateIndex))
                summaries.append(CrossPhotoCandidateSummary(
                    index: flatIndex,
                    name: candidate.analysis.name,
                    category: candidate.analysis.category,
                    subcategory: candidate.analysis.subcategory,
                    tags: candidate.analysis.tags,
                    barcodePayload: barcodeByCandidate[candidate.id] ?? nil,
                    recognizedText: recognizedTextByCandidate[candidate.id] ?? []
                ))
            }
        }

        guard summaries.count > 1 else { return results }

        let rawGroups = await ItemIntelligenceService.shared.detectDuplicateAngles(summaries)

        // Only keep groups whose members span more than one source photo —
        // same-photo grouping isn't meaningful here since Vision already
        // separated those into distinct regions on purpose.
        let crossPhotoGroups = rawGroups.filter { group in
            Set(group.map { flatOrigins[$0].sourceIndex }).count > 1
        }

        guard !crossPhotoGroups.isEmpty else { return results }

        var results = results
        var mergedAwayIDs = Set<UUID>() // candidate ids absorbed into another candidate

        for group in crossPhotoGroups {
            // Keep the first-appearing candidate (lowest flat index) as the
            // surviving one; fold the rest's photo data into it.
            let sortedGroup = group.sorted()
            guard let primaryFlatIndex = sortedGroup.first else { continue }
            let primaryOrigin = flatOrigins[primaryFlatIndex]
            let primaryID = results[primaryOrigin.sourceIndex].candidates[primaryOrigin.candidateIndex].id

            guard !mergedAwayIDs.contains(primaryID) else { continue }

            for flatIndex in sortedGroup.dropFirst() {
                let origin = flatOrigins[flatIndex]
                let absorbedCandidate = results[origin.sourceIndex].candidates[origin.candidateIndex]
                guard absorbedCandidate.isIncluded, !mergedAwayIDs.contains(absorbedCandidate.id) else { continue }

                let absorbedPhotoData = results[origin.sourceIndex].imageData
                results[primaryOrigin.sourceIndex].candidates[primaryOrigin.candidateIndex]
                    .mergedAnglePhotos.append(absorbedPhotoData)
                results[primaryOrigin.sourceIndex].candidates[primaryOrigin.candidateIndex]
                    .mergedAnglePhotos.append(contentsOf: absorbedCandidate.mergedAnglePhotos)

                // Mark the absorbed candidate as merged into the primary
                // rather than excluding it outright — this renders
                // distinctly in the review UI (a dashed purple "same as
                // another photo" box) instead of looking like a rejected
                // detection, and keeps it out of includedCount/saveAll
                // since saveAll only considers isIncluded && !merged.
                results[origin.sourceIndex].candidates[origin.candidateIndex].mergedIntoAnotherCandidate = true
                mergedAwayIDs.insert(absorbedCandidate.id)
            }
        }

        return results
    }

    private func analyzingStageView(progress: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse.byLayer, options: .repeating)
            ProgressView()
                .controlSize(.large)
            Text(progress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .id(progress)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: progress)
            Spacer()
        }
        .padding()
        .transition(.opacity)
    }

    // MARK: - Review stage

    private var reviewStageView: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                if !recipeSuggestions.isEmpty {
                    Button {
                        showingRecipeSuggestions = true
                    } label: {
                        Label("Recipe ideas for what you just added", systemImage: "fork.knife")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .buttonStyle(.pressScale)
                    .glassSurface(cornerRadius: 12)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ForEach(Array(sourceResults.enumerated()), id: \.element.id) { sourceIndex, source in
                    VStack(alignment: .leading, spacing: 8) {
                        let visibleCount = source.candidates.filter { !$0.mergedIntoAnotherCandidate }.count
                        Text("Photo \(sourceIndex + 1) — \(visibleCount) item\(visibleCount == 1 ? "" : "s") found")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        DetectionOverlayView(
                            imageData: source.imageData,
                            candidates: candidatesBinding(for: sourceIndex),
                            onEditCandidate: { candidate in
                                if let candidateIndex = sourceResults[sourceIndex].candidates.firstIndex(where: { $0.id == candidate.id }) {
                                    editingCandidate = (sourceIndex, candidateIndex)
                                }
                            }
                        )
                        .padding(.horizontal)

                        Text("Tap a box to include/exclude it. Tap the pencil to edit details. Dashed purple boxes were merged as another angle of a nearby photo's item — tap to split them back out.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        if source.candidates.contains(where: { $0.isHeuristicEstimate && $0.isIncluded }) {
                            Label("Apple Intelligence isn't available on this device — names and categories below are rough estimates from barcode/text scanning only. Please double check before saving.", systemImage: "wand.and.stars.inverse")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassSurface(cornerRadius: 10)
                                .padding(.horizontal)
                        }

                        ForEach(source.candidates.filter { $0.isIncluded && !$0.mergedIntoAnotherCandidate && $0.existingItemMatch != nil }) { candidate in
                            existingItemMatchCard(for: candidate)
                                .padding(.horizontal)
                        }
                    }
                }
            }
            .animation(.stashSpring, value: recipeSuggestions.count)
            .padding(.vertical)
        }
    }

    /// A notice shown when a candidate deterministically matches an item
    /// already in the persisted inventory (see `ExistingItemMatcher`) —
    /// this is the direct fix for the AI silently treating a re-scanned,
    /// already-cataloged item as brand new. Lets the user pick "update
    /// existing" (bumps quantity on the real existing item, this candidate
    /// won't be saved as a new row) or "keep as new" (saves normally,
    /// dismissing the suggestion for this candidate only).
    private func existingItemMatchCard(for candidate: DetectionOverlayView.Candidate) -> some View {
        guard let match = candidate.existingItemMatch else { return AnyView(EmptyView()) }
        let wantsMerge = mergeIntoExistingDecision[candidate.id] ?? (match.confidence != .weak)

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Already in your inventory?")
                            .font(.subheadline.weight(.semibold))
                        Text("\"\(candidate.analysis.name)\" — \(match.reason). Currently have \(match.item.quantity) in \(match.item.locationName ?? "Unspecified").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: match.confidence == .exact ? "checkmark.seal.fill" : "questionmark.circle.fill")
                        .foregroundStyle(match.confidence == .exact ? .green : .orange)
                }

                Picker("", selection: Binding(
                    get: { wantsMerge },
                    set: { newValue in
                        StashHaptics.impact()
                        mergeIntoExistingDecision[candidate.id] = newValue
                    }
                )) {
                    Text("Update existing (+\(quantityByCandidate[candidate.id] ?? 1))").tag(true)
                    Text("This is a new, separate item").tag(false)
                }
                .pickerStyle(.segmented)
            }
            .padding(12)
            .glassSurface(cornerRadius: 12)
        )
    }

    private func candidatesBinding(for sourceIndex: Int) -> Binding<[DetectionOverlayView.Candidate]> {
        Binding(
            get: { sourceResults[sourceIndex].candidates },
            set: { sourceResults[sourceIndex].candidates = $0 }
        )
    }

    private var includedCount: Int {
        sourceResults.reduce(0) { $0 + $1.candidates.filter { $0.isIncluded && !$0.mergedIntoAnotherCandidate }.count }
    }

    // MARK: - Per-candidate edit sheet plumbing

    private var editingCandidateBinding: Binding<EditingCandidateID?> {
        Binding(
            get: {
                guard let editingCandidate else { return nil }
                return EditingCandidateID(sourceIndex: editingCandidate.sourceIndex, candidateIndex: editingCandidate.candidateIndex)
            },
            set: { newValue in
                editingCandidate = newValue.map { ($0.sourceIndex, $0.candidateIndex) }
            }
        )
    }

    private struct EditingCandidateID: Identifiable {
        let sourceIndex: Int
        let candidateIndex: Int
        var id: String { "\(sourceIndex)-\(candidateIndex)" }
    }

    private func candidateEditSheet(sourceIndex: Int, candidateIndex: Int) -> some View {
        guard sourceResults.indices.contains(sourceIndex),
              sourceResults[sourceIndex].candidates.indices.contains(candidateIndex) else {
            return AnyView(
                Text("This item is no longer available.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .onAppear { editingCandidate = nil }
            )
        }

        let candidate = sourceResults[sourceIndex].candidates[candidateIndex]
        let candidateID = candidate.id

        return AnyView(ItemCandidateEditView(
            analysis: Binding(
                get: { sourceResults[sourceIndex].candidates[candidateIndex].analysis },
                set: { sourceResults[sourceIndex].candidates[candidateIndex].analysis = $0 }
            ),
            quantity: Binding(
                get: { quantityByCandidate[candidateID] ?? 1 },
                set: { quantityByCandidate[candidateID] = $0 }
            ),
            selectedLocation: Binding(
                get: { locationByCandidate[candidateID] ?? nil },
                set: { locationByCandidate[candidateID] = $0 }
            ),
            newLocationName: Binding(
                get: { newLocationNameByCandidate[candidateID] ?? "" },
                set: { newLocationNameByCandidate[candidateID] = $0 }
            ),
            expiryDate: Binding(
                get: { expiryDateByCandidate[candidateID] ?? .now },
                set: { expiryDateByCandidate[candidateID] = $0 }
            ),
            price: Binding(
                get: { priceByCandidate[candidateID] },
                set: { priceByCandidate[candidateID] = $0 }
            ),
            barcodePayload: barcodeByCandidate[candidateID] ?? nil,
            barcodeLookupSource: barcodeSourceByCandidate[candidateID] ?? nil,
            recognizedText: recognizedTextByCandidate[candidateID] ?? []
        ))
    }

    // MARK: - Failure fallback

    private func failedStageView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                photoPickerItems = []
                sourceResults = []
                stage = .capture
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Save

    private func saveAll() {
        for source in sourceResults {
            for candidate in source.candidates where candidate.isIncluded && !candidate.mergedIntoAnotherCandidate {
                if let match = candidate.existingItemMatch,
                   mergeIntoExistingDecision[candidate.id] ?? (match.confidence != .weak) {
                    mergeIntoExistingItem(candidate, match: match, sourceImageData: source.imageData)
                } else {
                    saveCandidate(candidate, sourceImageData: source.imageData)
                }
            }
        }
        try? modelContext.save()
        ItemIntelligenceService.shared.invalidateSessions()
        reloadWidgets()
        dismiss()
    }

    /// Applies a candidate the user confirmed is "the same item I already
    /// have" onto the real existing StashItem instead of creating a new
    /// row: bumps quantity by the scanned amount and, if this scan added a
    /// new photo angle or filled in a previously-missing price, folds
    /// those in too. This is the direct fix for re-scanning an
    /// already-cataloged item (e.g. checking its serial number again)
    /// resulting in a duplicate inventory entry.
    private func mergeIntoExistingItem(
        _ candidate: DetectionOverlayView.Candidate,
        match: ExistingItemMatcher.Match,
        sourceImageData: Data
    ) {
        guard let existingItem = modelContext.model(for: match.item.persistentID) as? StashItem else {
            // The matched item vanished (e.g. deleted between analysis and
            // save) — fall back to saving as a normal new item rather than
            // silently dropping the user's scan.
            saveCandidate(candidate, sourceImageData: sourceImageData)
            return
        }

        let scannedQuantity = quantityByCandidate[candidate.id] ?? 1
        existingItem.quantity += scannedQuantity
        existingItem.updatedAt = .now

        // A fresh scan's price is generally more current than whatever was
        // recorded before, so prefer it when this scan actually found one.
        if let priceInfo = priceByCandidate[candidate.id] {
            existingItem.priceAmount = priceInfo.amount
            existingItem.priceCurrency = priceInfo.currency
            existingItem.priceDetectedAutomatically = priceInfo.autoDetected
        }

        // Fill in barcode / lookup source if the existing row lacked them.
        if existingItem.barcodePayload == nil || existingItem.barcodePayload?.isEmpty == true,
           let payload = barcodeByCandidate[candidate.id] ?? nil,
           !payload.isEmpty {
            existingItem.barcodePayload = payload
            existingItem.barcodeLookupSource = barcodeSourceByCandidate[candidate.id] ?? nil
        }

        // Prefer a newer expiry when the user confirmed or AI found one.
        if candidate.analysis.isPerishable,
           let newExpiry = expiryDateByCandidate[candidate.id] {
            existingItem.isPerishable = true
            existingItem.expiryDate = newExpiry
            existingItem.expiryConfidence = candidate.analysis.expiryConfidence
            Task { await ExpiryEngine.shared.syncNotifications(for: existingItem) }
        }

        // Attach this scan's photo as an additional angle when save succeeds.
        if let filename = try? PhotoStore.save(imageData: sourceImageData) {
            existingItem.photoFilenames.append(filename)
        }
        for anglePhotoData in candidate.mergedAnglePhotos {
            if let filename = try? PhotoStore.save(imageData: anglePhotoData) {
                existingItem.photoFilenames.append(filename)
            }
        }

        StashHaptics.success()
    }

    private func saveCandidate(_ candidate: DetectionOverlayView.Candidate, sourceImageData: Data) {
        let analysis = candidate.analysis

        var location = locationByCandidate[candidate.id] ?? nil
        let trimmedNewLocation = (newLocationNameByCandidate[candidate.id] ?? "").trimmingCharacters(in: .whitespaces)
        if location == nil, !trimmedNewLocation.isEmpty {
            let newLocation = StorageLocation(name: trimmedNewLocation)
            modelContext.insert(newLocation)
            location = newLocation
        }

        var photoFilenames: [String] = []
        if let filename = try? PhotoStore.save(imageData: sourceImageData) {
            photoFilenames = [filename]
        }
        for anglePhotoData in candidate.mergedAnglePhotos {
            if let filename = try? PhotoStore.save(imageData: anglePhotoData) {
                photoFilenames.append(filename)
            }
        }

        let quantity = quantityByCandidate[candidate.id] ?? 1
        let expiryDate = expiryDateByCandidate[candidate.id] ?? .now
        let priceInfo = priceByCandidate[candidate.id]

        let item = StashItem(
            name: analysis.name,
            category: analysis.category,
            subcategory: analysis.subcategory.isEmpty ? nil : analysis.subcategory,
            quantity: quantity,
            isPerishable: analysis.isPerishable,
            expiryDate: analysis.isPerishable ? expiryDate : nil,
            expiryConfidence: analysis.expiryConfidence,
            notes: analysis.ripenessNote.isEmpty ? nil : analysis.ripenessNote,
            recognizedText: recognizedTextByCandidate[candidate.id]?.joined(separator: "\n"),
            tags: analysis.tags,
            location: location,
            photoFilenames: photoFilenames,
            priceAmount: priceInfo?.amount,
            priceCurrency: priceInfo?.currency,
            priceDetectedAutomatically: priceInfo?.autoDetected ?? false,
            barcodePayload: barcodeByCandidate[candidate.id] ?? nil,
            barcodeLookupSource: barcodeSourceByCandidate[candidate.id] ?? nil,
            nutrition: analysis.hasUsableNutrition ? analysis.nutrition : nil
        )

        modelContext.insert(item)
        Task { await ExpiryEngine.shared.syncNotifications(for: item) }

        // If this candidate had a scanned barcode but no online/local
        // database recognized it, the user's confirmed name at save time
        // is the best signal we'll ever get for that product — teach the
        // local Indian FMCG cache so re-scanning the same item resolves
        // instantly next time instead of repeating the same round trip
        // and coming up empty again.
        let lookupSource: String? = barcodeSourceByCandidate[candidate.id] ?? nil
        if let payload = barcodeByCandidate[candidate.id] ?? nil, !payload.isEmpty,
           lookupSource == nil {
            Task {
                await IndianFMCGBarcodeCache.shared.learn(
                    barcode: payload, name: item.name, category: item.category
                )
            }
        }

        // Nutrition is NOT auto-written to Health on save. HealthKit only
        // models "food consumed," not "food stored," so auto-logging at
        // stash time pollutes calorie/macro totals. Users can sync
        // deliberately from Item Detail via "Log nutrition to Health".
    }
}

/// Transferable wrapper for loading a picked video into a temporary file URL.
private struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MovieFile(url: destination)
        }
    }
}

#Preview {
    AddItemFlowView()
        .modelContainer(for: [StashItem.self, StorageLocation.self, StreakRecord.self], inMemory: true)
}
