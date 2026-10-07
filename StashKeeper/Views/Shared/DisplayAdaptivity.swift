//
//  DisplayAdaptivity.swift
//  StashKeeper
//
//  One reading of the window and the display, shared by every screen.
//  Width decides columns, padding, and card size. The panel's maximum
//  refresh rate decides how fast continuous motion is sampled. Springs
//  stay time-based so a 120 Hz panel plays the same gesture in the same
//  number of milliseconds, with more frames in between.
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

nonisolated struct DisplayMetrics: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat
    var refreshRate: Int
    var reduceMotion: Bool

    /// Phone-width layouts stay a single comfortable column. Wider
    /// windows open a second, then a third, without a separate iPad story.
    var columnCount: Int {
        if width >= 1100 { return 3 }
        if width >= 700 { return 2 }
        return 1
    }

    var horizontalPadding: CGFloat {
        if width >= 1100 { return 36 }
        if width >= 700 { return 28 }
        return 16
    }

    /// Keeps a line of body text from stretching across a large monitor.
    var readableWidth: CGFloat {
        min(width, width >= 900 ? 920 : width)
    }

    var sectionSpacing: CGFloat {
        width >= 700 ? 32 : 22
    }

    /// How many attention cards should sit in view before the row scrolls.
    var attentionCardWidth: CGFloat {
        let visible: CGFloat = width >= 1100 ? 5.2 : (width >= 700 ? 3.6 : 2.35)
        let available = max(width - horizontalPadding * 2, 240)
        return min(168, max(112, available / visible))
    }

    var locationChipWidth: CGFloat {
        attentionCardWidth * 0.68
    }

    /// Interval for effects that sample every display refresh.
    var frameInterval: Double {
        1.0 / Double(max(refreshRate, 30))
    }
}

private struct DisplayMetricsKey: EnvironmentKey {
    static let defaultValue = DisplayMetrics(width: 390, height: 844, refreshRate: 60, reduceMotion: false)
}

extension EnvironmentValues {
    var displayMetrics: DisplayMetrics {
        get { self[DisplayMetricsKey.self] }
        set { self[DisplayMetricsKey.self] = newValue }
    }
}

enum DisplayRefresh {
    /// Highest rate the screen will actually present. External displays
    /// are read from the window scene when one is connected.
    static var maximumFramesPerSecond: Int {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let rate = scenes.map(\.screen.maximumFramesPerSecond).max() ?? UIScreen.main.maximumFramesPerSecond
        return max(rate, 30)
        #else
        let rate = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        return max(rate, 30)
        #endif
    }
}

/// Publishes the current window size and the display refresh rate.
struct DisplayAdaptiveModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = CGSize(width: 390, height: 844)

    func body(content: Content) -> some View {
        content
            .environment(\.displayMetrics, DisplayMetrics(
                width: size.width,
                height: size.height,
                refreshRate: DisplayRefresh.maximumFramesPerSecond,
                reduceMotion: reduceMotion
            ))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, newSize in
                            size = newSize
                        }
                }
            }
    }
}

extension View {
    func displayAdaptive() -> some View {
        modifier(DisplayAdaptiveModifier())
    }

    /// Centers page content and caps the measure on large windows.
    func adaptivePage() -> some View {
        modifier(AdaptivePageModifier())
    }
}

private struct AdaptivePageModifier: ViewModifier {
    @Environment(\.displayMetrics) private var metrics

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: metrics.readableWidth)
            .frame(maxWidth: .infinity)
    }
}

extension Animation {
    /// Time-based spring. On a 120 Hz panel the same response is sampled
    /// twice as often, so the motion stays smooth instead of being retimed.
    static func stashSpring(for metrics: DisplayMetrics) -> Animation {
        if metrics.reduceMotion {
            return .linear(duration: 0.01)
        }
        let response = metrics.refreshRate >= 120 ? 0.36 : 0.42
        return .spring(response: response, dampingFraction: 0.78)
    }
}
