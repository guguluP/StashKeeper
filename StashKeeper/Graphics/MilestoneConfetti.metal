//
//  MilestoneConfetti.metal
//  StashKeeper
//
//  GPU particle system for the milestone-unlock celebration. Simulation
//  (position/velocity/rotation integration under gravity + drag) runs
//  entirely in a compute kernel so a few hundred confetti pieces cost
//  effectively nothing on the CPU — SwiftUI/CPU-driven particle effects at
//  this count tend to visibly stutter on older devices, which is exactly
//  the wrong impression to leave during a moment meant to feel delightful.
//

#include <metal_stdlib>
using namespace metal;

/// Mirrors `ConfettiParticle` on the Swift side exactly — layout must match
/// since this buffer is shared directly between CPU-initialized data and
/// GPU read/write without any marshaling.
struct ConfettiParticle {
    float2 position;
    float2 velocity;
    float rotation;
    float angularVelocity;
    float2 size;
    float4 color;
    float life;      // 1.0 at birth, counts down to 0
    float lifeSpan;  // seconds this particle lives for
};

struct SimulationParams {
    float deltaTime;
    float2 gravity;
    float drag;
    float2 viewSize;
};

/// Advances every particle by one frame: gravity + drag integration on
/// velocity, position integration, spin, and life countdown. One thread
/// per particle — trivially parallel, which is exactly what a compute
/// kernel is for and why this scales to many more particles than a
/// CPU/CoreAnimation approach would comfortably handle at 60-120fps.
kernel void simulateConfetti(
    device ConfettiParticle *particles [[buffer(0)]],
    constant SimulationParams &params [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    device ConfettiParticle &p = particles[id];
    if (p.life <= 0.0) { return; }

    p.velocity += params.gravity * params.deltaTime;
    p.velocity *= (1.0 - params.drag * params.deltaTime);
    p.position += p.velocity * params.deltaTime;
    p.rotation += p.angularVelocity * params.deltaTime;
    p.life -= params.deltaTime / p.lifeSpan;
}

// MARK: - Rendering

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

/// Draws each particle as a small camera-facing quad (2 triangles, 6
/// vertices, generated procedurally from a vertex ID rather than an actual
/// vertex buffer — a standard trick for cheap per-instance quads), rotated
/// by the particle's spin and faded out over its remaining life.
vertex VertexOut confettiVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant ConfettiParticle *particles [[buffer(0)]],
    constant float2 &viewportSize [[buffer(1)]]
) {
    constant ConfettiParticle &p = particles[instanceID];

    // Unit quad corners, indexed by vertexID % 6 (two triangles).
    float2 corners[6] = {
        float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5),
        float2(0.5, -0.5),  float2(0.5, 0.5),  float2(-0.5, 0.5)
    };
    float2 corner = corners[vertexID % 6];

    float c = cos(p.rotation);
    float s = sin(p.rotation);
    float2 rotated = float2(
        corner.x * c - corner.y * s,
        corner.x * s + corner.y * c
    );
    float2 worldPos = p.position + rotated * p.size;

    // Convert from pixel space (origin top-left, y-down — matching
    // SwiftUI's coordinate convention so the Swift side can hand over
    // plain view-space coordinates with no extra flipping) to clip space.
    float2 clipPos = (worldPos / viewportSize) * 2.0 - 1.0;
    clipPos.y = -clipPos.y;

    VertexOut out;
    out.position = float4(clipPos, 0.0, 1.0);
    out.uv = corner + 0.5;
    // Ease-out fade near end of life reads as a much gentler "flutter away"
    // than a linear fade, which tends to look like a sudden pop-off.
    float fadeAlpha = p.life < 0.25 ? (p.life / 0.25) : 1.0;
    out.color = float4(p.color.rgb, p.color.a * fadeAlpha);
    return out;
}

fragment float4 confettiFragment(VertexOut in [[stage_in]]) {
    // Soft rounded-rect falloff rather than a hard-edged square, so
    // confetti pieces read as small paper/foil flecks rather than pixels.
    float2 centered = abs(in.uv - 0.5) * 2.0;
    float edge = max(centered.x, centered.y);
    float alpha = 1.0 - smoothstep(0.75, 1.0, edge);
    return float4(in.color.rgb, in.color.a * alpha);
}
