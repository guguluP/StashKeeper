//
//  CameraCaptureView.swift
//  StashKeeper
//
//  Multi-shot camera for the Add Items flow on iOS and macOS.
//

import SwiftUI
@preconcurrency import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct CameraCaptureView: View {
    let onFinish: ([Data]) -> Void
    let onCancel: () -> Void

    @State private var model = CameraCaptureModel()

    static var isCameraAvailable: Bool {
        #if os(iOS)
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(for: .video) != nil
        #else
        AVCaptureDevice.default(for: .video) != nil
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewLayer(session: model.session)
                .ignoresSafeArea()
                .opacity(model.isAuthorized ? 1 : 0)

            if !model.isAuthorized {
                cameraUnavailableView
            }

            VStack {
                topBar
                Spacer()
                if !model.capturedThumbnails.isEmpty {
                    filmstrip
                }
                shutterBar
            }
        }
        #if os(iOS)
        .statusBarHidden()
        #endif
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var topBar: some View {
        HStack {
            Button {
                StashHaptics.impact()
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            if !model.capturedThumbnails.isEmpty {
                Text("\(model.capturedThumbnails.count) captured")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
            }
        }
        .padding()
        .padding(.top, 8)
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.capturedThumbnails.enumerated()), id: \.offset) { _, thumb in
                    thumb.image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
                        }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 12)
    }

    private var shutterBar: some View {
        HStack {
            Color.clear.frame(width: 64, height: 64)
            Spacer()
            Button {
                model.capturePhoto()
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 72, height: 72)
                    Circle().strokeBorder(.white, lineWidth: 3).frame(width: 84, height: 84)
                }
            }
            .buttonStyle(.plain)
            .scaleEffect(model.isCapturing ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: model.isCapturing)
            .disabled(!model.isAuthorized)
            Spacer()
            Button {
                StashHaptics.success()
                onFinish(model.capturedImageDatas)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30))
                    Text("Done").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(model.capturedThumbnails.isEmpty ? .white.opacity(0.35) : .green)
            }
            .buttonStyle(.plain)
            .disabled(model.capturedThumbnails.isEmpty)
            .frame(width: 64, height: 64)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 36)
    }

    private var cameraUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.6))
            Text("Camera access is needed to take photos")
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
        .padding(32)
    }
}

nonisolated struct CaptureThumbnail: Identifiable {
    let id = UUID()
    let image: Image
}

nonisolated private final class CameraSessionCoordinator: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.stashkeeper.cameracapture")
    private var onPhotoCaptured: ((Data?) -> Void)?

    func requestAccessAndStart(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else {
                completion(granted)
                return
            }
            self.sessionQueue.async {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                #if os(iOS)
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video)
                #else
                let device = AVCaptureDevice.default(for: .video)
                #endif
                if let device,
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                if self.session.canAddOutput(self.output) {
                    self.session.addOutput(self.output)
                }
                self.session.commitConfiguration()
                self.session.startRunning()
                completion(true)
            }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            session.stopRunning()
        }
    }

    func capturePhoto(completion: @escaping (Data?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            self.onPhotoCaptured = completion
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = (error == nil) ? photo.fileDataRepresentation() : nil
        let completion = onPhotoCaptured
        onPhotoCaptured = nil
        completion?(data)
    }
}

@MainActor
@Observable
private final class CameraCaptureModel {
    private let coordinator = CameraSessionCoordinator()
    var session: AVCaptureSession { coordinator.session }

    var isAuthorized = false
    var isCapturing = false
    var capturedThumbnails: [CaptureThumbnail] = []
    private(set) var capturedImageDatas: [Data] = []

    func start() {
        coordinator.requestAccessAndStart { [weak self] granted in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    func stop() {
        coordinator.stop()
    }

    func capturePhoto() {
        guard !isCapturing else { return }
        isCapturing = true
        StashHaptics.impact()
        coordinator.capturePhoto { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                guard let data else { return }
                self.capturedImageDatas.append(data)
                if let image = Self.makeThumbnail(from: data) {
                    self.capturedThumbnails.append(CaptureThumbnail(image: image))
                }
            }
        }
    }

    private static func makeThumbnail(from data: Data) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(data: data) { return Image(uiImage: ui) }
        #endif
        #if canImport(AppKit)
        if let ns = NSImage(data: data) { return Image(nsImage: ns) }
        #endif
        return nil
    }
}

#if os(iOS)
private struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#else
private struct CameraPreviewLayer: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
#endif
