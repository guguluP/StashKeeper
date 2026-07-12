//
//  StashAssistantChatView.swift
//  StashKeeper
//
//  Full-screen chat surface for the in-app assistant. Reachable from the
//  Dashboard prompt chip (AssistantPromptChip, below) or directly. Keeps
//  its own local message list in @State rather than persisting to
//  SwiftData — this is a lightweight, session-scoped conversation, not
//  inventory data, and StashAssistantService itself already holds the
//  actual model session/context across turns.
//

import SwiftUI
import SwiftData

struct StashAssistantChatView: View {

    @Query private var allItems: [StashItem]
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [StashChatMessage] = []
    @State private var draftText: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showingHeuristicNotice = false
    @FocusState private var isInputFocused: Bool

    /// Suggested starter prompts shown when the conversation is empty —
    /// gives the user a concrete sense of what this can do rather than a
    /// blank text field and a vague "ask anything."
    private static let starterPrompts = [
        "What can I cook with what I have?",
        "What's expiring soon?",
        "Suggest a snack after a workout",
        "How much have I got in the Pantry?"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showingHeuristicNotice {
                    heuristicNoticeBanner
                }

                if messages.isEmpty {
                    emptyStateView
                } else {
                    messageList
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }

                inputBar
            }
            .navigationTitle("Stash Assistant")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !messages.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            StashHaptics.impact()
                            withAnimation(.stashSpring) {
                                messages.removeAll()
                            }
                            StashAssistantService.shared.resetConversation()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty state with starter prompts

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.4))
            VStack(spacing: 6) {
                Text("Ask about your stash")
                    .font(.title3.weight(.semibold))
                Text("I can check what you have, what's expiring, and suggest things to cook — using your inventory and, if you allow it, today's Health activity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 10) {
                ForEach(Self.starterPrompts, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .buttonStyle(.pressScale)
                    .glassSurface(cornerRadius: 12)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Heuristic mode disclosure

    private var heuristicNoticeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Apple Intelligence isn't available on this device, so answers use simpler on-device logic — direct lookups work, but open-ended questions may not.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                guard let lastID = messages.last?.id else { return }
                withAnimation(.stashSpring) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask something…", text: $draftText, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .glassSurface(cornerRadius: 18)
                .focused($isInputFocused)
                .disabled(isSending)
                .onSubmit { sendDraft() }

            Button {
                sendDraft()
            } label: {
                Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolEffect(.pulse, isActive: isSending)
            }
            .buttonStyle(.pressScale)
            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding()
    }

    private func sendDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draftText = ""
        send(trimmed)
    }

    private func send(_ text: String) {
        guard !isSending else { return }
        errorMessage = nil
        isSending = true
        StashHaptics.impact()

        withAnimation(.stashSpring) {
            messages.append(StashChatMessage(role: .user, text: text))
            messages.append(StashChatMessage(role: .assistant, text: "", isStreaming: true))
        }

        Task {
            do {
                let reply = try await StashAssistantService.shared.send(text, items: allItems)
                if StashAssistantService.shared.lastResponseWasHeuristic {
                    withAnimation(.stashSpring) { showingHeuristicNotice = true }
                }
                if let lastIndex = messages.indices.last {
                    withAnimation(.stashSpring) {
                        messages[lastIndex].text = reply
                        messages[lastIndex].isStreaming = false
                    }
                }
            } catch {
                if let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant {
                    messages.removeLast()
                }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Please try again."
            }
            isSending = false
        }
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: StashChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubbleContent
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubbleContent
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        Group {
            if message.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(message.role == .user ? .white : .primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if message.role == .user {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.blue)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
    }
}

#Preview {
    StashAssistantChatView()
        .modelContainer(for: [StashItem.self, StorageLocation.self, StreakRecord.self], inMemory: true)
}
