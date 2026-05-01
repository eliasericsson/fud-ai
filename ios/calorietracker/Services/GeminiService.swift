import Foundation
import UIKit

struct GeminiService {
    struct FoodAnalysis {
        var name: String
        var calories: Int
        var protein: Int
        var carbs: Int
        var fat: Int
        var servingSizeGrams: Double
        var emoji: String?
        var sugar: Double?
        var addedSugar: Double?
        var fiber: Double?
        var saturatedFat: Double?
        var monounsaturatedFat: Double?
        var polyunsaturatedFat: Double?
        var cholesterol: Double?
        var sodium: Double?
        var potassium: Double?
    }

    struct NutritionLabelAnalysis {
        var name: String
        var caloriesPer100g: Double
        var proteinPer100g: Double
        var carbsPer100g: Double
        var fatPer100g: Double
        var servingSizeGrams: Double?
        var sugarPer100g: Double?
        var addedSugarPer100g: Double?
        var fiberPer100g: Double?
        var saturatedFatPer100g: Double?
        var monounsaturatedFatPer100g: Double?
        var polyunsaturatedFatPer100g: Double?
        var cholesterolPer100g: Double?
        var sodiumPer100g: Double?
        var potassiumPer100g: Double?

        func scaled(to grams: Double) -> FoodAnalysis {
            let scale = grams / 100
            return FoodAnalysis(
                name: name,
                calories: Int(round(caloriesPer100g * scale)),
                protein: Int(round(proteinPer100g * scale)),
                carbs: Int(round(carbsPer100g * scale)),
                fat: Int(round(fatPer100g * scale)),
                servingSizeGrams: grams,
                sugar: sugarPer100g.map { round($0 * scale * 10) / 10 },
                addedSugar: addedSugarPer100g.map { round($0 * scale * 10) / 10 },
                fiber: fiberPer100g.map { round($0 * scale * 10) / 10 },
                saturatedFat: saturatedFatPer100g.map { round($0 * scale * 10) / 10 },
                monounsaturatedFat: monounsaturatedFatPer100g.map { round($0 * scale * 10) / 10 },
                polyunsaturatedFat: polyunsaturatedFatPer100g.map { round($0 * scale * 10) / 10 },
                cholesterol: cholesterolPer100g.map { round($0 * scale * 10) / 10 },
                sodium: sodiumPer100g.map { round($0 * scale * 10) / 10 },
                potassium: potassiumPer100g.map { round($0 * scale * 10) / 10 }
            )
        }
    }

    enum AnalysisError: LocalizedError {
        case noAPIKey
        case imageConversionFailed
        case networkError(Error)
        case invalidResponse
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No API key configured. Add your key in Settings → AI Provider."
            case .imageConversionFailed:
                return "Failed to process the image."
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Could not understand the AI response. Please try again."
            case .apiError(let message):
                return "API error: \(message)"
            }
        }
    }

    // MARK: - Public API (unchanged interface)

    static func analyzeTextInput(description: String) async throws -> FoodAnalysis {
        // On-device path: route through FoundationModels when the user picks it as their
        // primary provider. Constrained decoding via @Generable means we get a typed
        // struct back — no JSON parser needed. On any FM failure (unavailable hardware,
        // generation error) we fall back to the cloud path below if a fallback is
        // configured, otherwise we surface the error.
        if AIProviderSettings.selectedProvider == .foundationModels {
            do {
                return try await FoundationModelsService.analyzeTextInput(description: description)
            } catch {
                guard let fallback = AIProviderSettings.currentFallbackConfig(excludingPrimary: .foundationModels) else {
                    throw error
                }
                let prompt = textInputPrompt(description: description)
                let text = try await dispatch(
                    provider: fallback.provider, model: fallback.model,
                    baseURL: fallback.baseURL, apiKey: fallback.apiKey,
                    prompt: prompt, imageData: nil
                )
                return try parseFoodAnalysis(from: text)
            }
        }

        let prompt = textInputPrompt(description: description)
        let text = try await callAI(prompt: prompt, image: nil)
        return try parseFoodAnalysis(from: text)
    }

    /// Cloud-tier prompt for text → nutrition. Lifted into a helper so the
    /// FoundationModels fallback path can build the same prompt without duplication.
    private static func textInputPrompt(description: String) -> String {
        """
        Estimate the nutritional content for: \(description)
        Parse any quantities, brands, and multiple items from the text. If a brand is mentioned, use that brand's known nutritional data. If multiple items are described, sum up the total nutrition.
        Respond ONLY with JSON:
        {"name":"...","calories":0,"protein":0,"carbs":0,"fat":0,"serving_size_grams":0.0,"emoji":"🍽️","sugar":0.0,"added_sugar":0.0,"fiber":0.0,"saturated_fat":0.0,"monounsaturated_fat":0.0,"polyunsaturated_fat":0.0,"cholesterol":0.0,"sodium":0.0,"potassium":0.0}
        Calories/protein/carbs/fat are integers. serving_size_grams is the estimated total weight in grams. Micronutrients are numbers (sugar/fiber/sat fat/mono fat/poly fat in grams, cholesterol/sodium/potassium in milligrams).
        Include a single food emoji that best represents the food. Use null for any nutrient you cannot estimate.
        """
    }

    static func autoAnalyze(image: UIImage) async throws -> FoodAnalysis {
        let prompt = """
        Analyze this image. It could be either a photo of food OR a nutrition facts label.

        If it's a food photo: identify the food and estimate nutritional content for the serving shown.
        If it's a nutrition label: read the values and calculate for one serving size as listed on the label.

        Respond ONLY with JSON:
        {"name":"...","calories":0,"protein":0,"carbs":0,"fat":0,"serving_size_grams":0.0,"sugar":0.0,"added_sugar":0.0,"fiber":0.0,"saturated_fat":0.0,"monounsaturated_fat":0.0,"polyunsaturated_fat":0.0,"cholesterol":0.0,"sodium":0.0,"potassium":0.0}
        Calories/protein/carbs/fat are integers. serving_size_grams is the estimated weight in grams of the serving. Micronutrients are numbers (sugar/fiber/sat fat/mono fat/poly fat in grams, cholesterol/sodium/potassium in milligrams).
        Use null for any nutrient you cannot estimate.
        """
        let text = try await callAI(prompt: prompt, image: image)
        return try parseFoodAnalysis(from: text)
    }

    static func analyzeFood(image: UIImage, description: String? = nil) async throws -> FoodAnalysis {
        var prompt = """
        Analyze this food image. Identify the food and estimate its nutritional content.

        Respond ONLY with a JSON object in this exact format, no other text:
        {"name":"Food Name","calories":0,"protein":0,"carbs":0,"fat":0,"serving_size_grams":0.0,"sugar":0.0,"added_sugar":0.0,"fiber":0.0,"saturated_fat":0.0,"monounsaturated_fat":0.0,"polyunsaturated_fat":0.0,"cholesterol":0.0,"sodium":0.0,"potassium":0.0}

        Calories/protein/carbs/fat are integers. serving_size_grams is the estimated weight in grams of the serving shown. Micronutrients are numbers (sugar/fiber/sat fat/mono fat/poly fat in grams, cholesterol/sodium/potassium in milligrams).
        Give your best estimate for a typical serving size shown in the image. Use null for any nutrient you cannot estimate.
        """

        if let description, !description.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt += "\n\nAdditional context from the user about this meal: \(description)\nUse this context to improve accuracy of identification, portion size, and nutrition estimates."
        }

        let text = try await callAI(prompt: prompt, image: image)
        return try parseFoodAnalysis(from: text)
    }

    static func analyzeNutritionLabel(image: UIImage) async throws -> NutritionLabelAnalysis {
        // On-device path: Vision (`VNRecognizeTextRequest`) extracts text, then a
        // FoundationModels session with a @Generable label schema parses it. Two-stage
        // because the system model accepts text more reliably than label imagery — and
        // Vision OCR is already the highest-accuracy text extractor on the platform.
        if AIProviderSettings.selectedProvider == .foundationModels {
            do {
                return try await FoundationModelsService.analyzeNutritionLabel(image: image)
            } catch {
                guard let fallback = AIProviderSettings.currentFallbackConfig(excludingPrimary: .foundationModels) else {
                    throw error
                }
                guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                    throw AnalysisError.imageConversionFailed
                }
                let prompt = nutritionLabelPrompt()
                let text = try await dispatch(
                    provider: fallback.provider, model: fallback.model,
                    baseURL: fallback.baseURL, apiKey: fallback.apiKey,
                    prompt: prompt, imageData: imageData
                )
                return try parseNutritionLabel(from: text)
            }
        }

        let prompt = nutritionLabelPrompt()
        let text = try await callAI(prompt: prompt, image: image)
        return try parseNutritionLabel(from: text)
    }

    /// Cloud-tier prompt for nutrition label OCR. Lifted into a helper so the
    /// FoundationModels fallback path can build the same prompt without duplication.
    private static func nutritionLabelPrompt() -> String {
        """
        Read this nutrition label image. Extract the nutritional values per 100g (or per 100ml).
        If the label shows per-serving values, convert them to per-100g using the serving size.

        For the name, identify the product or brand name visible on the packaging or label.
        If no name is visible, describe the food type (e.g. "Protein Bar", "Yogurt", "Cereal").

        Respond ONLY with JSON:
        {"name":"Product Name","calories_per_100g":0.0,"protein_per_100g":0.0,"carbs_per_100g":0.0,"fat_per_100g":0.0,"serving_size_grams":0.0,"sugar_per_100g":0.0,"added_sugar_per_100g":0.0,"fiber_per_100g":0.0,"saturated_fat_per_100g":0.0,"monounsaturated_fat_per_100g":0.0,"polyunsaturated_fat_per_100g":0.0,"cholesterol_per_100g":0.0,"sodium_per_100g":0.0,"potassium_per_100g":0.0}

        All values should be numbers. If serving size or any nutrient is not available, use null.
        """
    }

    // MARK: - Weight Forecast Insight

    /// Asks the user's selected LLM to summarize their weight trend and suggest 2–3 adjustments
    /// in plain English. Caller provides an already-computed WeightForecast so the LLM gets hard
    /// numbers instead of guessing.
    static func analyzeWeightTrend(
        profile: UserProfile,
        forecast: WeightForecast,
        recentAvgMacros: (protein: Int, carbs: Int, fat: Int)?,
        useMetric: Bool
    ) async throws -> String {
        let unit = useMetric ? "kg" : "lbs"
        let wUnit: (Double) -> String = { kg in
            useMetric ? String(format: "%.1f kg", kg) : String(format: "%.1f lbs", kg * 2.20462)
        }
        let weekly: (Double) -> String = { kg in
            useMetric ? String(format: "%+.2f kg/week", kg) : String(format: "%+.2f lbs/week", kg * 2.20462)
        }

        var lines: [String] = []
        lines.append("User profile:")
        lines.append("- Gender: \(profile.gender.rawValue)")
        lines.append("- Age: \(profile.age)")
        lines.append("- Height: \(useMetric ? String(format: "%.0f cm", profile.heightCm) : String(format: "%.1f in", profile.heightCm / 2.54))")
        lines.append("- Current weight: \(wUnit(forecast.currentWeightKg))")
        lines.append("- Activity level: \(profile.activityLevel.displayName)")
        lines.append("- Goal: \(profile.goal.displayName)")
        if let goal = profile.goalWeightKg {
            lines.append("- Goal weight: \(wUnit(goal))")
        }
        if let bf = profile.bodyFatPercentage {
            lines.append("- Body fat: \(Int(bf * 100))%")
        }
        lines.append("")
        lines.append("Energy balance (from \(forecast.daysOfFoodData) days of logged food):")
        lines.append("- Avg daily intake: \(forecast.avgDailyCalories) kcal")
        lines.append("- TDEE estimate: \(forecast.tdee) kcal")
        lines.append("- Daily balance: \(forecast.dailyEnergyBalance >= 0 ? "+" : "")\(forecast.dailyEnergyBalance) kcal")
        if let macros = recentAvgMacros {
            lines.append("- Avg macros: \(macros.protein)g protein, \(macros.carbs)g carbs, \(macros.fat)g fat")
        }
        lines.append("")
        lines.append("Projection:")
        lines.append("- Predicted (from diet): \(weekly(forecast.predictedWeeklyChangeKg))")
        if let observed = forecast.observedWeeklyChangeKg {
            lines.append("- Observed (from \(forecast.weightEntriesUsed) weight entries): \(weekly(observed))")
        }
        lines.append("- Expected weight in 30 days: \(wUnit(forecast.predictedWeight30dKg))")
        lines.append("- Expected weight in 90 days: \(wUnit(forecast.predictedWeight90dKg))")
        if let days = forecast.daysToGoal {
            lines.append("- At current pace, reach goal in ~\(days) days")
        }
        if forecast.trendsDisagree {
            lines.append("- NOTE: predicted and observed trends differ by >0.3 kg/week (possibly under-logging food).")
        }

        let prompt = """
        You are a nutrition coach analyzing a user's weight trend. Write 3–4 short sentences (plain English, no bullets, no markdown, no bold) that:
        1. State the predicted weight in \(unit) 30 days out and whether they're on track for their goal.
        2. Give one or two specific, actionable suggestions (e.g. calorie target, protein amount, activity change) grounded in the numbers below.
        3. If predicted and observed trends disagree, mention possible under-logging briefly.
        Be direct, factual, and encouraging. Do not exceed 100 words.

        \(lines.joined(separator: "\n"))
        """
        return try await callAI(prompt: prompt, image: nil)
    }

    // MARK: - Unified AI Call Router

    private static func callAI(prompt: String, image: UIImage?) async throws -> String {
        let primaryProvider = AIProviderSettings.selectedProvider
        if primaryProvider.requiresAPIKey, AIProviderSettings.currentAPIKey == nil {
            throw AnalysisError.noAPIKey
        }

        var imageData: Data?
        if let image {
            guard let data = image.jpegData(compressionQuality: 0.8) else {
                throw AnalysisError.imageConversionFailed
            }
            imageData = data
        }

        do {
            return try await dispatch(
                provider: primaryProvider,
                model: AIProviderSettings.selectedModel,
                baseURL: AIProviderSettings.currentBaseURL,
                apiKey: AIProviderSettings.currentAPIKey,
                prompt: prompt,
                imageData: imageData
            )
        } catch {
            // imageConversionFailed is local — fallback won't help, rethrow.
            // For everything else (network / 5xx / 4xx / parser failure) try fallback.
            if case AnalysisError.imageConversionFailed = error { throw error }
            guard let fallback = AIProviderSettings.currentFallbackConfig(excludingPrimary: primaryProvider) else {
                throw error
            }
            return try await dispatch(
                provider: fallback.provider,
                model: fallback.model,
                baseURL: fallback.baseURL,
                apiKey: fallback.apiKey,
                prompt: prompt,
                imageData: imageData
            )
        }
    }

    private static func dispatch(provider: AIProvider, model: String, baseURL: String, apiKey: String?, prompt: String, imageData: Data?) async throws -> String {
        switch provider.apiFormat {
        case .foundationModels:
            // FoundationModels uses constrained decoding on @Generable structs, not free-form text.
            // Each top-level analysis method routes to FoundationModelsService directly before
            // reaching here, so this case is only hit when something tries to dispatch FM through
            // the cloud router (a programmer error). Surface it loudly rather than silently failing.
            throw AnalysisError.apiError("FoundationModels can't be dispatched through the cloud router. Call FoundationModelsService directly.")
        case .gemini:
            guard let key = apiKey else { throw AnalysisError.noAPIKey }
            return try await callGemini(baseURL: baseURL, model: model, apiKey: key, prompt: prompt, imageData: imageData)
        case .openaiCompatible:
            return try await callOpenAICompatible(baseURL: baseURL, model: model, apiKey: apiKey, provider: provider, prompt: prompt, imageData: imageData)
        case .anthropic:
            guard let key = apiKey else { throw AnalysisError.noAPIKey }
            return try await callAnthropic(baseURL: baseURL, model: model, apiKey: key, prompt: prompt, imageData: imageData)
        }
    }

    // MARK: - Gemini Format

    private static func callGemini(baseURL: String, model: String, apiKey: String, prompt: String, imageData: Data?) async throws -> String {
        // Send the API key in the X-goog-api-key header, not the URL query string,
        // so it doesn't end up in server logs / proxies (CodeQL: cleartext transmission).
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent") else {
            throw AnalysisError.apiError("Invalid API URL. Check your provider settings.")
        }

        var parts: [[String: Any]] = []
        if let imageData {
            parts.append([
                "inlineData": [
                    "mimeType": "image/jpeg",
                    "data": imageData.base64EncodedString()
                ]
            ])
        }
        parts.append(["text": prompt])

        var body: [String: Any] = [
            "contents": [["parts": parts]]
        ]
        if let userContext = AIProviderSettings.currentUserContext {
            body["systemInstruction"] = ["parts": [["text": userContext]]]
        }

        let data = try await makeRequest(
            url: url,
            headers: ["Content-Type": "application/json", "X-goog-api-key": apiKey],
            body: body
        )

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String
        else { throw AnalysisError.invalidResponse }
        return text
    }

    // MARK: - OpenAI-Compatible Format (OpenAI, xAI, OpenRouter, Together, Groq, Ollama)

    private static func callOpenAICompatible(baseURL: String, model: String, apiKey: String?, provider: AIProvider, prompt: String, imageData: Data?) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AnalysisError.apiError("Invalid API URL. Check your provider settings.")
        }

        var content: [[String: Any]] = []
        if let imageData {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"]
            ])
        }
        content.append(["type": "text", "text": prompt])

        var messages: [[String: Any]] = []
        if let userContext = AIProviderSettings.currentUserContext {
            messages.append(["role": "system", "content": userContext])
        }
        messages.append(["role": "user", "content": content])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 1024,
        ]

        var headers = ["Content-Type": "application/json"]
        if let apiKey {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        if provider == .openrouter {
            headers["HTTP-Referer"] = "https://github.com/apoorvdarshan/fud-ai"
            headers["X-Title"] = "Fud AI"
        }

        let data = try await makeRequest(url: url, headers: headers, body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String
        else { throw AnalysisError.invalidResponse }
        return text
    }

    // MARK: - Anthropic Format

    private static func callAnthropic(baseURL: String, model: String, apiKey: String, prompt: String, imageData: Data?) async throws -> String {
        guard let url = URL(string: "\(baseURL)/messages") else {
            throw AnalysisError.apiError("Invalid API URL. Check your provider settings.")
        }

        var content: [[String: Any]] = []
        if let imageData {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": imageData.base64EncodedString()
                ]
            ])
        }
        content.append(["type": "text", "text": prompt])

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": content]],
        ]
        if let userContext = AIProviderSettings.currentUserContext {
            body["system"] = userContext
        }

        let headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]

        let data = try await makeRequest(url: url, headers: headers, body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let text = contentArray.first?["text"] as? String
        else { throw AnalysisError.invalidResponse }
        return text
    }

    // MARK: - Network

    private static func makeRequest(url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Retry transient overload responses (503/429/529) with exponential backoff: 1s, 2s, 4s.
        // The "model is currently experiencing high demand" message is Google's global throttle on
        // the Gemini model, not a per-key rate limit, so a quick retry usually succeeds.
        let retryDelaysNs: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]
        var lastError: AnalysisError = .apiError("Request failed")

        for attempt in 0...retryDelaysNs.count {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw AnalysisError.networkError(error)
            }

            guard let httpResponse = response as? HTTPURLResponse else { return data }

            if httpResponse.statusCode == 200 {
                return data
            }

            // Parse the API's error message once so we can surface the friendliest version.
            // Fall back to a status-code-only message when parsing finds nothing OR when the
            // parsed value is empty (some providers return `{"error": {"message": ""}}`,
            // which used to slip through as a literal blank "API error: " alert).
            let parsed = parseErrorMessage(from: data) ?? ""
            let parsedMessage = parsed.isEmpty ? "HTTP \(httpResponse.statusCode)" : parsed
            lastError = .apiError(friendlyMessage(for: httpResponse.statusCode, raw: parsedMessage))

            let isRetryable = httpResponse.statusCode == 503
                           || httpResponse.statusCode == 529
                           || httpResponse.statusCode == 429
            if isRetryable && attempt < retryDelaysNs.count {
                try? await Task.sleep(nanoseconds: retryDelaysNs[attempt])
                continue
            }
            throw lastError
        }
        throw lastError
    }

    private static func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = json["error"] as? String {
            return message
        }
        return nil
    }

    private static func friendlyMessage(for status: Int, raw: String) -> String {
        switch status {
        case 503, 529:
            return "The AI provider is overloaded right now. We retried a few times — please try again in a minute, or switch to a different provider/model in Settings → AI Provider."
        case 429:
            return "Rate limit hit on your API key. Wait a minute, or switch to another provider in Settings → AI Provider."
        case 401, 403:
            return "Your API key was rejected. Open Settings → AI Provider and re-paste a valid key."
        default:
            return raw
        }
    }

    // MARK: - Parsing (unchanged)

    private static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let openFence = cleaned.range(of: "```json", options: .caseInsensitive)
            ?? cleaned.range(of: "```") {
            cleaned = String(cleaned[openFence.upperBound...])
            if let closeFence = cleaned.range(of: "```", options: .backwards) {
                cleaned = String(cleaned[..<closeFence.lowerBound])
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstBrace = cleaned.firstIndex(of: "{") else { return cleaned }
        var depth = 0
        var inString = false
        var escape = false
        var endIndex: String.Index?
        for idx in cleaned[firstBrace...].indices {
            let ch = cleaned[idx]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = cleaned.index(after: idx)
                    break
                }
            }
        }
        if let end = endIndex {
            return String(cleaned[firstBrace..<end])
        }
        return cleaned
    }

    private static func parseFoodAnalysis(from text: String) throws -> FoodAnalysis {
        let jsonString = extractJSON(from: text)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String,
              let calories = (json["calories"] as? NSNumber)?.intValue,
              let protein = (json["protein"] as? NSNumber)?.intValue,
              let carbs = (json["carbs"] as? NSNumber)?.intValue,
              let fat = (json["fat"] as? NSNumber)?.intValue
        else { throw AnalysisError.invalidResponse }
        return FoodAnalysis(
            name: name, calories: calories, protein: protein, carbs: carbs, fat: fat,
            servingSizeGrams: (json["serving_size_grams"] as? NSNumber)?.doubleValue ?? 100,
            emoji: json["emoji"] as? String,
            sugar: (json["sugar"] as? NSNumber)?.doubleValue,
            addedSugar: (json["added_sugar"] as? NSNumber)?.doubleValue,
            fiber: (json["fiber"] as? NSNumber)?.doubleValue,
            saturatedFat: (json["saturated_fat"] as? NSNumber)?.doubleValue,
            monounsaturatedFat: (json["monounsaturated_fat"] as? NSNumber)?.doubleValue,
            polyunsaturatedFat: (json["polyunsaturated_fat"] as? NSNumber)?.doubleValue,
            cholesterol: (json["cholesterol"] as? NSNumber)?.doubleValue,
            sodium: (json["sodium"] as? NSNumber)?.doubleValue,
            potassium: (json["potassium"] as? NSNumber)?.doubleValue
        )
    }

    private static func parseNutritionLabel(from text: String) throws -> NutritionLabelAnalysis {
        let jsonString = extractJSON(from: text)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String,
              let caloriesPer100g = (json["calories_per_100g"] as? NSNumber)?.doubleValue,
              let proteinPer100g = (json["protein_per_100g"] as? NSNumber)?.doubleValue,
              let carbsPer100g = (json["carbs_per_100g"] as? NSNumber)?.doubleValue,
              let fatPer100g = (json["fat_per_100g"] as? NSNumber)?.doubleValue
        else { throw AnalysisError.invalidResponse }
        return NutritionLabelAnalysis(
            name: name, caloriesPer100g: caloriesPer100g, proteinPer100g: proteinPer100g,
            carbsPer100g: carbsPer100g, fatPer100g: fatPer100g,
            servingSizeGrams: (json["serving_size_grams"] as? NSNumber)?.doubleValue,
            sugarPer100g: (json["sugar_per_100g"] as? NSNumber)?.doubleValue,
            addedSugarPer100g: (json["added_sugar_per_100g"] as? NSNumber)?.doubleValue,
            fiberPer100g: (json["fiber_per_100g"] as? NSNumber)?.doubleValue,
            saturatedFatPer100g: (json["saturated_fat_per_100g"] as? NSNumber)?.doubleValue,
            monounsaturatedFatPer100g: (json["monounsaturated_fat_per_100g"] as? NSNumber)?.doubleValue,
            polyunsaturatedFatPer100g: (json["polyunsaturated_fat_per_100g"] as? NSNumber)?.doubleValue,
            cholesterolPer100g: (json["cholesterol_per_100g"] as? NSNumber)?.doubleValue,
            sodiumPer100g: (json["sodium_per_100g"] as? NSNumber)?.doubleValue,
            potassiumPer100g: (json["potassium_per_100g"] as? NSNumber)?.doubleValue
        )
    }
}
