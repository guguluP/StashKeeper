//
//  DetectionOverlayView.swift
//  StashKeeper
//
//  Renders the captured photo/frame with a tappable bounding box drawn over
//  each detected item region. The user taps a box to toggle whether that
//  detection should be kept, and can tap a box again (or a dedicated
//  button) to jump into editing that specific item's details before saving.
//

import SwiftUI

struct DetectionOverlayView: View {

    struct Candidate: Identifiable {
        let id: UUID
        var boundingBox: CGRect // normalized, Vision convention (origin bottom-left)
        var analysis: ItemAnalysis
        var isIncluded: Bool
        /// Set when this candidate was merged with detections from OTHER
        /// source photos believed to be the same physical item shot from a
        /// different angle. Each entry is the full image data of one of
        /// those other photos, so all angles get saved onto the resulting
        /// StashItem's `photoFilenames`. Empty for a normal, unmerged
        /// candidate.
        var mergedAnglePhotos: [Data] = []
        /// True if THIS candidate was the one absorbed into another
        /// candidate elsewhere (rather than the survivor holding the merge).
        /// Rendered distinctly from a plain excluded/rejected box so it's
        /// clear this was a deliberate "same item, different angle" merge
        /// rather than a bad detection the user turned off.
        var mergedIntoAnotherCandidate: Bool = false
        /// Set when this candidate deterministically matches an item
        /// already in the persisted inventory from a PREVIOUS Add Item
        /// session (e.g. re-scanning the same electronics box weeks
        /// later), as opposed to `mergedAnglePhotos` which only tracks
        /// merges within the current session's own photos. When set, the
        /// review UI offers "update existing item's quantity" instead of
        /// silently creating a second inventory entry for the same object.
        var existingItemMatch: ExistingItemMatcher.Match?
        /// True when this candidate's analysis came from `HeuristicItemNamer`
        /// (no AI model involved — device can't run Apple Intelligence and
        /// Private Cloud Compute wasn't available either) rather than AFM.
        /// The review UI shows an honest "estimated" badge in this case so
        /// the user knows to double-check more carefully than they would
        /// for an AI-identified result.
        var isHeuristicEstimate: Bool = false

        var isMergedFromMultipleAngles: Bool { !mergedAnglePhotos.isEmpty }
    }

    let imageData: Data
    @Binding var candidates: [Candidate]
    var onEditCandidate: (Candidate) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let platformImage = PlatformImage(data: imageData) {
                    platformImage.resizableImage
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }

                ForEach($candidates) { $candidate in
                    boxView(for: candidate, containerSize: proxy.size)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                if candidate.mergedIntoAnotherCandidate {
                                    // Let the user undo an incorrect
                                    // "same item, different angle" merge —
                                    // splits this detection back out as its
                                    // own separate, included item.
                                    candidate.mergedIntoAnotherCandidate = false
                                    candidate.isIncluded = true
                                } else {
                                    candidate.isIncluded.toggle()
                                }
                            }
                        }
                }
            }
        }
        .aspectRatio(imageAspectRatio, contentMode: .fit)
    }

    private var imageAspectRatio: CGFloat {
        guard let platformImage = PlatformImage(data: imageData) else { return 1 }
        return platformImage.pixelAspectRatio ?? 1
    }

    private func boxView(for candidate: Candidate, containerSize: CGSize) -> some View {
        // Convert Vision's normalized bottom-left-origin box into SwiftUI's
        // top-left-origin, view-space rect.
        let rect = CGRect(
            x: candidate.boundingBox.origin.x * containerSize.width,
            y: (1 - candidate.boundingBox.origin.y - candidate.boundingBox.height) * containerSize.height,
            width: candidate.boundingBox.width * containerSize.width,
            height: candidate.boundingBox.height * containerSize.height
        )

        let tint: Color = candidate.mergedIntoAnotherCandidate ? .purple : (candidate.isIncluded ? .green : .red)

        return VStack {
            HStack {
                Spacer()
                if !candidate.mergedIntoAnotherCandidate {
                    Button {
                        onEditCandidate(candidate)
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .blue)
                            .background(Circle().fill(.white).padding(2))
                    }
                    .buttonStyle(.pressScale)
                    // Ensures the pencil button reliably intercepts its own
                    // taps rather than potentially being swallowed by the
                    // parent box's onTapGesture (include/exclude toggle),
                    // since both live in the same hit-testing region.
                    .contentShape(Circle())
                    .offset(x: 8, y: -8)
                }
            }
            Spacer()
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .scaleEffect(candidate.isIncluded ? 1.0 : 0.97)
        .opacity(candidate.mergedIntoAnotherCandidate ? 0.55 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint, style: candidate.mergedIntoAnotherCandidate ? StrokeStyle(lineWidth: 3, dash: [6, 4]) : StrokeStyle(lineWidth: 3))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.08))
                )
        )
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                if candidate.isMergedFromMultipleAngles {
                    Image(systemName: "square.stack")
                        .font(.caption2)
                } else if candidate.mergedIntoAnotherCandidate {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.caption2)
                }
                Text(candidate.mergedIntoAnotherCandidate ? "Same as another photo" : candidate.analysis.name)
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint, in: Capsule())
            .foregroundStyle(.white)
            .padding(4)
            .opacity(rect.width > 60 ? 1 : 0)
        }
        .position(x: rect.midX, y: rect.midY)
    }
}

private extension PlatformImage {
    /// Width/height ratio of the underlying pixel data, used to size the
    /// overlay container to match the displayed image exactly.
    var pixelAspectRatio: CGFloat? {
        #if os(macOS)
        guard let nsImage else { return nil }
        let size = nsImage.size
        guard size.height > 0 else { return nil }
        return size.width / size.height
        #else
        guard let uiImage else { return nil }
        guard uiImage.size.height > 0 else { return nil }
        return uiImage.size.width / uiImage.size.height
        #endif
    }
}
