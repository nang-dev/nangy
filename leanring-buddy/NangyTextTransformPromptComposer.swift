//
//  NangyTextTransformPromptComposer.swift
//  leanring-buddy
//
//  Prompt builder and lightweight intent detector for in-place text rewrites.
//

import Foundation

enum NangyTextTransformPromptComposer {
    static let systemInstruction = """
    You are a macOS text insertion and replacement assistant. Return only the final text to insert or replace. Do not add commentary, quotes, code fences, labels, or explanations.
    Preserve the original meaning and formatting unless the user's instruction explicitly changes it.
    """

    private static let questionPrefixes = [
        "what",
        "why",
        "how",
        "where",
        "when",
        "who",
        "can you",
        "could you",
        "would you",
        "is this",
        "what does",
        "what is",
        "how do",
        "why is"
    ]

    private static let transformPrefixes = [
        "translate",
        "rewrite",
        "rephrase",
        "paraphrase",
        "shorten",
        "lengthen",
        "expand",
        "condense",
        "summarize",
        "polish",
        "improve",
        "fix",
        "correct",
        "make this",
        "make it",
        "turn this into",
        "turn it into",
        "convert this",
        "respond to this",
        "reply to this",
        "write a reply",
        "draft a reply"
    ]

    private static let transformContainsPhrases = [
        "like a native",
        "sound more",
        "more concise",
        "more formal",
        "more casual",
        "more professional",
        "fix the grammar",
        "fix grammar",
        "translate this",
        "rewrite this",
        "rephrase this"
    ]

    static func shouldRewriteSelectedText(
        instruction: String,
        selectedText: String
    ) -> Bool {
        let normalizedInstruction = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedInstruction.isEmpty else {
            return false
        }

        let trimmedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelection.isEmpty else {
            return false
        }

        return looksLikeTextTransformInstruction(normalizedInstruction)
    }

    static func looksLikeTextTransformInstruction(_ instruction: String) -> Bool {
        let normalizedInstruction = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedInstruction.isEmpty else {
            return false
        }

        if normalizedInstruction.hasSuffix("?") {
            return false
        }

        if questionPrefixes.contains(where: { normalizedInstruction.hasPrefix($0) }) {
            return false
        }

        if transformPrefixes.contains(where: { normalizedInstruction.hasPrefix($0) }) {
            return true
        }

        return transformContainsPhrases.contains(where: { normalizedInstruction.contains($0) })
    }

    static func compose(instruction: String, selectedText: String) -> String {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        User request:
        \(trimmedInstruction)

        Text to replace:
        \"\"\"
        \(selectedText)
        \"\"\"
        """
    }
}
