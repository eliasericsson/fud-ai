//
//  USDANutritionTool.swift
//  calorietracker
//
//  Foundation Models `Tool` that grounds nutrition estimates in USDA FoodData
//  Central. The on-device system model is small (~3B params) and will hallucinate
//  exact gram values without retrieval; surfacing this tool to a `LanguageModelSession`
//  lets the model identify the food + portion, then call out for ground-truth numbers.
//
//  Activation: Phase 2 ships the tool plumbing without bundling the actual database.
//  When `USDAFoodDatabase.shared.isAvailable` is false (no SQLite file in the bundle),
//  the tool reports unavailability to the model via its return text, and the model is
//  instructed to fall back to its own estimate. When the file IS bundled (after running
//  `scripts/fetch_usda.sh`), the tool returns ground-truth values and the model is
//  instructed to use them verbatim.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Tool definition surfaced to `LanguageModelSession` instances. Conforms to
/// `FoundationModels.Tool`; the framework reads `name`, `description`, and the
/// `Arguments` schema from `@Generable` to build a tool-call spec the model
/// can invoke during constrained generation.
@available(iOS 26.0, *)
struct USDANutritionTool: Tool {

    /// Tool identifier the model uses to invoke the call. Spelled with an
    /// underscore (not a hyphen) since some tokenizers split hyphens awkwardly.
    let name = "lookup_usda_nutrition"

    /// Description shown to the model. Kept terse but explicit about *when* the
    /// tool should be called — without this, small models tend to either over-
    /// invoke (every token) or under-invoke (never) depending on temperament.
    let description = """
    Looks up ground-truth nutrition data from the USDA FoodData Central database. \
    Use this tool whenever the user describes a single common food (e.g. "banana", \
    "grilled chicken breast", "1 cup brown rice") so your estimate is grounded in \
    real measurements rather than guessed. Skip it for branded composite meals \
    (e.g. "Chipotle burrito bowl") since USDA only covers raw and minimally \
    prepared foods. The tool returns per-100g values plus an optional portion \
    scaling — use those numbers verbatim for the final estimate.
    """

    /// Tool input schema. `@Generable` makes this readable to the framework's
    /// constrained-decoding layer so the model is guaranteed to emit a valid
    /// argument struct (or skip the call) — no parser, no retries.
    @Generable
    struct Arguments {
        @Guide(description: "Food name to search for. Use the simplest form, e.g. 'banana raw' or 'chicken breast grilled'. Avoid brand names — USDA doesn't cover them.")
        let foodName: String

        @Guide(description: "Optional portion weight in grams. Provide when you know the serving size; the tool returns scaled values. Omit for per-100g.")
        let portionGrams: Double?
    }

    /// Tool execution. Called synchronously by the FM session during generation;
    /// the returned `ToolOutput` text is fed back into the model's context window
    /// so it can decide whether to use the values or call again with a refined query.
    func call(arguments: Arguments) async throws -> ToolOutput {
        let db = USDAFoodDatabase.shared
        guard db.isAvailable else {
            return ToolOutput("USDA database is not bundled in this build. Estimate nutrition from your own training knowledge instead.")
        }

        let matches = db.search(query: arguments.foodName, limit: 3)
        guard let best = matches.first else {
            return ToolOutput("No USDA match found for '\(arguments.foodName)'. Estimate nutrition from your own training knowledge instead.")
        }

        let scale: Double = (arguments.portionGrams ?? 100) / 100
        let portionLabel: String = arguments.portionGrams.map { "per \(Int($0))g" } ?? "per 100g"
        let alternatives: String = matches.dropFirst().map { "  - \($0.description) (FDC \($0.fdcId))" }.joined(separator: "\n")
        let alternativesBlock: String = alternatives.isEmpty ? "" : "\nOther matches (call again with a more specific name if a different one fits better):\n\(alternatives)"

        return ToolOutput("""
        USDA match: \(best.description) (FDC ID: \(best.fdcId))\(best.foodCategory.map { ", category: \($0)" } ?? "")

        Values \(portionLabel):
        - Calories: \(formatScaled(best.kcalPer100g, scale: scale, unit: "kcal", decimals: 0))
        - Protein: \(formatScaled(best.proteinPer100g, scale: scale, unit: "g", decimals: 1))
        - Carbs: \(formatScaled(best.carbsPer100g, scale: scale, unit: "g", decimals: 1))
        - Fat: \(formatScaled(best.fatPer100g, scale: scale, unit: "g", decimals: 1))
        - Sugar: \(formatScaled(best.sugarPer100g, scale: scale, unit: "g", decimals: 1))
        - Added sugar: \(formatScaled(best.addedSugarPer100g, scale: scale, unit: "g", decimals: 1))
        - Fiber: \(formatScaled(best.fiberPer100g, scale: scale, unit: "g", decimals: 1))
        - Saturated fat: \(formatScaled(best.satFatPer100g, scale: scale, unit: "g", decimals: 1))
        - Monounsaturated fat: \(formatScaled(best.monoFatPer100g, scale: scale, unit: "g", decimals: 1))
        - Polyunsaturated fat: \(formatScaled(best.polyFatPer100g, scale: scale, unit: "g", decimals: 1))
        - Cholesterol: \(formatScaled(best.cholesterolMgPer100g, scale: scale, unit: "mg", decimals: 1))
        - Sodium: \(formatScaled(best.sodiumMgPer100g, scale: scale, unit: "mg", decimals: 1))
        - Potassium: \(formatScaled(best.potassiumMgPer100g, scale: scale, unit: "mg", decimals: 1))\(alternativesBlock)
        """)
    }

    /// Renders an optional Double with the requested scale + decimals, or the
    /// string "unknown" when the underlying USDA value was NULL. Keeping unknowns
    /// explicit (rather than printing 0) helps the model decide whether to fall
    /// back to its own estimate for a specific micronutrient.
    private func formatScaled(_ value: Double?, scale: Double, unit: String, decimals: Int) -> String {
        guard let value else { return "unknown" }
        let scaled = value * scale
        let format = "%.\(decimals)f"
        return "\(String(format: format, scaled))\(unit)"
    }
}
#endif
