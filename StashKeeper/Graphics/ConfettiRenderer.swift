//
//  ConfettiRenderer.swift
//  StashKeeper
//
//  Owns the Metal device/pipeline state and the particle buffer for the
//  milestone-unlock celebration, and drives the compute-then-render pass
//  each frame via MTKViewDelegate. Kept as a plain class (not an actor) —
//  MTKViewDelegate callbacks arrive on whatever thread MetalKit's internal
//  display link uses, and GPU command encoding here has no shared mutable
//  state accessed from elsewhere, so actor isolation would add overhead
//  without adding safety.
//

import MetalKit
import simd

/// Mirrors the Metal shader's `ConfettiParticle` struct byte-for-byte —
/// this buffer is shared directly with the GPU, so field order, types, and
/// alignment must match exactly (float2/float4 are 8/16-byte aligned,
/// which this layout already satisfies since every field here is a SIMD
/// vector or a 4-byte scalar).
struct ConfettiParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var rotation: Float
    var angularVelocity: Float
    var size: SIMD2<Float>
    var color: SIMD4<Float>
    var life: Float
    var lifeSpan: Float
}

private struct SimulationParams {
    var deltaTime: Float
    var gravity: SIMD2<Float>
    var drag: Float
    var viewSize: SIMD2<Float>
}

/// Drives a burst of GPU-simulated confetti particles for one celebration
/// moment. Created fresh per celebration (cheap — a few hundred particles
/// is a tiny buffer) rather than kept as a long-lived shared object, since
/// milestone celebrations are infrequent, bursty events, not a continuous
/// effect that benefits from a persistent renderer.
final class ConfettiRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let simulationPipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private var particleBuffer: MTLBuffer
    private let particleCount: Int
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    /// Total elapsed time since the burst started, used by the host view to
    /// know when every particle has faded out and it can tear itself down.
    private(set) var elapsedTime: TimeInterval = 0

    /// Confetti color palette — matches the app's accent tints so the
    /// celebration feels like a natural extension of the UI rather than a
    /// generic effect bolted on, rather than reaching for arbitrary
    /// rainbow confetti colors.
    private static let palette: [SIMD4<Float>] = [
        SIMD4(0.20, 0.60, 1.00, 1.0), // blue
        SIMD4(0.65, 0.35, 1.00, 1.0), // purple
        SIMD4(1.00, 0.62, 0.15, 1.0), // orange
        SIMD4(0.20, 0.85, 0.55, 1.0), // green
        SIMD4(1.00, 0.85, 0.25, 1.0)  // gold
    ]

    init?(device: MTLDevice, particleCount: Int = 240, burstOrigin: CGPoint, viewSize: CGSize) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main),
              let simFunction = library.makeFunction(name: "simulateConfetti"),
              let vertexFunction = library.makeFunction(name: "confettiVertex"),
              let fragmentFunction = library.makeFunction(name: "confettiFragment") else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.particleCount = particleCount

        do {
            self.simulationPipeline = try device.makeComputePipelineState(function: simFunction)

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // Standard alpha blending so overlapping confetti pieces and
            // the fade-out near end-of-life composite naturally over
            // whatever's behind the view (the celebration card/backdrop).
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.renderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            return nil
        }

        var particles: [ConfettiParticle] = []
        particles.reserveCapacity(particleCount)
        for _ in 0..<particleCount {
            particles.append(Self.makeRandomParticle(origin: burstOrigin, viewSize: viewSize))
        }
        guard let buffer = device.makeBuffer(
            bytes: particles,
            length: MemoryLayout<ConfettiParticle>.stride * particleCount,
            options: .storageModeShared
        ) else { return nil }
        self.particleBuffer = buffer

        super.init()
    }

    private static func makeRandomParticle(origin: CGPoint, viewSize: CGSize) -> ConfettiParticle {
        // Burst outward in a wide upward cone from the origin point (e.g.
        // the center of an unlocked milestone badge), like a small
        // firework — reads as "coming from" that specific achievement
        // rather than a generic full-screen effect.
        let angle = Float.random(in: (.pi * 0.2)...(.pi * 0.8))
        let speed = Float.random(in: 220...520)
        let velocity = SIMD2<Float>(cos(angle) * speed, -sin(angle) * speed)
        return ConfettiParticle(
            position: SIMD2(Float(origin.x), Float(origin.y)),
            velocity: velocity,
            rotation: Float.random(in: 0...(.pi * 2)),
            angularVelocity: Float.random(in: -6...6),
            size: SIMD2(Float.random(in: 5...10), Float.random(in: 7...14)),
            color: palette.randomElement() ?? palette[0],
            life: 1.0,
            lifeSpan: Float.random(in: 1.4...2.2)
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let deltaTime = Float(min(now - lastFrameTime, 1.0 / 30.0)) // clamp to avoid a huge jump after a hitch
        lastFrameTime = now
        elapsedTime += Double(deltaTime)

        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Compute pass: advance the simulation by one frame.
        var params = SimulationParams(
            deltaTime: deltaTime,
            gravity: SIMD2(0, 900), // points/sec^2, downward in view space
            drag: 0.6,
            viewSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        )
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(simulationPipeline)
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            computeEncoder.setBytes(&params, length: MemoryLayout<SimulationParams>.stride, index: 1)
            let threadsPerGroup = MTLSize(width: min(simulationPipeline.maxTotalThreadsPerThreadgroup, particleCount), height: 1, depth: 1)
            let groups = MTLSize(width: (particleCount + threadsPerGroup.width - 1) / threadsPerGroup.width, height: 1, depth: 1)
            computeEncoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
        }

        // Render pass: draw all particles as instanced quads.
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            renderEncoder.setRenderPipelineState(renderPipeline)
            renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            var viewportSize = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            renderEncoder.setVertexBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particleCount)
            renderEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// True once every particle's life has counted down to zero — the host
    /// view uses this to know it can remove the MTKView from the hierarchy
    /// rather than leaving an idle Metal view (and its display link)
    /// running forever after the celebration visually finishes.
    var isFinished: Bool {
        elapsedTime > 2.5
    }
}
