//
//  StashIntelligenceProfiles.swift
//  StashKeeper
//
//  iOS 27 / Foundation Models v3 Dynamic Profiles. One session can swap
//  model, tools, temperature, and reasoning level per prompt instead of
//  tearing down LanguageModelSession. Analysis gets OCRTool +
//  BarcodeReaderTool so the AFM 3 on-device model can read packaging
//  itself; chat escalates reasoning when the user asks to cook or plan.
//

import Foundation
import FoundationModels
import SwiftData
import Vision

nonisolated final class DeepReasoningFlag: @unchecked Sendable {
    nonisolated(unsafe) var value = false
}

struct StashAnalysisProfile: LanguageModelSession.DynamicProfile {
    let tools: [any Tool]
    let instructionsText: String
    let preferCloud: Bool

    @LanguageModelSession.DynamicProfileBuilder
    var body: some LanguageModelSession.DynamicProfile {
        let onDevice = PreferredModelRouter.onDeviceModel(for: .contentTagging)
        if preferCloud, let pcc = PreferredModelRouter.privateCloudModelIfAvailable() {
            Profile {
                Instructions { instructionsText }
                tools
            }
            .model(pcc)
            .temperature(0.2)
            .samplingMode(.greedy)
            .maximumResponseTokens(2048)
            .reasoningLevel(.deep)
        } else {
            Profile {
                Instructions { instructionsText }
                tools
            }
            .model(onDevice)
            .temperature(0.2)
            .samplingMode(.greedy)
            .maximumResponseTokens(2048)
            .reasoningLevel(.moderate)
        }
    }
}

struct StashSearchProfile: LanguageModelSession.DynamicProfile {
    let tools: [any Tool]
    let instructionsText: String

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions { instructionsText }
            tools
        }
        .model(PreferredModelRouter.onDeviceModel(for: .contentTagging))
        .temperature(0.2)
        .samplingMode(.greedy)
        .reasoningLevel(.light)
    }
}

struct StashChatProfile: LanguageModelSession.DynamicProfile {
    let tools: [any Tool]
    let instructionsText: String
    let preferDeepReasoning: @Sendable () -> Bool

    @LanguageModelSession.DynamicProfileBuilder
    var body: some LanguageModelSession.DynamicProfile {
        let deep = preferDeepReasoning()
        let onDevice = PreferredModelRouter.onDeviceModel(for: .general)
        if deep, let pcc = PreferredModelRouter.privateCloudModelIfAvailable() {
            Profile {
                Instructions { instructionsText }
                tools
            }
            .model(pcc)
            .temperature(0.6)
            .reasoningLevel(.deep)
            .maximumResponseTokens(2048)
        } else {
            Profile {
                Instructions { instructionsText }
                tools
            }
            .model(onDevice)
            .temperature(0.4)
            .reasoningLevel(.moderate)
            .maximumResponseTokens(1024)
        }
    }
}

enum StashVisionTools {
    /// System Vision tools from `_Vision_FoundationModels` (imported via
    /// Vision + Foundation Models). The model calls these on labeled
    /// image attachments instead of relying only on our pre-OCR.
    static func analysisTools() -> [any Tool] {
        [
            OCRTool(),
            BarcodeReaderTool()
        ]
    }
}
