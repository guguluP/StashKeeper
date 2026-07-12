//
//  MilestonesView.swift
//  StashKeeper
//
//  Fitness-app-style achievements screen: a streak summary up top (mirrors
//  the Fitness app's "activity" framing) followed by a ring-based milestone
//  grid per category, animated fluidly with spring physics. Newly unlocked
//  milestones get a celebratory scale+glow animation the first time this
//  view appears after they're earned.
//

import SwiftUI
import SwiftData

struct MilestonesView: View {

    @Query private var allItems: [StashItem]
    @Query private var streakRecords: [StreakRecord]
    @Environment(\.modelContext) private var modelContext

    @State private var celebratingMilestones: [CategoryMilestone] = []
    @State private var showCelebration = false
    @State private var appearedCategories: Set<String> = []

    private var streak: StreakRecord? { streakRecords.first }

    private var milestonesByCategory: [(category: String, milestones: [CategoryMilestone])] {
        let all = MilestoneEngine.shared.allMilestones(items: allItems)
        let grouped = Dictionary(grouping: all, by: \.category)
        return grouped
            .map { (category: $0.key, milestones: $0.value.sorted { $0.tier < $1.tier }) }
            .sorted { $0.category < $1.category }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                streakSection

                ForEach(milestonesByCategory, id: \.category) { entry in
                    categorySection(entry.category, milestones: entry.milestones)
                        .opacity(appearedCategories.contains(entry.category) ? 1 : 0)
                        .offset(y: appearedCategories.contains(entry.category) ? 0 : 12)
                        .onAppear {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(staggerDelay(for: entry.category))) {
                                _ = appearedCategories.insert(entry.category)
                            }
                        }
                }

                if milestonesByCategory.isEmpty {
                    ContentUnavailableView(
                        "No Milestones Yet",
                        systemImage: "rosette",
                        description: Text("Start adding items to unlock achievements for each category.")
                    )
                    .padding(.top, 40)
                }
            }
            .padding()
        }
        .navigationTitle("Milestones")
        .onAppear {
            let fresh = MilestoneEngine.shared.newlyUnlockedMilestones(items: allItems)
            if !fresh.isEmpty {
                celebratingMilestones = fresh
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    showCelebration = true
                }
            }
        }
        .overlay {
            if showCelebration, !celebratingMilestones.isEmpty {
                CelebrationOverlay(milestones: celebratingMilestones) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showCelebration = false
                    }
                }
            }
        }
    }

    private func staggerDelay(for category: String) -> Double {
        let index = milestonesByCategory.firstIndex { $0.category == category } ?? 0
        return Double(index) * 0.05
    }

    // MARK: - Streak

    private var streakSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: min(1.0, Double(streak?.currentStreak ?? 1) / 30.0))
                    .stroke(
                        AngularGradient(colors: [.orange, .red, .orange], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.8, dampingFraction: 0.8), value: streak?.currentStreak)
                VStack(spacing: 0) {
                    Text("\(streak?.currentStreak ?? 1)")
                        .font(.title2.weight(.bold))
                        .contentTransition(.numericText())
                    Text("days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 4) {
                Text("Current Streak")
                    .font(.subheadline.weight(.semibold))
                Text("Longest: \(streak?.longestStreak ?? 1) day\((streak?.longestStreak ?? 1) == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Open StashKeeper daily to keep it going")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Category section

    private func categorySection(_ category: String, milestones: [CategoryMilestone]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(category)
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(milestones) { milestone in
                        MilestoneRingView(milestone: milestone)
                    }
                }
            }
        }
    }
}

// MARK: - Ring view

private struct MilestoneRingView: View {
    let milestone: CategoryMilestone
    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(milestone.tier.tint.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        milestone.tier.tint,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: milestone.isUnlocked ? milestone.systemImage : "lock.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(milestone.isUnlocked ? milestone.tier.tint : .secondary)
                    .symbolEffect(.bounce, value: milestone.isUnlocked)
            }
            .frame(width: 64, height: 64)
            .scaleEffect(milestone.isUnlocked ? 1.0 : 0.94)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: milestone.isUnlocked)

            Text(milestone.tier.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(milestone.isUnlocked ? .primary : .secondary)

            Text("\(milestone.currentCount)/\(milestone.tier.threshold)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 80)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.75).delay(0.1)) {
                animatedProgress = milestone.progress
            }
        }
    }
}

// MARK: - Celebration overlay

private struct CelebrationOverlay: View {
    let milestones: [CategoryMilestone]
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 0.6
    @State private var opacity: Double = 0
    @State private var showConfetti = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                // Real Metal-driven GPU particle burst (see Graphics/) —
                // originates from the top-center of the card, like the
                // celebration is "coming from" the achievement itself.
                if showConfetti {
                    ConfettiView(
                        burstOrigin: CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.35),
                        onFinished: { showConfetti = false }
                    )
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                }

                VStack(spacing: 16) {
                    ForEach(milestones.prefix(3)) { milestone in
                        HStack(spacing: 12) {
                            Image(systemName: milestone.systemImage)
                                .font(.title2)
                                .foregroundStyle(milestone.tier.tint)
                                .padding(12)
                                .background(milestone.tier.tint.opacity(0.15), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(milestone.tier.label) Unlocked!")
                                    .font(.headline)
                                Text("\(milestone.category) — \(milestone.tier.threshold) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }

                    Button("Nice!") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(32)
                .scaleEffect(scale)
                .opacity(opacity)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
                scale = 1.0
                opacity = 1.0
            }
            StashHaptics.success()
        }
    }
}

#Preview {
    NavigationStack { MilestonesView() }
        .modelContainer(for: [StashItem.self, StorageLocation.self, StreakRecord.self], inMemory: true)
}
