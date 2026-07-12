//
//  StashScanActivityController.swift
//  StashKeeper
//
//  Thin wrapper around ActivityKit's Activity<StashScanActivityAttributes>
//  API, called from AddItemFlowView during photo analysis. Isolated into
//  its own type (rather than calling ActivityKit directly from the view)
//  so every call site handles the same real-world constraints identically:
//  Live Activities require user permission, can fail to start for reasons
//  outside our control, and aren't available on macOS at all — none of
//  which should ever block or degrade the actual Add Item flow, since the
//  Live Activity is a nice-to-have progress surface, not a requirement.
//

import Foundation
#if os(iOS)
import ActivityKit
#endif

@MainActor
final class StashScanActivityController {
    static let shared = StashScanActivityController()

    #if os(iOS)
    private var currentActivity: Activity<StashScanActivityAttributes>?
    #endif

    private init() {}

    /// Starts a new Live Activity for a scan session. Safe to call even
    /// when Live Activities aren't authorized or available (macOS, user
    /// disabled them in Settings, etc.) — silently does nothing in that
    /// case rather than surfacing an error, since the Add Item flow works
    /// completely fine without it.
    func start(totalPhotoCount: Int) {
        #if os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end() // guard against a leftover activity from a previous session

        let attributes = StashScanActivityAttributes(totalPhotoCount: totalPhotoCount)
        let initialState = StashScanActivityAttributes.ContentState(
            progressMessage: "Starting analysis…",
            fractionComplete: 0,
            itemsFoundSoFar: 0,
            isComplete: false
        )

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil)
            )
        } catch {
            // Live Activity creation can fail for reasons entirely outside
            // app logic (rate limits, user permission state) — the Add
            // Item flow continues normally either way.
            currentActivity = nil
        }
        #endif
    }

    /// Pushes a progress update. `photoIndex` is 1-based (matching the
    /// progress strings already used in AddItemFlowView's `.analyzing`
    /// stage) so both surfaces read identically to the user.
    func updateProgress(photoIndex: Int, totalPhotoCount: Int, message: String, itemsFoundSoFar: Int) {
        #if os(iOS)
        guard let currentActivity else { return }
        let fraction = totalPhotoCount > 0 ? Double(photoIndex) / Double(totalPhotoCount) : 0
        let state = StashScanActivityAttributes.ContentState(
            progressMessage: message,
            fractionComplete: min(max(fraction, 0), 1),
            itemsFoundSoFar: itemsFoundSoFar,
            isComplete: false
        )
        Task {
            await currentActivity.update(.init(state: state, staleDate: nil))
        }
        #endif
    }

    /// Marks the activity complete with a final item count, then ends it
    /// shortly after so the person sees a satisfying "done" state on the
    /// Lock Screen/Dynamic Island rather than it vanishing the instant
    /// analysis finishes.
    func finish(totalItemsFound: Int) {
        #if os(iOS)
        guard let currentActivity else { return }
        let finalState = StashScanActivityAttributes.ContentState(
            progressMessage: totalItemsFound == 0 ? "No items found" : "Found \(totalItemsFound) item\(totalItemsFound == 1 ? "" : "s")",
            fractionComplete: 1,
            itemsFoundSoFar: totalItemsFound,
            isComplete: true
        )
        Task {
            await currentActivity.update(.init(state: finalState, staleDate: nil))
            try? await Task.sleep(for: .seconds(2))
            await currentActivity.end(nil, dismissalPolicy: .after(.now.addingTimeInterval(2)))
        }
        self.currentActivity = nil
        #endif
    }

    /// Immediately ends any in-flight activity with no completion flourish
    /// — used when the flow is cancelled or fails outright.
    func end() {
        #if os(iOS)
        guard let currentActivity else { return }
        Task {
            await currentActivity.end(nil, dismissalPolicy: .immediate)
        }
        self.currentActivity = nil
        #endif
    }
}
