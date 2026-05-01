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
import Vision

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

    /// Phase 1 — Text path. Uses `LanguageModelSession.respond(to:generating:)` with a
    /// `@Generable` nutrition struct so the model is forced at the token level to emit
    /// fields matching our schema (no JSON parser, no brace-balancing, no markdown fence
    /// stripping). Falls back to cloud is handled in `GeminiService.analyzeTextInput`.
    static func analyzeTextInput(description: String) async throws -> GeminiService.FoodAnalysis {
        try ensureAvailable()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await TextPath.analyze(description: description)
        }
        #endif
        // Should be unreachable after `ensureAvailable()` — the availability check returns
        // `.unavailableUnsupportedOS` on anything pre-iOS 26 and we'd have thrown above.
        throw AnalysisError.unavailable(.unavailableUnsupportedOS)
    }

    /// Phase 4 — Vision multimodal. Passes the `UIImage` directly to the on-device
    /// system model (iOS 26's FoundationModels accepts image input). Reuses the
    /// `NutritionEstimate` schema from the text path so the result mapping is shared.
    static func analyzeFood(image: UIImage, description: String? = nil) async throws -> GeminiService.FoodAnalysis {
        try ensureAvailable()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await ImagePath.analyze(image: image, description: description)
        }
        #endif
        throw AnalysisError.unavailable(.unavailableUnsupportedOS)
    }

    /// Phase 4 — Auto-detect path: same multimodal call as `analyzeFood` but with a
    /// system instruction that branches between food-photo and nutrition-label
    /// interpretation. Mirrors `GeminiService.autoAnalyze`.
    static func autoAnalyze(image: UIImage) async throws -> GeminiService.FoodAnalysis {
        try ensureAvailable()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await ImagePath.autoAnalyze(image: image)
        }
        #endif
        throw AnalysisError.unavailable(.unavailableUnsupportedOS)
    }

    /// Phase 3 — Vision OCR. Runs `VNRecognizeTextRequest` to extract text from the
    /// label image, then feeds the text into a `LanguageModelSession` with a
    /// `@Generable NutritionLabelAnalysis` schema for deterministic parsing
    /// (constrained decoding eliminates the brace-balancing JSON parser the cloud
    /// tier needs).
    static func analyzeNutritionLabel(image: UIImage) async throws -> GeminiService.NutritionLabelAnalysis {
        try ensureAvailable()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await LabelPath.analyze(image: image)
        }
        #endif
        throw AnalysisError.unavailable(.unavailableUnsupportedOS)
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

// MARK: - Phase 1: Text path implementation

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum TextPath {

    /// Generation schema for nutrition estimation from a free-form text description.
    /// Field names are deliberately verbose so the model picks the right unit (e.g.
    /// `sugarGrams` vs `cholesterolMilligrams`) without us having to post-process.
    /// The macro layout matches `GeminiService.FoodAnalysis` so mapping is a 1:1 copy.
    @Generable
    struct NutritionEstimate {
        @Guide(description: "Common name of the food, e.g. 'Chicken Caesar Salad' or 'Chipotle Burrito Bowl'.")
        let name: String

        @Guide(description: "Total calories for the described serving (whole number).")
        let calories: Int

        @Guide(description: "Total protein in grams for the described serving (whole number).")
        let proteinGrams: Int

        @Guide(description: "Total carbohydrates in grams for the described serving (whole number).")
        let carbsGrams: Int

        @Guide(description: "Total fat in grams for the described serving (whole number).")
        let fatGrams: Int

        @Guide(description: "Estimated total weight of the described portion in grams.")
        let servingSizeGrams: Double

        @Guide(description: "A single food emoji that best represents this food, e.g. 🥗 or 🍕.")
        let emoji: String

        @Guide(description: "Total sugar in grams. Omit if not estimable.")
        let sugarGrams: Double?

        @Guide(description: "Added sugar in grams (excludes naturally occurring sugars). Omit if not estimable.")
        let addedSugarGrams: Double?

        @Guide(description: "Dietary fiber in grams. Omit if not estimable.")
        let fiberGrams: Double?

        @Guide(description: "Saturated fat in grams. Omit if not estimable.")
        let saturatedFatGrams: Double?

        @Guide(description: "Monounsaturated fat in grams. Omit if not estimable.")
        let monounsaturatedFatGrams: Double?

        @Guide(description: "Polyunsaturated fat in grams. Omit if not estimable.")
        let polyunsaturatedFatGrams: Double?

        @Guide(description: "Cholesterol in milligrams. Omit if not estimable.")
        let cholesterolMilligrams: Double?

        @Guide(description: "Sodium in milligrams. Omit if not estimable.")
        let sodiumMilligrams: Double?

        @Guide(description: "Potassium in milligrams. Omit if not estimable.")
        let potassiumMilligrams: Double?
    }

    static func analyze(description: String) async throws -> GeminiService.FoodAnalysis {
        // Attach the USDA tool whenever the bundled database is present. When it isn't,
        // we still pass the tool — it self-reports unavailability to the model — but it's
        // a no-op cost. Sending an empty tool list when missing skips the model's tool-call
        // overhead entirely; preferred path here is "tool always present, sometimes empty".
        let session = LanguageModelSession(
            tools: [USDANutritionTool()],
            instructions: Self.systemInstructions()
        )
        do {
            let response = try await session.respond(
                to: prompt(description: description),
                generating: NutritionEstimate.self
            )
            return mapToFoodAnalysis(response.content)
        } catch {
            throw FoundationModelsService.AnalysisError.generationFailed(error)
        }
    }

    /// Builds the system instruction prepended to every text-path session. Always includes
    /// the nutrition coach framing; appends the user's free-form `userContext` from
    /// Settings when set (matches the cloud tier's behaviour at AIProvider.swift's
    /// system-instruction injection points). Phase 2 adds tool-usage guidance — without
    /// explicit instructions, small models tend to call the USDA tool too often or not
    /// at all, so the framing is deliberately prescriptive about *when* to invoke it.
    private static func systemInstructions() -> String {
        let base = """
        You are a nutrition expert helping a calorie tracking app. Estimate nutritional content for the food the user describes. Use ranges typical of the portion size implied by the description. If a brand name is given, use that brand's known values. If multiple items are described, sum their totals. Round whole-gram macros to the nearest gram. Use the units stated in each field's description (grams vs. milligrams).

        When the user describes a single common food (raw or minimally prepared, no brand), call the lookup_usda_nutrition tool with the simplest form of the food name and the portion in grams if known. Use the values returned verbatim — do not adjust them. Skip the tool for branded composite meals (e.g. restaurant items) since USDA doesn't cover them; estimate those from your own knowledge.
        """
        if let userContext = AIProviderSettings.currentUserContext {
            return base + "\n\nAdditional user context (apply when relevant):\n" + userContext
        }
        return base
    }

    private static func prompt(description: String) -> String {
        "Estimate nutrition for: \(description)"
    }

    /// Adapts the on-device schema into the cloud-shape `FoodAnalysis` struct that the
    /// rest of the app already speaks. Keeping a single public shape means views,
    /// FoodEntry mapping, and HealthKit writes don't care which tier produced the data.
    private static func mapToFoodAnalysis(_ estimate: NutritionEstimate) -> GeminiService.FoodAnalysis {
        GeminiService.FoodAnalysis(
            name: estimate.name,
            calories: estimate.calories,
            protein: estimate.proteinGrams,
            carbs: estimate.carbsGrams,
            fat: estimate.fatGrams,
            servingSizeGrams: estimate.servingSizeGrams,
            emoji: estimate.emoji,
            sugar: estimate.sugarGrams,
            addedSugar: estimate.addedSugarGrams,
            fiber: estimate.fiberGrams,
            saturatedFat: estimate.saturatedFatGrams,
            monounsaturatedFat: estimate.monounsaturatedFatGrams,
            polyunsaturatedFat: estimate.polyunsaturatedFatGrams,
            cholesterol: estimate.cholesterolMilligrams,
            sodium: estimate.sodiumMilligrams,
            potassium: estimate.potassiumMilligrams
        )
    }
}
#endif

// MARK: - Phase 3: Vision OCR + label parsing

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum LabelPath {

    /// Generation schema for nutrition-label parsing. Per-100g/-100ml only; if the
    /// label only shows per-serving, the model is instructed to convert. Mirrors
    /// `GeminiService.NutritionLabelAnalysis` 1:1 so `scaled(to:)` keeps working.
    @Generable
    struct LabelData {
        @Guide(description: "Product or brand name as visible on the package. If no name is visible, describe the food type ('Protein Bar', 'Yogurt').")
        let productName: String

        @Guide(description: "Calories per 100g (or per 100ml for liquids). Convert from per-serving if the label only shows that.")
        let caloriesPer100g: Double

        @Guide(description: "Protein grams per 100g.")
        let proteinPer100g: Double

        @Guide(description: "Carbohydrates in grams per 100g.")
        let carbsPer100g: Double

        @Guide(description: "Total fat in grams per 100g.")
        let fatPer100g: Double

        @Guide(description: "Serving size in grams as printed on the label. Omit if the label doesn't state it.")
        let servingSizeGrams: Double?

        @Guide(description: "Sugar in grams per 100g. Omit if not on the label.")
        let sugarPer100g: Double?

        @Guide(description: "Added sugar in grams per 100g. Omit if not on the label.")
        let addedSugarPer100g: Double?

        @Guide(description: "Fiber in grams per 100g. Omit if not on the label.")
        let fiberPer100g: Double?

        @Guide(description: "Saturated fat in grams per 100g. Omit if not on the label.")
        let saturatedFatPer100g: Double?

        @Guide(description: "Monounsaturated fat in grams per 100g. Omit if not on the label.")
        let monounsaturatedFatPer100g: Double?

        @Guide(description: "Polyunsaturated fat in grams per 100g. Omit if not on the label.")
        let polyunsaturatedFatPer100g: Double?

        @Guide(description: "Cholesterol in milligrams per 100g. Omit if not on the label.")
        let cholesterolPer100g: Double?

        @Guide(description: "Sodium in milligrams per 100g. Omit if not on the label.")
        let sodiumPer100g: Double?

        @Guide(description: "Potassium in milligrams per 100g. Omit if not on the label.")
        let potassiumPer100g: Double?
    }

    /// End-to-end pipeline: image → OCR → FM → typed struct. Both stages can fail;
    /// errors are wrapped as `FoundationModelsService.AnalysisError` so the caller
    /// can decide whether to fall back to cloud (handled in `GeminiService`).
    static func analyze(image: UIImage) async throws -> GeminiService.NutritionLabelAnalysis {
        let recognizedText = try await recognizeText(in: image)
        guard !recognizedText.isEmpty else {
            throw FoundationModelsService.AnalysisError.invalidResponse
        }

        let session = LanguageModelSession(instructions: systemInstructions())
        do {
            let response = try await session.respond(
                to: prompt(ocrText: recognizedText),
                generating: LabelData.self
            )
            return mapToLabelAnalysis(response.content)
        } catch {
            throw FoundationModelsService.AnalysisError.generationFailed(error)
        }
    }

    // MARK: - Vision OCR

    /// Runs `VNRecognizeTextRequest` over the image and joins recognized lines into
    /// a single string. The recognition level is `.accurate` since labels often have
    /// small print and we'd rather pay the latency than miss "trans fat" or "sodium".
    /// Language correction is OFF — nutrition labels use specialized vocabulary
    /// ("polyunsaturated", brand names) that the system dictionary often mangles.
    private static func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw FoundationModelsService.AnalysisError.invalidResponse
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: FoundationModelsService.AnalysisError.generationFailed(error))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // topCandidates(1) gives the highest-confidence transcription per region.
                // Joining with newlines preserves the natural line layout the LLM uses
                // to pair "Protein" with its adjacent "25g" value.
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // Recognize US English by default; Vision auto-detects scripts so no need to
            // enumerate every language. Apps shipping localized markets can extend this.
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(for: image.imageOrientation))
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: FoundationModelsService.AnalysisError.generationFailed(error))
            }
        }
    }

    /// UIImage exposes orientation as `UIImage.Orientation`; Vision wants a
    /// `CGImagePropertyOrientation`. The mapping is fixed and well-known but
    /// not in any standard library, so we keep the table local.
    private static func cgOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    // MARK: - System instruction + prompt

    private static func systemInstructions() -> String {
        let base = """
        You parse nutrition facts panels into a structured per-100g schema. The user gives you raw OCR output from a photo of a label — text may be mis-ordered, missing punctuation, or contain unrelated package text. Pull out the nutrition values and convert to per-100g if the label only shows per-serving (multiply per-serving values by 100/serving_size_grams). Use null for any field not visible on the label rather than guessing. The serving_size_grams field stores the label's own stated serving size (not 100); leave it null if the label doesn't state it.
        """
        if let userContext = AIProviderSettings.currentUserContext {
            return base + "\n\nAdditional user context (apply when relevant):\n" + userContext
        }
        return base
    }

    private static func prompt(ocrText: String) -> String {
        """
        Parse the nutrition facts from this OCR output:

        \(ocrText)
        """
    }

    // MARK: - Mapping back to the cloud-shape struct

    private static func mapToLabelAnalysis(_ data: LabelData) -> GeminiService.NutritionLabelAnalysis {
        GeminiService.NutritionLabelAnalysis(
            name: data.productName,
            caloriesPer100g: data.caloriesPer100g,
            proteinPer100g: data.proteinPer100g,
            carbsPer100g: data.carbsPer100g,
            fatPer100g: data.fatPer100g,
            servingSizeGrams: data.servingSizeGrams,
            sugarPer100g: data.sugarPer100g,
            addedSugarPer100g: data.addedSugarPer100g,
            fiberPer100g: data.fiberPer100g,
            saturatedFatPer100g: data.saturatedFatPer100g,
            monounsaturatedFatPer100g: data.monounsaturatedFatPer100g,
            polyunsaturatedFatPer100g: data.polyunsaturatedFatPer100g,
            cholesterolPer100g: data.cholesterolPer100g,
            sodiumPer100g: data.sodiumPer100g,
            potassiumPer100g: data.potassiumPer100g
        )
    }
}
#endif

// MARK: - Phase 4: Multimodal food-photo path

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum ImagePath {

    /// Direct food-photo analysis. Reuses `TextPath.NutritionEstimate` so views and
    /// FoodEntry mapping don't get a third schema to learn — the only thing changing
    /// is what's in the model's input window (food image + optional caption).
    static func analyze(image: UIImage, description: String?) async throws -> GeminiService.FoodAnalysis {
        let session = LanguageModelSession(
            tools: [USDANutritionTool()],
            instructions: foodPhotoInstructions(extraContext: description)
        )
        do {
            let prompt = try buildPrompt(
                image: image,
                instructionText: "Identify the food in this image and estimate nutrition for the visible serving."
            )
            let response = try await session.respond(
                to: prompt,
                generating: TextPath.NutritionEstimate.self
            )
            return TextPath.mapToFoodAnalysisInternal(response.content)
        } catch {
            throw FoundationModelsService.AnalysisError.generationFailed(error)
        }
    }

    /// Auto-detect path: the user took a single photo that could be either a food or
    /// a nutrition label. The model picks the right interpretation from the image
    /// itself; same return shape either way (label values are scaled to the implied
    /// serving by the model rather than going through `NutritionLabelAnalysis.scaled`).
    static func autoAnalyze(image: UIImage) async throws -> GeminiService.FoodAnalysis {
        let session = LanguageModelSession(
            tools: [USDANutritionTool()],
            instructions: autoDetectInstructions()
        )
        do {
            let prompt = try buildPrompt(
                image: image,
                instructionText: "Decide whether this image is a food photo or a nutrition facts label, then estimate nutrition for one serving."
            )
            let response = try await session.respond(
                to: prompt,
                generating: TextPath.NutritionEstimate.self
            )
            return TextPath.mapToFoodAnalysisInternal(response.content)
        } catch {
            throw FoundationModelsService.AnalysisError.generationFailed(error)
        }
    }

    // MARK: - Prompt assembly

    /// Builds a multimodal `Prompt` containing the image followed by the instruction
    /// text. The exact API for image attachment in `LanguageModelSession`'s prompt
    /// builder is `Prompt { ... }` with image segments — uses the public initializer
    /// that takes a `CGImage`. We extract the CG image from `UIImage` (with an
    /// orientation-preserving redraw fallback) before building the prompt so the
    /// model sees the image right-side up.
    private static func buildPrompt(image: UIImage, instructionText: String) throws -> Prompt {
        let cgImage = try cgImageRespectingOrientation(image)
        return Prompt {
            // Image first so the model attends to it before reading the textual prompt;
            // empirically gives slightly more coherent food identification on small models.
            PromptSegment.image(cgImage)
            instructionText
        }
    }

    /// `UIImage.cgImage` is the *raw* pixel buffer, ignoring `imageOrientation`. If
    /// the user took a photo in portrait mode, `cgImage` will be sideways — feeding
    /// that to the model gives terrible identification accuracy. Re-render the image
    /// into a fresh upright CGImage when orientation isn't already `.up`.
    private static func cgImageRespectingOrientation(_ image: UIImage) throws -> CGImage {
        if image.imageOrientation == .up, let cg = image.cgImage {
            return cg
        }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let upright = renderer.image { _ in
            image.draw(at: .zero)
        }
        guard let cg = upright.cgImage else {
            throw FoundationModelsService.AnalysisError.invalidResponse
        }
        return cg
    }

    // MARK: - System instructions

    /// Food-photo framing. Identical macro-coach persona as TextPath, plus explicit
    /// guidance about portion estimation from visible cues (utensil scale, plate
    /// size). Optional caption from the user is appended verbatim — the cloud tier
    /// does the same thing in `GeminiService.analyzeFood`.
    private static func foodPhotoInstructions(extraContext: String?) -> String {
        var base = """
        You are a nutrition expert helping a calorie tracking app. Identify the food shown in the image and estimate nutritional content for the visible serving. Use visual cues for portion size — utensil and plate scale, packaging text, distinctive ingredients. If multiple foods are visible, sum their totals. Round whole-gram macros to the nearest gram. Use the units stated in each field's description (grams vs. milligrams).

        When the food is a single common item (raw or minimally prepared, no brand), call the lookup_usda_nutrition tool with the food name and your portion estimate so your numbers are grounded. Skip the tool for branded composite meals (restaurants, packaged ready-meals).
        """
        if let extra = extraContext?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            base += "\n\nAdditional context from the user about this meal: \(extra)\nUse this context to improve identification, portion size, and nutrition estimates."
        }
        if let userContext = AIProviderSettings.currentUserContext {
            base += "\n\nAdditional user context (apply when relevant):\n" + userContext
        }
        return base
    }

    /// Auto-detect framing. Tells the model that the input could be either kind of
    /// image, and that either way the output schema is the same `NutritionEstimate`.
    /// Subtle but important — without this, the model sometimes refuses to output
    /// food-shaped data when it sees a nutrition label.
    private static func autoDetectInstructions() -> String {
        var base = """
        You analyze food-related images for a calorie tracking app. The image is either a photo of food or a photo of a nutrition facts label.

        If it's food: identify what's shown and estimate nutrition for the serving visible.
        If it's a label: read the values and emit nutrition for one serving as the label states (multiply per-100g values by serving_size/100 if needed).

        Either way, fill in the same schema. Use the units stated in each field's description (grams vs. milligrams). Set servingSizeGrams to the estimated weight of one serving in grams.
        """
        if let userContext = AIProviderSettings.currentUserContext {
            base += "\n\nAdditional user context (apply when relevant):\n" + userContext
        }
        return base
    }
}
#endif

// MARK: - Internal mapping bridge for ImagePath

#if canImport(FoundationModels)
@available(iOS 26.0, *)
extension TextPath {
    /// `mapToFoodAnalysis` is private to `TextPath`; ImagePath needs the same mapping
    /// since both use the same `NutritionEstimate` schema. Expose an internal alias
    /// rather than duplicating the field-by-field copy.
    static func mapToFoodAnalysisInternal(_ estimate: NutritionEstimate) -> GeminiService.FoodAnalysis {
        mapToFoodAnalysis(estimate)
    }
}
#endif
