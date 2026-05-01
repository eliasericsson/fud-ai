//
//  CoachFoundationModelsTools.swift
//  calorietracker
//
//  Bridges the existing `CoachTools` executor (a struct that turns a tool name
//  + JSON args into a JSON string) into individual `FoundationModels.Tool`
//  conformances the on-device `LanguageModelSession` can call during a chat.
//
//  We deliberately produce one `Tool` per tool name (not a single parametric
//  Tool with a `toolName` argument) so each tool's `@Generable Arguments`
//  schema gives the model precise constrained-decoding hints — "expects an
//  ISO date string" is much more useful than "any string".
//
//  The cloud tier (ChatService.callOpenAICompatible / callAnthropic / callGemini)
//  builds its tool schema from `CoachTools.toolNames` + `toolDescriptions`. We
//  reuse those same descriptions here so the model sees identical guidance
//  regardless of which tier serves the chat.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
enum CoachFoundationModelsTools {

    /// Builds the array of FM tools to attach to a `LanguageModelSession`. Pass
    /// the same `CoachTools` instance the cloud tier would have built — the data
    /// snapshot is captured by value so each Tool sees the same view of the
    /// user's history during the entire turn.
    static func makeAll(executor: CoachTools) -> [any Tool] {
        [
            GetDataSummary(executor: executor),
            GetWeightHistory(executor: executor),
            GetBodyFatHistory(executor: executor),
            GetCalorieTotals(executor: executor),
            GetFoodEntries(executor: executor),
        ]
    }

    // MARK: - get_data_summary

    /// Counts + earliest/latest dates for weights/body-fats/foods. No arguments —
    /// `@Generable` allows empty argument structs but the FM API still wants a
    /// concrete type, so we declare an empty `Arguments`.
    @available(iOS 26.0, *)
    struct GetDataSummary: Tool {
        let executor: CoachTools
        let name = "get_data_summary"
        var description: String { CoachTools.toolDescriptions[name] ?? "" }

        @Generable
        struct Arguments {}

        func call(arguments: Arguments) async throws -> ToolOutput {
            ToolOutput(executor.execute(name: name, arguments: [:]))
        }
    }

    // MARK: - get_weight_history

    @available(iOS 26.0, *)
    struct GetWeightHistory: Tool {
        let executor: CoachTools
        let name = "get_weight_history"
        var description: String { CoachTools.toolDescriptions[name] ?? "" }

        @Generable
        struct Arguments {
            @Guide(description: "ISO date yyyy-MM-dd, inclusive start of the range to fetch.")
            let from: String
            @Guide(description: "ISO date yyyy-MM-dd, inclusive end of the range.")
            let to: String
            @Guide(description: "Optional maximum number of entries (default and cap is 365).")
            let limit: Int?
        }

        func call(arguments: Arguments) async throws -> ToolOutput {
            ToolOutput(executor.execute(name: name, arguments: argDict(arguments)))
        }

        private func argDict(_ args: Arguments) -> [String: Any] {
            var dict: [String: Any] = ["from": args.from, "to": args.to]
            if let limit = args.limit { dict["limit"] = limit }
            return dict
        }
    }

    // MARK: - get_body_fat_history

    @available(iOS 26.0, *)
    struct GetBodyFatHistory: Tool {
        let executor: CoachTools
        let name = "get_body_fat_history"
        var description: String { CoachTools.toolDescriptions[name] ?? "" }

        @Generable
        struct Arguments {
            @Guide(description: "ISO date yyyy-MM-dd, inclusive start.")
            let from: String
            @Guide(description: "ISO date yyyy-MM-dd, inclusive end.")
            let to: String
            @Guide(description: "Optional maximum number of entries (default and cap is 365).")
            let limit: Int?
        }

        func call(arguments: Arguments) async throws -> ToolOutput {
            var dict: [String: Any] = ["from": arguments.from, "to": arguments.to]
            if let limit = arguments.limit { dict["limit"] = limit }
            return ToolOutput(executor.execute(name: name, arguments: dict))
        }
    }

    // MARK: - get_calorie_totals

    @available(iOS 26.0, *)
    struct GetCalorieTotals: Tool {
        let executor: CoachTools
        let name = "get_calorie_totals"
        var description: String { CoachTools.toolDescriptions[name] ?? "" }

        @Generable
        struct Arguments {
            @Guide(description: "ISO date yyyy-MM-dd, inclusive start.")
            let from: String
            @Guide(description: "ISO date yyyy-MM-dd, inclusive end.")
            let to: String
        }

        func call(arguments: Arguments) async throws -> ToolOutput {
            ToolOutput(executor.execute(name: name, arguments: ["from": arguments.from, "to": arguments.to]))
        }
    }

    // MARK: - get_food_entries

    @available(iOS 26.0, *)
    struct GetFoodEntries: Tool {
        let executor: CoachTools
        let name = "get_food_entries"
        var description: String { CoachTools.toolDescriptions[name] ?? "" }

        @Generable
        struct Arguments {
            @Guide(description: "ISO date yyyy-MM-dd, inclusive start.")
            let from: String
            @Guide(description: "ISO date yyyy-MM-dd, inclusive end.")
            let to: String
            @Guide(description: "Optional maximum number of entries (default 200, cap 365).")
            let limit: Int?
        }

        func call(arguments: Arguments) async throws -> ToolOutput {
            var dict: [String: Any] = ["from": arguments.from, "to": arguments.to]
            if let limit = arguments.limit { dict["limit"] = limit }
            return ToolOutput(executor.execute(name: name, arguments: dict))
        }
    }
}
#endif
