//
//  StashAssistantService.swift
//  StashKeeper
//
//  Backs the in-app chat assistant: a multi-turn LanguageModelSession with
//  both InventoryLookupTool and HealthContextTool attached, so the model
//  can answer things like "what should I cook tonight" or "how much have
//  I spent on snacks this month" by actually querying live data rather
//  than guessing from the conversation text alone.
//
//  Session lifecycle mirrors ItemIntelligenceService's pattern (a warm
//  session reused across turns, rebuilt if the model tier or inventory
//  changes underneath it) but is intentionally a separate service/session
//  rather than reusing ItemIntelligenceService's analysisSession — that
//  session's instructions are tuned for structured region analysis, not
//  open conversation, and mixing the two would mean every analysis call
//  re-parses chat-flavored instructions and vice versa.
//

import Foundation
import FoundationModels
import SwiftData

/// One message in the assistant conversation, kept as a plain Sendable
/// struct (not the framework's internal transcript type) so it's simple to
/// store in SwiftUI @State and persist later if we ever want chat history
/// to survive app relaunches.
struct StashChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    /// True while a response is still streaming in — lets the UI show a
    /// typing-style indicator on the message bubble itself rather than a
    /// separate loading row that then gets swapped out.
    var isStreaming: Bool = false
}

enum StashAssistantError: Error, LocalizedError {
    case modelUnavailable
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "I couldn't reach any model tier right now — your inventory and Health data are safe, nothing here needs it to function."
        case .generationFailed:
            return "Something went wrong generating a response. Please try again."
        }
    }
}

@MainActor
final class StashAssistantService {

    static let shared = StashAssistantService()

    private var session: LanguageModelSession?
    private var sessionItemCount: Int = -1
    private var sessionTier: ModelTier?

    /// True if the most recently completed response came from the
    /// zero-AI heuristic fallback rather than an actual AFM tier — lets
    /// the UI disclose degraded capability the same way ModelTier does
    /// elsewhere in the app, rather than silently giving terser answers
    /// with no explanation.
    private(set) var lastResponseWasHeuristic = false

    private init() {}

    private static let baseInstructions = """
        You are the in-app assistant for StashKeeper, a personal home
        inventory app. You help the user with:
        (1) questions about what they have stored — quantities,
        locations, expiry — using the lookupExistingInventory tool;
        (2) practical food and recipe suggestions using what's actually
        in their stash, optionally informed by their activity today via
        the getTodayHealthContext tool;
        (3) resolving a barcode/UPC/EAN number the user mentions directly
        into a real product name/brand/category using the
        lookupProductByBarcode tool;
        (4) actually updating their inventory when they mention using,
        finishing, consuming, throwing away, or restocking something —
        via the adjustItemQuantity tool. This is a real write action, not
        just conversation: only call it when the user's message clearly
        states or implies a completed change in what they have (e.g. "I
        used the last of the milk", "used 2 eggs", "add 3 more paper
        towels"), not for hypothetical or future statements ("I might use
        some eggs later" should NOT trigger an adjustment). After a
        successful adjustment, confirm plainly what changed and to what
        new quantity, using the tool's actual returned numbers — never
        state a new quantity you didn't get back from the tool. If the
        tool reports an ambiguous or no match, ask the user to clarify
        rather than guessing or silently skipping the request.

        Ground every factual claim about their inventory, health data, or
        a looked-up product in an actual tool call — never invent
        quantities, locations, activity numbers, or product identities.
        If a tool returns no data, is unavailable, or reports an
        ambiguous match, say so plainly rather than guessing.

        Keep answers conversational and concise — this is a chat, not a
        report. For recipe suggestions, ALWAYS lead with ingredients that
        are expired or expiring soon (from lookupExistingInventory's
        daysUntilExpiry), then the rest of what's on hand. It's fine to
        assume a few common pantry staples (oil, salt, basic spices)
        even if they're not itemized. When listing inventory, sort
        perishable items by urgency before everything else.
        You are not a medical or nutrition professional — keep any
        health-related framing general and suggest consulting a doctor or
        dietitian for anything specific to a medical condition.
        """

    /// Returns (and lazily builds/rebuilds) a warm session with both tools
    /// attached. Rebuilt if the inventory item count has changed since the
    /// session was built (same staleness heuristic ItemIntelligenceService
    /// uses) or if the resolved model tier has changed, so a stale tool
    /// snapshot or a tier flip (e.g. Apple Intelligence toggled mid-use)
    /// doesn't silently persist across the conversation.
    private func warmSession(items: [StashItem], modelContext: ModelContext) -> LanguageModelSession {
        // Chat is open-ended conversation — use the general use case, not
        // content tagging (which is specialized for classification/schema fill).
        let (model, tier) = PreferredModelRouter.resolve(
            preferCloud: false,
            useCase: .general
        )

        if let session, sessionItemCount == items.count, sessionTier == tier {
            return session
        }

        let inventoryTool = InventoryLookupTool(items: items)
        let healthTool = HealthContextTool()
        let productLookupTool = ProductLookupTool()
        let adjustmentTool = InventoryAdjustmentTool(modelContext: modelContext)

        let newSession = LanguageModelSession(
            model: model,
            tools: [inventoryTool, healthTool, productLookupTool, adjustmentTool],
            instructions: Instructions { Self.baseInstructions }
        )
        // Prewarm so the first chat turn is not paying model-load cost.
        newSession.prewarm()
        session = newSession
        sessionItemCount = items.count
        sessionTier = tier
        return newSession
    }

    /// Sends a user message and returns the assistant's full text
    /// response. Non-streaming for simplicity and reliability — chat
    /// turns here are short, conversational answers, not long documents,
    /// so the latency difference versus true token streaming is minor,
    /// and this avoids partial-JSON/tool-call edge cases that streaming
    /// structured generation can hit mid-tool-call.
    func send(_ message: String, items: [StashItem], modelContext: ModelContext) async throws -> String {
        let onDeviceAvailable = PreferredModelRouter.onDeviceModel(for: .general).isAvailable
        let pccAvailable = PreferredModelRouter.isPrivateCloudComputeAvailable
        guard onDeviceAvailable || pccAvailable else {
            // No AFM tier reachable at all — rather than a dead end, fall
            // back to deterministic rule-based answers over the same
            // underlying data, mirroring HeuristicItemNamer's philosophy
            // for the Add Item flow. Genuinely useful for a known set of
            // question types, honest about what it can't do for anything
            // else.
            let snapshots = items.map(InventorySnapshotItem.init)
            var fitnessContext: FitnessContext?
            #if os(iOS)
            if let summary = await HealthKitService.shared.fetchTodayFitnessSummary() {
                fitnessContext = FitnessContext(
                    approximateSteps: summary.approximateSteps,
                    approximateActiveEnergyBurned: summary.approximateActiveEnergyBurned,
                    approximateDietaryEnergyConsumed: summary.approximateDietaryEnergyConsumed
                )
            }
            #endif
            lastResponseWasHeuristic = true
            return HeuristicAssistantEngine.respond(to: message, items: snapshots, fitnessSummary: fitnessContext)
        }

        lastResponseWasHeuristic = false
        let activeSession = warmSession(items: items, modelContext: modelContext)
        do {
            let response = try await activeSession.respond(
                to: Prompt { message },
                options: GenerationOptions(
                    temperature: 0.6,
                    maximumResponseTokens: 1024,
                    toolCallingMode: .allowed
                )
            )
            return response.content
        } catch {
            throw StashAssistantError.generationFailed
        }
    }

    /// Resets the conversation, e.g. when the user taps "New Chat" — a
    /// fresh session with no prior turns in context.
    func resetConversation() {
        session = nil
        sessionItemCount = -1
        sessionTier = nil
    }
}
