//
//  OpenAIAPI.swift
//  OpenAI Responses API helper for Clicky
//

import Foundation

enum OpenAIAPIError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenAI API key in Settings before using API key mode."
        case .invalidResponse:
            return "OpenAI returned a response Clicky could not parse."
        case .apiError(let message):
            return message
        case .emptyOutput:
            return "OpenAI returned an empty result."
        }
    }
}

final class OpenAIAPI {
    private static let apiURL = URL(string: "https://api.openai.com/v1/responses")!

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    func transformText(
        prompt: String,
        systemPrompt: String,
        apiKey: String,
        model: String,
        reasoning: ClickyReasoningEffort,
        serviceTier: ClickyServiceTier
    ) async throws -> String {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw OpenAIAPIError.missingAPIKey
        }

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")

        var payload: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": prompt,
            "max_output_tokens": 2000,
            "service_tier": serviceTier.rawValue,
            "store": false
        ]
        payload["reasoning"] = ["effort": reasoning.rawValue]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        nangyLog(
            "text transform request model=\(model) reasoning=\(reasoning.rawValue) tier=\(serviceTier.rawValue) promptLength=\(prompt.count)",
            category: .openai
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            nangyLog("text transform returned invalid response object", category: .openai, level: .error)
            throw OpenAIAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = Self.extractErrorMessage(from: data) ?? "OpenAI request failed with status \(httpResponse.statusCode)."
            nangyLog(
                "text transform failed status=\(httpResponse.statusCode) message=\(NangyLogger.preview(message, limit: 220))",
                category: .openai,
                level: .error
            )
            throw OpenAIAPIError.apiError(message)
        }

        guard let text = Self.extractOutputText(from: data) else {
            nangyLog(
                "text transform could not parse output bodyPreview=\(NangyLogger.preview(String(data: data, encoding: .utf8), limit: 220))",
                category: .openai,
                level: .error
            )
            throw OpenAIAPIError.invalidResponse
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            nangyLog("text transform returned empty output", category: .openai, level: .error)
            throw OpenAIAPIError.emptyOutput
        }

        nangyLog("text transform completed outputLength=\(trimmedText.count)", category: .openai)
        return trimmedText
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)] = [],
        userPrompt: String,
        apiKey: String,
        model: String,
        reasoning: ClickyReasoningEffort,
        serviceTier: ClickyServiceTier
    ) async throws -> (text: String, duration: TimeInterval) {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw OpenAIAPIError.missingAPIKey
        }

        let startTime = Date()

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")

        var userContent: [[String: Any]] = []
        for image in images {
            let mimeType = detectImageMediaType(for: image.data)
            let dataURL = "data:\(mimeType);base64,\(image.data.base64EncodedString())"

            userContent.append([
                "type": "input_text",
                "text": image.label
            ])
            userContent.append([
                "type": "input_image",
                "image_url": dataURL
            ])
        }
        userContent.append([
            "type": "input_text",
            "text": buildConversationPrompt(
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        ])

        var payload: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": [[
                "role": "user",
                "content": userContent
            ]],
            "max_output_tokens": 700,
            "service_tier": serviceTier.rawValue,
            "store": false
        ]
        payload["reasoning"] = ["effort": reasoning.rawValue]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        if let bodyData = request.httpBody {
            let payloadMB = Double(bodyData.count) / 1_048_576.0
            nangyLog(
                "responses request model=\(model) reasoning=\(reasoning.rawValue) tier=\(serviceTier.rawValue) images=\(images.count) payloadMB=\(String(format: "%.1f", payloadMB)) historyCount=\(conversationHistory.count)",
                category: .openai
            )
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            nangyLog("responses request returned invalid response object", category: .openai, level: .error)
            throw OpenAIAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = Self.extractErrorMessage(from: data) ?? "OpenAI request failed with status \(httpResponse.statusCode)."
            nangyLog(
                "responses request failed status=\(httpResponse.statusCode) message=\(NangyLogger.preview(message, limit: 220))",
                category: .openai,
                level: .error
            )
            throw OpenAIAPIError.apiError(message)
        }

        guard let text = Self.extractOutputText(from: data) else {
            nangyLog(
                "responses request could not parse output bodyPreview=\(NangyLogger.preview(String(data: data, encoding: .utf8), limit: 220))",
                category: .openai,
                level: .error
            )
            throw OpenAIAPIError.invalidResponse
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            nangyLog("responses request returned empty output", category: .openai, level: .error)
            throw OpenAIAPIError.emptyOutput
        }

        let duration = Date().timeIntervalSince(startTime)
        nangyLog(
            "responses request completed status=\(httpResponse.statusCode) duration=\(String(format: "%.2f", duration))s outputLength=\(trimmedText.count)",
            category: .openai
        )
        return (trimmedText, duration)
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }

        return "image/jpeg"
    }

    private func buildConversationPrompt(
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        guard !conversationHistory.isEmpty else {
            return userPrompt
        }

        let formattedHistory = conversationHistory.map { exchange in
            """
            user: \(exchange.userTranscript)
            clicky: \(exchange.assistantResponse)
            """
        }
        .joined(separator: "\n\n")

        return """
        conversation so far:
        \(formattedHistory)

        current user request:
        \(userPrompt)
        """
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else {
            return nil
        }

        if let message = error["message"] as? String {
            return message
        }

        return nil
    }

    private static func extractOutputText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let outputText = object["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        guard let outputItems = object["output"] as? [[String: Any]] else {
            return nil
        }

        let fragments = outputItems.compactMap { outputItem -> String? in
            guard let contentItems = outputItem["content"] as? [[String: Any]] else {
                return nil
            }

            let texts = contentItems.compactMap { contentItem -> String? in
                if let text = contentItem["text"] as? String, !text.isEmpty {
                    return text
                }
                if let text = contentItem["output_text"] as? String, !text.isEmpty {
                    return text
                }
                return nil
            }

            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }

        let combinedText = fragments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return combinedText.isEmpty ? nil : combinedText
    }
}
