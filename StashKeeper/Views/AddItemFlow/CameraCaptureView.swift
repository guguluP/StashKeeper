//
//  CameraCaptureView.swift
//  StashKeeper
//
//  A custom multi-shot camera screen for the Add Items flow. Unlike
//  UIImagePickerController (single shot, then dismiss), this lets the user
//  snap several items in a row without leaving the camera — mirroring the
//  existing "select up to 10 photos" mental model but for live capture.
//  Each captured frame is handed back as JPEG Data, identical in shape to
//  what PhotosPicker already produces, so it drops straight into
//  AddItemFlowView's existing analyzeAllSources(_:) pipeline with no
//  changes needed on the analysis side.
//

#if os(iOS)
import SwiftUI
@preconcurrency import AVFoundation

struct CameraCaptureView: View {
    let onFinish: ([Data]) -> Void
    let onCancel: () -> Void

    @State private var model = CameraCaptureModel()

    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
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
        .statusBarHidden()
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
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 12)
        .animation(.stashSpring, value: model.capturedThumbnails.count)
    }

    private var shutterBar: some View {
        HStack {
            Color.clear.frame(width: 64, height: 64)

            Spacer()

            Button {
                model.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 72, height: 72)
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .frame(width: 84, height: 84)
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
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                    Text("Done")
                        .font(.caption2.weight(.semibold))
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
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

// MARK: - Capture model

/// Owns the AVCaptureSession lifecycle off the main actor (session
/// start/stop and photo capture are documented by Apple as blocking calls
/// that shouldn't run on the main thread) while publishing UI-facing state
/// back on the main actor. Kept as a separate `nonisolated` coordinator
/// class — rather than making the whole model `@MainActor` and hopping
/// queues inline — so the AVCapturePhotoCaptureDelegate conformance itself
/// never needs to cross an actor boundary to reach the session/output it's
/// attached to, avoiding Swift 6 Sendable friction with AVFoundation's
/// non-Sendable capture types.
/// Explicitly `nonisolated`: this project sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise make
/// this class implicitly main-actor-isolated — but AVFoundation invokes
/// `AVCapturePhotoCaptureDelegate` callbacks from its own background
/// delegate queue, not the main actor, so a main-actor-isolated
/// conformance can't actually be used there (Swift 6 error). All mutable
/// state below is already confined to `sessionQueue`, so nonisolated is
/// also the technically correct annotation, not just a workaround.
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

                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
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
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .auto
            self.output.capturePhoto(with: settings, delegate: self)
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
    var capturedThumbnails: [UIImage] = []
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
                if let image = UIImage(data: data) {
                    self.capturedThumbnails.append(image)
                }
            }
        }
    }
}

// MARK: - Preview layer bridge

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
#endif
