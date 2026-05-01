//
//  FoundationModelsService.swift
//  calorietracker
//
//  Phase 0 of the on-device AI migration: a scaffold for Apple's `FoundationModels`
//  framework (iOS 26+). This file is intentionally inert — it isn't wired into the
//  call dispatch path yet, and adding the matching `AIProvider` enum case ships in
//  Phase 1. Phases 1–5 fill in the methods stubbed out below.
//
//  Why a separate service instead of bolting on to `GeminiService`:
//  - The cloud router routes by `apiFormat` and assumes a network roundtrip with
//    JSON parsing. On-device generation uses constrained decoding (`@Generable`),
//    so the call shape is fundamentally different.
//  - Keeps the cloud fallback tier untouched while we iterate on the on-device path.
//
//  The public method signatures intentionally mirror `GeminiService`'s so callers
//  can swap providers without changing their result-handling code.
//

import Foundation
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Thin wrapper around Apple's on-device `FoundationModels` framework.
///
/// Exposes the same return shapes as `GeminiService` (`FoodAnalysis`,
/// `NutritionLabelAnalysis`) so call sites don't need to know which tier
/// served the request. Each analysis method throws `.notImplemented` until
/// its corresponding migration phase ships.
enum FoundationModelsService {

    // MARK: - Errors

    enum AnalysisError: LocalizedError {
        /// Hardware doesn't support Apple Intelligence, OS too old, model still
        /// downloading, or user has it disabled in Settings.
        case unavailable(Availability)
        /// The phase that owns this method hasn't shipped yet.
        case notImplemented(phase: String)
        /// Underlying generation failure surfaced from the framework.
        case generationFailed(Error)
        /// Model returned content that didn't satisfy the `@Generable` schema.
        /// With constrained decoding this should be rare; surface clearly when it happens.
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable(let availability):
                return availability.userFacingDescription
            case .notImplemented(let phase):
                return "On-device AI for this flow ships in \(phase)."
            case .generationFailed(let error):
                return "On-device generation failed: \(error.localizedDescription)"
            case .invalidResponse:
                return "On-device model returned an unexpected response."
            }
        }
    }

    // MARK: - Availability

    /// Whether the device can run on-device AI right now. Wraps
    /// `SystemLanguageModel.default.availability` so callers don't have to deal
    /// with `#available` / `#if canImport` themselves.
    enum Availability: Equatable {
        case available
        case unavailableDeviceNotEligible       // iPhone < 15 Pro, non-Apple-Intelligence Macs/iPads
        case unavailableAppleIntelligenceOff    // user has it turned off in Settings
        case unavailableModelNotReady           // downloading or not yet downloaded
        case unavailableUnsupportedOS           // iOS < 26 (shouldn't trigger; deployment target is 26.2)
        case unavailableUnknown(String)

        var isAvailable: Bool { self == .available }

        /// Copy that's safe to show in Settings or in an error toast.
        var userFacingDescription: String {
            switch self {
            case .available:
                return "On-device AI is available."
            case .unavailableDeviceNotEligible:
                return "Your device doesn't support on-device AI. Use a cloud provider in Settings → AI Provider."
            case .unavailableAppleIntelligenceOff:
                return "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri to use on-device AI."
            case .unavailableModelNotReady:
                return "On-device model is still downloading. Try again in a few minutes."
            case .unavailableUnsupportedOS:
                return "Update to iOS 26 or later to use on-device AI."
            case .unavailableUnknown(let detail):
                return "On-device AI is unavailable: \(detail)"
            }
        }
    }

    /// Current availability of the system language model. Cheap to call — the
    /// framework caches the answer; safe to invoke on the main thread.
    static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return resolveAvailability(SystemLanguageModel.default.availability)
        } else {
            return .unavailableUnsupportedOS
        }
        #else
        return .unavailableUnsupportedOS
        #endif
    }

    static var isAvailable: Bool { availability.isAvailable }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func resolveAvailability(_ value: SystemLanguageModel.Availability) -> Availability {
        switch value {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailableDeviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .unavailableAppleIntelligenceOff
            case .modelNotReady:
                return .unavailableModelNotReady
            @unknown default:
                return .unavailableUnknown(String(describing: reason))
            }
        }
    }
    #endif

    // MARK: - Analysis API surface

    // The signatures below intentionally mirror `GeminiService`'s static methods so
    // a future provider-router change can call into either tier identically. They
    // throw `.notImplemented` until each phase lands.

    /// Phase 1 — Text path. Replaces `GeminiService.analyzeTextInput` with a
    /// `LanguageModelSession.respond(to:generating:)` call against a `@Generable`
    /// nutrition struct (constrained decoding eliminates the JSON brace-balancing
    /// parser used by the cloud tier).
    static func analyzeTextInput(description: String) async throws -> GeminiService.FoodAnalysis {
        try ensureAvailable()
        throw AnalysisError.notImplemented(phase: "Phase 1 — Text path")
    }

    /// Phase 4 — Vision multimodal. Will accept a `UIImage` directly (the
    /// `FoundationModels` system model supports image input on iOS 26+).
    static func analyzeFood(image: UIImage, description: String? = nil) async throws -> GeminiService.FoodAnalysis {
        try ensureAvailable()
        throw AnalysisError.notImplemented(phase: "Phase 4 — Vision multimodal")
    }

    /// Phase 3 — Vision OCR. Will run `VNRecognizeTextRequest` and pipe the
    /// extracted text into a `LanguageModelSession` with a `@Generable
    /// NutritionLabelAnalysis` schema for deterministic parsing.
    static func analyzeNutritionLabel(image: UIImage) async throws -> GeminiService.NutritionLabelAnalysis {
        try ensureAvailable()
        throw AnalysisError.notImplemented(phase: "Phase 3 — Vision OCR")
    }

    // MARK: - Helpers

    /// Throws `.unavailable` with the resolved reason if on-device AI isn't usable.
    /// Each public analysis method calls this first so callers get a consistent error
    /// shape regardless of which underlying availability state we're in.
    private static func ensureAvailable() throws {
        let state = availability
        guard state.isAvailable else {
            throw AnalysisError.unavailable(state)
        }
    }
}
