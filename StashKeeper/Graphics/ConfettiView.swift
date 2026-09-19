//
//  ConfettiView.swift
//  StashKeeper
//
//  SwiftUI-facing wrapper around an MTKView running ConfettiRenderer — this
//  is the actual "greater use of Metal for milestone-completion animation"
//  surface: a real GPU particle system rather than a SwiftUI-animated
//  shape, used for the celebration overlay shown when a milestone unlocks.
//

import SwiftUI
import MetalKit

#if os(iOS)
struct ConfettiView: UIViewRepresentable {
    let burstOrigin: CGPoint
    var onFinished: (() -> Void)?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .clear
        view.isOpaque = false
        view.framebufferOnly = false
        configureRenderer(for: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    private func configureRenderer(for view: MTKView, coordinator: Coordinator) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        view.device = device
        let size = view.bounds.size == .zero ? UIScreen.main.bounds.size : view.bounds.size
        guard let renderer = ConfettiRenderer(device: device, burstOrigin: burstOrigin, viewSize: size) else { return }
        coordinator.renderer = renderer
        coordinator.hostView = view
        view.delegate = coordinator
        coordinator.startWatchingForCompletion()
    }
}
#else
struct ConfettiView: NSViewRepresentable {
    let burstOrigin: CGPoint
    var onFinished: (() -> Void)?

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.layer?.isOpaque = false
        configureRenderer(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    private func configureRenderer(for view: MTKView, coordinator: Coordinator) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        view.device = device
        let size = view.bounds.size == .zero ? NSScreen.main?.frame.size ?? CGSize(width: 800, height: 600) : view.bounds.size
        guard let renderer = ConfettiRenderer(device: device, burstOrigin: burstOrigin, viewSize: size) else { return }
        coordinator.renderer = renderer
        coordinator.hostView = view
        view.delegate = coordinator
        coordinator.startWatchingForCompletion()
    }
}
#endif

/// Bridges MTKViewDelegate callbacks back to SwiftUI and polls
/// `renderer.isFinished` on a lightweight timer so the celebration overlay
/// can dismiss itself once every particle has faded, rather than staying
/// on screen (and the Metal view rendering) forever.
final class Coordinator: NSObject, MTKViewDelegate {
    var renderer: ConfettiRenderer?
    weak var hostView: MTKView?
    let onFinished: (() -> Void)?
    private var completionTimer: Timer?

    init(onFinished: (() -> Void)?) {
        self.onFinished = onFinished
    }

    func startWatchingForCompletion() {
        completionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, let renderer = self.renderer else {
                timer.invalidate()
                return
            }
            if renderer.isFinished {
                timer.invalidate()
                DispatchQueue.main.async { [weak self] in
                    self?.hostView?.isPaused = true
                    self?.onFinished?()
                }
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }
}
