//
//  BarcodeQuickAddView.swift
//  StashKeeper
//
//  Scan a barcode and save it when a catalog or a previous confirmation
//  already knows the name. A photo is only for a code nobody recognizes.
//

import SwiftUI
import SwiftData
@preconcurrency import AVFoundation

struct BarcodeQuickAddView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StorageLocation.name) private var locations: [StorageLocation]
    @Query private var existingItems: [StashItem]

    @State private var scanner = BarcodeCaptureModel()
    @State private var typedCode = ""
    @State private var scannedCode: String?
    @State private var name = ""
    @State private var category = "Pantry & Food"
    @State private var quantity = 1
    @State private var includeExpiry = false
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var location: StorageLocation?
    @State private var lookupSource: String?
    @State private var remembered: LookedUpProduct?
    @State private var isLookingUp = false
    @State private var unknownCode = false
    @State private var status: String?
    @State private var showingCameraFlow = false

    var body: some View {
        NavigationStack {
            Form {
                if CameraCaptureView.isCameraAvailable, scannedCode == nil {
                    Section {
                        CameraPreviewLayer(session: scanner.session)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .listRowInsets(EdgeInsets())
                        Text("Point the camera at the barcode. A known product saves from here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Barcode") {
                    TextField("Type a barcode", text: $typedCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Button("Look up") { Task { await lookup(typedCode) } }
                        .disabled(typedCode.trimmingCharacters(in: .whitespaces).isEmpty || isLookingUp)
                }
                if isLookingUp {
                    Section { ProgressView("Checking catalogs…") }
                }
                if scannedCode != nil {
                    Section("Item") {
                        TextField("Name", text: $name)
                        Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                        Picker("Place", selection: $location) {
                            Text("None").tag(StorageLocation?.none)
                            ForEach(locations) { place in
                                Text(place.name).tag(StorageLocation?.some(place))
                            }
                        }
                        Toggle("This lot has an expiry date", isOn: $includeExpiry)
                        if includeExpiry {
                            DatePicker("Expiry", selection: $expiry, displayedComponents: .date)
                        }
                        if let lookupSource {
                            Text("Matched via \(lookupSource)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if unknownCode {
                            Text("No catalog has this code. Type the name to save it, or photograph the package.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Photograph the package") { showingCameraFlow = true }
                        }
                    }
                    Section {
                        Button("Save to stash") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let status {
                    Section { Text(status) }
                }
            }
            .navigationTitle("Scan Barcode")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                scanner.onCode = { code in
                    Task { await lookup(code) }
                }
                scanner.start()
            }
            .onDisappear { scanner.stop() }
            .sheet(isPresented: $showingCameraFlow) {
                AddItemFlowView()
            }
        }
    }

    private func lookup(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLookingUp = true
        defer { isLookingUp = false }
        scannedCode = trimmed
        typedCode = BarcodeCodes.candidates(from: trimmed).first ?? trimmed
        if let product = await ProductLookupService().lookup(barcode: trimmed) {
            name = product.name
            if let productCategory = product.category, !productCategory.isEmpty {
                category = ItemAnalysis.categoryOptions.contains(productCategory) ? productCategory : "Pantry & Food"
            }
            lookupSource = product.source
            remembered = product
            unknownCode = false
            status = nil
        } else {
            name = ""
            lookupSource = nil
            remembered = nil
            unknownCode = true
            status = nil
        }
    }

    private func save() async {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawCode = scannedCode, !cleanedName.isEmpty else { return }
        let code = BarcodeCodes.candidates(from: rawCode).first ?? rawCode.filter(\.isNumber)
        let expiryDate = includeExpiry ? expiry : nil
        let snapshots = existingItems.map(InventorySnapshotItem.init)
        if let match = ExistingItemMatcher.findMatch(
            barcodePayload: code,
            recognizedText: [],
            candidateName: cleanedName,
            candidateCategory: category,
            candidateExpiry: expiryDate,
            in: snapshots
        ), let existing = modelContext.model(for: match.item.persistentID) as? StashItem {
            existing.quantity += quantity
            existing.noteChange("added \(quantity)")
            try? modelContext.save()
            await StashItemLifecycle.afterEdit(existing, in: modelContext)
            status = "Added \(quantity) to the existing lot of \(existing.name)."
        } else {
            let sameProduct = remembered?.name == cleanedName
            let item = StashItem(
                name: cleanedName,
                category: category,
                quantity: quantity,
                isPerishable: includeExpiry,
                expiryDate: expiryDate,
                location: location,
                barcodePayload: code,
                barcodeLookupSource: lookupSource,
                nutrition: sameProduct ? remembered?.nutrition : nil,
                ingredients: sameProduct ? remembered?.ingredients : nil
            )
            item.noteChange("added \(quantity)")
            modelContext.insert(item)
            try? modelContext.save()
            await StashItemLifecycle.afterEdit(item, in: modelContext)
            status = "Saved \(cleanedName)."
        }
        let sameProduct = remembered?.name == cleanedName
        await IndianFMCGBarcodeCache.shared.learn(ConfirmedPackage(
            barcode: code,
            name: cleanedName,
            category: category,
            nutrition: sameProduct ? remembered?.nutrition : nil,
            ingredients: sameProduct ? remembered?.ingredients : nil,
            wrapperTokens: remembered?.wrapperTokens ?? []
        ))
        StashHaptics.success()
        scannedCode = nil
        name = ""
        unknownCode = false
        scanner.unlock()
    }
}

nonisolated final class BarcodeCaptureModel: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onCode: (String) -> Void = { _ in }
    private var locked = false
    private let queue = DispatchQueue(label: "stashkeeper.barcode")

    func start() {
        guard CameraCaptureView.isCameraAvailable else { return }
        queue.async {
            guard self.session.inputs.isEmpty else {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            #if os(iOS)
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video)
            #else
            let device = AVCaptureDevice.default(for: .video)
            #endif
            guard let device, let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                return
            }
            self.session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else {
                self.session.commitConfiguration()
                return
            }
            self.session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: self.queue)
            output.metadataObjectTypes = output.availableMetadataObjectTypes.filter {
                [.ean13, .ean8, .upce, .qr, .code128, .code39].contains($0)
            }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func unlock() {
        locked = false
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !locked,
              let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue,
              !code.isEmpty else { return }
        locked = true
        let handler = onCode
        DispatchQueue.main.async {
            handler(code)
        }
    }
}
