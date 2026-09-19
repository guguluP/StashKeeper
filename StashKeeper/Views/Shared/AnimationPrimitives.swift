//
//  AnimationPrimitives.swift
//  StashKeeper
//
//  Small reusable animation building blocks applied across the app for a
//  consistent, fluid feel — a tactile press-scale button style (used on
//  nearly every tappable card/chip), a shimmer effect for loading states,
//  shared spring presets so easing feels consistent everywhere rather than
//  each view inventing its own timing curve, and macOS 26 (Tahoe) Liquid
//  Glass surface helpers used for cards, chips, and toolbars app-wide.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Haptics (macOS trackpad feedback / iOS Taptic Engine)

/// Thin wrapper so call sites read the same (`.impact()`, `.success()`)
/// regardless of platform, without sprinkling `#if os(...)` everywhere.
/// On macOS this drives `NSHapticFeedbackManager` (Force Touch trackpad,
/// silently no-ops without one). On iOS/iPadOS this drives the Taptic
/// Engine via `UIFeedbackGenerator` (no-ops on devices without one, e.g.
/// some iPads).
enum StashHaptics {
    static func impact() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #elseif os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func success() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #elseif os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func alignment() {
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #elseif os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

// MARK: - Visual language

enum StashTheme {
    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.55),
                Color.purple.opacity(0.35),
                Color.orange.opacity(0.25)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var screenBackground: some View {
        ZStack {
            Color(white: 0.06).opacity(0.0001)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.08),
                    Color.clear,
                    Color.orange.opacity(0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct ExpiryBadge: View {
    let item: StashItem

    var body: some View {
        if item.isPerishable {
            Text(item.expiryCaption)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(item.expiryStatus.tint)
                .background(item.expiryStatus.tint.opacity(0.15), in: Capsule())
        }
    }
}

struct StashSectionHeader: View {
    let title: String
    var systemImage: String?
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.headline)
            Spacer()
        }
    }
}

// MARK: - Liquid Glass surfaces

/// Applies the Tahoe-era Liquid Glass treatment where available (macOS 26 /
/// iOS 26), falling back to the existing `.regularMaterial` look on older
/// systems so the app still builds and looks correct against earlier SDKs.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    var interactive: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// Card/tile/chip surface — the default "everything sits on glass" look.
    func glassSurface(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, interactive: interactive))
    }
}

/// Groups sibling glass surfaces so adjacent Liquid Glass shapes merge and
/// morph together on macOS 26 / iOS 26; on older systems this is a no-op
/// passthrough container.
@ViewBuilder
func StashGlassGroup<Content: View>(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) -> some View {
    if #available(macOS 26.0, iOS 26.0, *) {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    } else {
        content()
    }
}

extension Animation {
    /// Standard "snappy but soft" spring used for most UI state changes
    /// (selection, toggles, appearing content).
    static var stashSpring: Animation {
        .spring(response: 0.4, dampingFraction: 0.75)
    }

    /// Slightly slower, more pronounced spring for celebratory or
    /// attention-grabbing moments (milestone unlocks, ring fills).
    static var stashCelebration: Animation {
        .spring(response: 0.6, dampingFraction: 0.7)
    }
}

/// A button style that gently scales and dims content on press, used
/// throughout the app on cards, chips, and rows so tapping anything feels
/// tactile and alive rather than static.
struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed, haptic { StashHaptics.impact() }
            }
    }
}

extension ButtonStyle where Self == PressScaleButtonStyle {
    static var pressScale: PressScaleButtonStyle { PressScaleButtonStyle() }
}

/// A subtle shimmering placeholder, used while Vision/Foundation Models
/// analysis is in progress so the loading state feels alive rather than a
/// static spinner alone.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.35), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: phase * proxy.size.width * 1.8)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }

    /// Applies a staggered fade+slide entrance, offset by `index` — used for
    /// list rows and grid items so content cascades in rather than popping
    /// in all at once.
    func staggeredAppear(index: Int, isVisible: Bool, baseDelay: Double = 0.04) -> some View {
        self
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 10)
            .animation(.stashSpring.delay(Double(index) * baseDelay), value: isVisible)
    }
}

// MARK: - Sheet/cover entrance animation

/// A gentle scale + fade + rise applied to a sheet or full-screen cover's
/// root content the moment it appears, so presented windows feel like they
/// pop into place rather than the system's flat default fade. SwiftUI
/// already animates the sheet container's slide-up; this additionally
/// animates the *content inside* on a slightly independent, springier
/// curve, which is what actually reads as "alive" — the container motion
/// alone looks mechanical without it.
///
/// Applied via `.sheetPopIn()` at the root of each sheet/fullScreenCover's
/// content closure, e.g.:
/// ```
/// .sheet(isPresented: $showing) {
///     SomeView().sheetPopIn()
/// }
/// ```
struct SheetPopInModifier: ViewModifier {
    @State private var hasAppeared = false

    /// Slightly different starting scale/offset per call site would be
    /// overkill; one consistent, subtle motion reads as intentional across
    /// the whole app rather than each sheet doing its own thing.
    private let startScale: CGFloat = 0.94
    private let startOffsetY: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .scaleEffect(hasAppeared ? 1 : startScale)
            .offset(y: hasAppeared ? 0 : startOffsetY)
            .opacity(hasAppeared ? 1 : 0)
            .onAppear {
                // A tiny delay lets the sheet's own presentation transition
                // begin first so this doesn't fight the system animation —
                // without it the two motions visibly stutter against each
                // other for a frame.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                        hasAppeared = true
                    }
                }
            }
    }
}

extension View {
    /// See `SheetPopInModifier`. Apply at the root of a sheet/cover's
    /// content view.
    func sheetPopIn() -> some View {
        modifier(SheetPopInModifier())
    }
}
