//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import Security
import Speech
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum ClickyAuthMode: String, CaseIterable, Codable, Identifiable {
    case chatGPTOAuth
    case apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPTOAuth:
            return "OAuth"
        case .apiKey:
            return "API Key"
        }
    }

    var subtitle: String {
        switch self {
        case .chatGPTOAuth:
            return "Use the ChatGPT/Codex sign-in already available on this Mac."
        case .apiKey:
            return "Use your OpenAI Platform API key stored in Keychain."
        }
    }
}

enum ClickyReasoningEffort: String, CaseIterable, Codable, Identifiable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "XHigh"
        }
    }
}

enum ClickyServiceTier: String, CaseIterable, Codable, Identifiable {
    case fast
    case flex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast:
            return "Fast"
        case .flex:
            return "Flex"
        }
    }
}

struct ClickyPreferences: Codable, Equatable {
    var authMode: ClickyAuthMode
    var model: String
    var reasoningEffort: ClickyReasoningEffort
    var serviceTier: ClickyServiceTier

    static let `default` = ClickyPreferences(
        authMode: .chatGPTOAuth,
        model: "gpt-5.4",
        reasoningEffort: .xhigh,
        serviceTier: .fast
    )
}

@MainActor
final class ClickySettingsStore: ObservableObject {
    @Published private(set) var preferences: ClickyPreferences

    private let defaults: UserDefaults
    private let storageKey = "Clicky.Preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(ClickyPreferences.self, from: data)
        {
            preferences = decoded
        } else {
            preferences = .default
        }
    }

    func update(_ mutate: (inout ClickyPreferences) -> Void) {
        var copy = preferences
        mutate(&copy)
        preferences = copy
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum ClickyAssistantError: LocalizedError {
    case settingsRequired

    var errorDescription: String? {
        switch self {
        case .settingsRequired:
            return "Connect OpenAI in Nangy Settings first."
        }
    }
}

enum ClickyKeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

final class ClickyKeychainStore {
    private let service = Bundle.main.bundleIdentifier ?? "com.clicky.app"

    func loadString(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveString(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw ClickyKeychainStoreError.unexpectedStatus(updateStatus)
        }

        var createQuery = baseQuery
        createQuery[kSecValueData as String] = data

        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw ClickyKeychainStoreError.unexpectedStatus(createStatus)
        }
    }

    func deleteValue(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClickyKeychainStoreError.unexpectedStatus(status)
        }
    }
}

enum CodexCLIError: LocalizedError {
    case commandUnavailable
    case notLoggedIn
    case commandFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            return "Codex CLI is not installed or is not available on PATH."
        case .notLoggedIn:
            return "Sign in with ChatGPT first before using OAuth mode."
        case .commandFailed(let message):
            return message
        case .emptyOutput:
            return "Codex returned an empty result."
        }
    }
}

struct CodexAuthStatus: Equatable {
    var isInstalled: Bool
    var isLoggedIn: Bool
    var authMode: String?
    var detail: String

    static let unknown = CodexAuthStatus(
        isInstalled: false,
        isLoggedIn: false,
        authMode: nil,
        detail: "Codex CLI status has not been checked yet."
    )
}

enum CodexLoginState: Equatable {
    case idle
    case checking
    case awaitingBrowser(url: URL, code: String)
    case waitingForCompletion(String)
    case completed(String)
    case failed(String)
}

@MainActor
final class ClickyCodexCLIService: ObservableObject {
    @Published private(set) var authStatus: CodexAuthStatus = .unknown
    @Published private(set) var loginState: CodexLoginState = .idle

    private static let deviceAuthLandingURL = URL(string: "https://auth.openai.com/codex/device")!

    private var loginProcess: Process?
    private var loginOutputBuffer = ""
    private var lastOpenedLoginURL: URL?

    func refreshStatus() async {
        nangyLog("refreshing Codex auth status", category: .codex, level: .debug)
        await refreshStatus(updateLoginState: true)
    }

    func startDeviceAuth() {
        nangyLog("starting Codex device auth flow", category: .codex)
        if case .awaitingBrowser(let url, _) = loginState {
            openBrowser(url)
            return
        }

        if loginProcess != nil {
            cancelActiveLoginAttempt()
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "login", "--device-auth"]
        process.standardOutput = stdout
        process.standardError = stderr

        loginProcess = process
        loginOutputBuffer = ""
        lastOpenedLoginURL = nil
        loginState = .waitingForCompletion("Launching ChatGPT sign-in…")
        openBrowser(Self.deviceAuthLandingURL)

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consumeLoginOutput(data)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consumeLoginOutput(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.loginProcess = nil

                if process.terminationStatus == 0 {
                    nangyLog("Codex device auth finished successfully", category: .codex)
                    self.loginState = .completed("ChatGPT sign-in finished.")
                    await self.refreshStatus(updateLoginState: false)
                } else {
                    let output = Self.sanitize(self.loginOutputBuffer)
                    nangyLog(
                        "Codex device auth failed status=\(process.terminationStatus) output=\(NangyLogger.preview(output, limit: 220))",
                        category: .codex,
                        level: .error
                    )
                    self.loginState = .failed(output.isEmpty ? "Codex login did not complete." : output)
                    await self.refreshStatus(updateLoginState: false)
                }
            }
        }

        do {
            try process.run()
        } catch {
            nangyLog(error: error, context: "failed to start Codex device auth", category: .codex)
            loginProcess = nil
            loginState = .failed(error.localizedDescription)
        }
    }

    func generateResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String,
        model: String,
        reasoning: ClickyReasoningEffort,
        serviceTier: ClickyServiceTier
    ) async throws -> String {
        guard authStatus.isInstalled else {
            throw CodexCLIError.commandUnavailable
        }

        if !authStatus.isLoggedIn {
            await refreshStatus(updateLoginState: false)
        }

        guard authStatus.isLoggedIn else {
            throw CodexCLIError.notLoggedIn
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let outputURL = temporaryDirectory.appendingPathComponent("response.txt")

        var arguments: [String] = [
            "codex",
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "-C", NSHomeDirectory(),
            "-m", model,
            "-c", "model_reasoning_effort=\"\(reasoning.rawValue)\"",
            "-c", "service_tier=\"\(serviceTier.rawValue)\"",
            "-o", outputURL.path
        ]

        for (index, image) in images.enumerated() {
            let fileExtension = image.data.isPNGData ? "png" : "jpg"
            let imageURL = temporaryDirectory.appendingPathComponent("clicky-screen-\(index).\(fileExtension)")
            try image.data.write(to: imageURL)
            arguments.append(contentsOf: ["-i", imageURL.path])
        }

        let prompt = buildPrompt(
            imageLabels: images.map(\.label),
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        arguments.append("--")
        arguments.append(prompt)

        nangyLog(
            "running Codex exec model=\(model) reasoning=\(reasoning.rawValue) tier=\(serviceTier.rawValue) images=\(images.count) historyCount=\(conversationHistory.count)",
            category: .codex
        )

        _ = try await runCommand(arguments)

        let text = try String(contentsOf: outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            nangyLog("Codex exec returned empty output file", category: .codex, level: .error)
            throw CodexCLIError.emptyOutput
        }

        nangyLog("Codex exec completed outputLength=\(text.count)", category: .codex)
        return text
    }

    func transformText(
        prompt: String,
        systemPrompt: String,
        model: String,
        reasoning: ClickyReasoningEffort,
        serviceTier: ClickyServiceTier
    ) async throws -> String {
        guard authStatus.isInstalled else {
            throw CodexCLIError.commandUnavailable
        }

        if !authStatus.isLoggedIn {
            await refreshStatus(updateLoginState: false)
        }

        guard authStatus.isLoggedIn else {
            throw CodexCLIError.notLoggedIn
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-codex-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let outputURL = temporaryDirectory.appendingPathComponent("response.txt")
        let fullPrompt = """
        \(systemPrompt)

        additional rules:
        - respond with only the final text to insert.
        - do not add surrounding quotes, markdown, labels, or commentary.

        \(prompt)
        """

        nangyLog(
            "running Codex text transform model=\(model) reasoning=\(reasoning.rawValue) tier=\(serviceTier.rawValue) promptLength=\(prompt.count)",
            category: .codex
        )

        _ = try await runCommand([
            "codex",
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "-C", NSHomeDirectory(),
            "-m", model,
            "-c", "model_reasoning_effort=\"\(reasoning.rawValue)\"",
            "-c", "service_tier=\"\(serviceTier.rawValue)\"",
            "-o", outputURL.path,
            "--",
            fullPrompt
        ])

        let text = try String(contentsOf: outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            nangyLog("Codex text transform returned empty output file", category: .codex, level: .error)
            throw CodexCLIError.emptyOutput
        }

        nangyLog("Codex text transform completed outputLength=\(text.count)", category: .codex)
        return text
    }

    private func buildPrompt(
        imageLabels: [String],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        let imageLabelSection: String
        if imageLabels.isEmpty {
            imageLabelSection = "no screenshots attached."
        } else {
            imageLabelSection = imageLabels.enumerated().map { index, label in
                "image \(index + 1): \(label)"
            }
            .joined(separator: "\n")
        }

        let conversationSection: String
        if conversationHistory.isEmpty {
            conversationSection = "no prior conversation."
        } else {
            conversationSection = conversationHistory.map { exchange in
                """
                user: \(exchange.userTranscript)
                clicky: \(exchange.assistantResponse)
                """
            }
            .joined(separator: "\n\n")
        }

        return """
        \(systemPrompt)

        additional rules:
        - respond directly in plain text.
        - do not use shell tools, web search, or inspect the filesystem.
        - use only the attached images and the conversation below.
        - attached screenshots are in this order:
        \(imageLabelSection)

        conversation so far:
        \(conversationSection)

        current user request:
        \(userPrompt)
        """
    }

    private func refreshStatus(updateLoginState: Bool) async {
        if updateLoginState {
            loginState = .checking
        }

        do {
            let result = try await runCommand(["codex", "login", "status"])
            let output = Self.sanitize(result.combinedOutput)
            let isLoggedIn = output.localizedCaseInsensitiveContains("logged in")
            let authMode = output.localizedCaseInsensitiveContains("chatgpt") ? "ChatGPT" : nil

            authStatus = CodexAuthStatus(
                isInstalled: true,
                isLoggedIn: isLoggedIn,
                authMode: authMode,
                detail: output.isEmpty ? "Codex CLI is available." : output
            )
            nangyLog(
                "Codex auth status installed=true loggedIn=\(isLoggedIn) authMode=\(authMode ?? "unknown") detail=\(NangyLogger.preview(output, limit: 180))",
                category: .codex
            )
            if updateLoginState {
                loginState = .idle
            }
        } catch CodexCLIError.commandUnavailable {
            authStatus = CodexAuthStatus(
                isInstalled: false,
                isLoggedIn: false,
                authMode: nil,
                detail: "Codex CLI was not found on this Mac."
            )
            nangyLog("Codex CLI not found on PATH", category: .codex, level: .error)
            if updateLoginState {
                loginState = .failed("Install Codex CLI first to use ChatGPT OAuth mode.")
            }
        } catch {
            authStatus = CodexAuthStatus(
                isInstalled: true,
                isLoggedIn: false,
                authMode: nil,
                detail: error.localizedDescription
            )
            nangyLog(error: error, context: "Codex auth refresh failed", category: .codex)
            if updateLoginState {
                loginState = .failed(error.localizedDescription)
            }
        }
    }

    private func consumeLoginOutput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        loginOutputBuffer += text

        let cleaned = Self.sanitize(loginOutputBuffer)
        if let url = extractFirstURL(from: cleaned), let code = extractDeviceCode(from: cleaned) {
            loginState = .awaitingBrowser(url: url, code: code)
            if lastOpenedLoginURL != url {
                openBrowser(url)
            }
            return
        }

        if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loginState = .waitingForCompletion(cleaned)
        }
    }

    private func cancelActiveLoginAttempt() {
        guard let loginProcess else { return }
        nangyLog("cancelling active Codex device auth attempt", category: .codex, level: .warning)

        if let stdout = loginProcess.standardOutput as? Pipe {
            stdout.fileHandleForReading.readabilityHandler = nil
        }

        if let stderr = loginProcess.standardError as? Pipe {
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        loginProcess.terminationHandler = nil
        if loginProcess.isRunning {
            loginProcess.terminate()
        }

        self.loginProcess = nil
        loginOutputBuffer = ""
        lastOpenedLoginURL = nil
        loginState = .idle
    }

    @discardableResult
    private func openBrowser(_ url: URL) -> Bool {
        if NSWorkspace.shared.open(url) {
            lastOpenedLoginURL = url
            nangyLog("opened browser for Codex auth url=\(url.absoluteString)", category: .codex, level: .debug)
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]

        do {
            try process.run()
            lastOpenedLoginURL = url
            nangyLog("opened browser via /usr/bin/open url=\(url.absoluteString)", category: .codex, level: .debug)
            return true
        } catch {
            nangyLog(error: error, context: "failed to open browser for Codex auth", category: .codex)
            return false
        }
    }

    private func runCommand(_ arguments: [String]) async throws -> CLICommandResult {
        nangyLog(
            "running command=\(NangyLogger.preview(arguments.joined(separator: " "), limit: 260))",
            category: .codex,
            level: .debug
        )
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = [output, errorOutput]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let sanitizedCombined = Self.sanitize(combined)

                if process.terminationStatus == 0 {
                    nangyLog(
                        "command finished status=0 output=\(NangyLogger.preview(sanitizedCombined, limit: 220))",
                        category: .codex,
                        level: .debug
                    )
                    continuation.resume(returning: CLICommandResult(
                        standardOutput: output,
                        standardError: errorOutput,
                        combinedOutput: combined
                    ))
                } else if process.terminationStatus == 127 || combined.localizedCaseInsensitiveContains("not found") {
                    nangyLog(
                        "command unavailable status=\(process.terminationStatus) output=\(NangyLogger.preview(sanitizedCombined, limit: 220))",
                        category: .codex,
                        level: .error
                    )
                    continuation.resume(throwing: CodexCLIError.commandUnavailable)
                } else {
                    nangyLog(
                        "command failed status=\(process.terminationStatus) output=\(NangyLogger.preview(sanitizedCombined, limit: 220))",
                        category: .codex,
                        level: .error
                    )
                    continuation.resume(throwing: CodexCLIError.commandFailed(sanitizedCombined))
                }
            }

            do {
                try process.run()
            } catch {
                nangyLog(error: error, context: "failed to launch command", category: .codex)
                continuation.resume(throwing: CodexCLIError.commandUnavailable)
            }
        }
    }

    nonisolated private static func sanitize(_ text: String) -> String {
        enum EscapeState {
            case none
            case escaped
            case controlSequence
            case operatingSystemCommand
            case operatingSystemCommandEscape
        }

        var scalars: [UnicodeScalar] = []
        var state: EscapeState = .none

        for scalar in text.unicodeScalars {
            switch state {
            case .none:
                if scalar == "\u{001B}" {
                    state = .escaped
                    continue
                }

                if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" {
                    continue
                }

                scalars.append(scalar)

            case .escaped:
                switch scalar {
                case "[":
                    state = .controlSequence
                case "]":
                    state = .operatingSystemCommand
                default:
                    state = .none
                }

            case .controlSequence:
                if (0x40...0x7E).contains(scalar.value) {
                    state = .none
                }

            case .operatingSystemCommand:
                if scalar == "\u{0007}" {
                    state = .none
                } else if scalar == "\u{001B}" {
                    state = .operatingSystemCommandEscape
                }

            case .operatingSystemCommandEscape:
                state = scalar == "\\" ? .none : .operatingSystemCommand
            }
        }

        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractFirstURL(from text: String) -> URL? {
        guard
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).first?.url
    }

    private func extractDeviceCode(from text: String) -> String? {
        let pattern = #"[A-Z0-9]{4,}-[A-Z0-9]{4,}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }
}

private struct CLICommandResult {
    let standardOutput: String
    let standardError: String
    let combinedOutput: String
}

private extension Data {
    var isPNGData: Bool {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        return count >= 4 && Array(prefix(4)) == pngSignature
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    static let shared = CompanionManager()

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var hasSpeechRecognitionPermission = true
    @Published private(set) var preferences: ClickyPreferences
    @Published private(set) var hasStoredAPIKey: Bool
    @Published private(set) var codexAuthStatus: CodexAuthStatus = .unknown
    @Published private(set) var codexLoginState: CodexLoginState = .idle

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the model response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"
    private let apiKeyAccount = "openai_api_key"
    private let settingsStore: ClickySettingsStore
    private let keychainStore: ClickyKeychainStore
    private let codexCLIService: ClickyCodexCLIService
    private let accessibilityTextService: NangyAccessibilityTextService
    private let openAIAPI: OpenAIAPI

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so the assistant remembers prior exchanges within a session.
    /// Each entry is the user's transcript and the assistant response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var settingsCancellable: AnyCancellable?
    private var codexAuthStatusCancellable: AnyCancellable?
    private var codexLoginStateCancellable: AnyCancellable?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var hasStarted = false

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
            && hasSpeechRecognitionPermission
    }

    /// The cursor overlay can be shown independently of voice/transcription setup.
    /// This keeps Nangy visible even while the user is still finishing permissions.
    private var shouldShowOverlayCursor: Bool {
        isClickyCursorEnabled
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    var selectedModel: String {
        preferences.model
    }

    func setSelectedModel(_ model: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        settingsStore.update { $0.model = trimmedModel }
    }

    var selectedReasoningEffort: ClickyReasoningEffort {
        preferences.reasoningEffort
    }

    func setSelectedReasoningEffort(_ reasoningEffort: ClickyReasoningEffort) {
        settingsStore.update { $0.reasoningEffort = reasoningEffort }
    }

    var selectedServiceTier: ClickyServiceTier {
        preferences.serviceTier
    }

    func setSelectedServiceTier(_ serviceTier: ClickyServiceTier) {
        settingsStore.update { $0.serviceTier = serviceTier }
    }

    var selectedAuthMode: ClickyAuthMode {
        preferences.authMode
    }

    func setSelectedAuthMode(_ authMode: ClickyAuthMode) {
        settingsStore.update { $0.authMode = authMode }
    }

    var isCurrentAuthReady: Bool {
        switch preferences.authMode {
        case .apiKey:
            return hasStoredAPIKey
        case .chatGPTOAuth:
            return codexAuthStatus.isLoggedIn
        }
    }

    var currentAssistantSummary: String {
        "\(preferences.model) · \(preferences.reasoningEffort.title) · \(preferences.serviceTier.title)"
    }

    var currentAuthSummary: String {
        switch preferences.authMode {
        case .apiKey:
            return hasStoredAPIKey ? "API key saved" : "API key needed"
        case .chatGPTOAuth:
            if !codexAuthStatus.isInstalled {
                return "Codex CLI needed"
            }
            return codexAuthStatus.isLoggedIn ? "OAuth connected" : "OAuth needed"
        }
    }

    init() {
        let settingsStore = ClickySettingsStore()
        let keychainStore = ClickyKeychainStore()
        let codexCLIService = ClickyCodexCLIService()
        let accessibilityTextService = NangyAccessibilityTextService()
        let openAIAPI = OpenAIAPI()

        self.settingsStore = settingsStore
        self.keychainStore = keychainStore
        self.codexCLIService = codexCLIService
        self.accessibilityTextService = accessibilityTextService
        self.openAIAPI = openAIAPI
        preferences = settingsStore.preferences
        hasStoredAPIKey = !(keychainStore.loadString(for: apiKeyAccount)?.isEmpty ?? true)

        settingsCancellable = settingsStore.$preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedPreferences in
                self?.preferences = updatedPreferences
            }

        codexAuthStatusCancellable = codexCLIService.$authStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.codexAuthStatus = status
            }

        codexLoginStateCancellable = codexCLIService.$loginState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loginState in
                self?.codexLoginState = loginState
            }

        nangyLog(
            "CompanionManager initialized authMode=\(preferences.authMode.rawValue) model=\(preferences.model) reasoning=\(preferences.reasoningEffort.rawValue) tier=\(preferences.serviceTier.rawValue) storedAPIKey=\(hasStoredAPIKey)",
            category: .assistant
        )
    }

    func openSettings() {
        nangyLog("opening settings window", category: .ui)
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        NangySettingsWindowController.shared.show(companionManager: self)
    }

    func refreshCodexAuthStatus() {
        Task {
            await codexCLIService.refreshStatus()
        }
    }

    func startCodexDeviceAuth() {
        nangyLog("user requested Codex OAuth sign-in", category: .auth)
        codexCLIService.startDeviceAuth()
    }

    func resetAssistantDefaults() {
        settingsStore.update { preferences in
            preferences = .default
        }
    }

    func saveAPIKey(_ value: String) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            try keychainStore.deleteValue(for: apiKeyAccount)
            nangyLog("deleted saved OpenAI API key", category: .auth)
        } else {
            try keychainStore.saveString(trimmedValue, for: apiKeyAccount)
            nangyLog("saved OpenAI API key to Keychain", category: .auth)
        }

        hasStoredAPIKey = !trimmedValue.isEmpty
    }

    func loadAPIKey() -> String? {
        keychainStore.loadString(for: apiKeyAccount)
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil
        nangyLog("cursor visibility preference updated enabled=\(enabled)", category: .ui)

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        completeOnboardingStateIfNeeded()
        refreshAllPermissions()
        refreshCodexAuthStatus()
        nangyLog(
            "start accessibility=\(hasAccessibilityPermission) screen=\(hasScreenRecordingPermission) mic=\(hasMicrophonePermission) speech=\(hasSpeechRecognitionPermission) screenContent=\(hasScreenContentPermission) onboarded=\(hasCompletedOnboarding)",
            category: .permissions
        )
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Treat onboarding as already complete and show the overlay as soon
        // as the app has everything it needs.
        if shouldShowOverlayCursor {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
            nangyLog("showing overlay on app start", category: .ui)
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        completeOnboardingStateIfNeeded()

        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        triggerOnboarding()
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        nangyLog("stopping companion manager", category: .app)
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadSpeechRecognition = hasSpeechRecognitionPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized
        hasSpeechRecognitionPermission = buddyDictationManager.hasSpeechRecognitionPermission

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadSpeechRecognition != hasSpeechRecognitionPermission {
            nangyLog(
                "permissions accessibility=\(hasAccessibilityPermission) screen=\(hasScreenRecordingPermission) mic=\(hasMicrophonePermission) speech=\(hasSpeechRecognitionPermission) screenContent=\(hasScreenContentPermission)",
                category: .permissions
            )
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        if !previouslyHadSpeechRecognition && hasSpeechRecognitionPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "speech_recognition")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                nangyLog(
                    "screen content capture width=\(image.width) height=\(image.height) didCapture=\(didCapture)",
                    category: .permissions
                )
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    if shouldShowOverlayCursor && !isOverlayVisible {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                        nangyLog("showing overlay after screen content grant", category: .ui)
                    }
                }
            } catch {
                nangyLog(error: error, context: "screen content permission request failed", category: .permissions)
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func completeOnboardingStateIfNeeded() {
        if !hasCompletedOnboarding {
            hasCompletedOnboarding = true
        }

        if showOnboardingPrompt || showOnboardingVideo || onboardingVideoPlayer != nil {
            stopOnboardingMusic()
            tearDownOnboardingVideo()
            showOnboardingPrompt = false
            onboardingPromptText = ""
            onboardingPromptOpacity = 0.0
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            nangyLog("received push-to-talk pressed transition", category: .voice, level: .debug)

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        nangyLog(
                            "received final transcript length=\(finalTranscript.count) preview=\(NangyLogger.preview(finalTranscript, limit: 140))",
                            category: .voice
                        )
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToAssistantWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            nangyLog("received push-to-talk released transition", category: .voice, level: .debug)
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to the
    /// configured OpenAI path and plays the response aloud via ElevenLabs TTS.
    /// The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// The model response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToAssistantWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        nangyLog(
            "starting assistant response pipeline authMode=\(preferences.authMode.rawValue) transcriptLength=\(transcript.count) preview=\(NangyLogger.preview(transcript, limit: 140))",
            category: .assistant
        )

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                if preferences.authMode == .chatGPTOAuth && !codexAuthStatus.isLoggedIn {
                    await codexCLIService.refreshStatus()
                }

                guard isCurrentAuthReady else {
                    nangyLog("assistant request blocked because auth is not ready", category: .assistant, level: .warning)
                    openSettings()
                    speakSettingsRequiredFallback()
                    return
                }

                if try await handleInlineTextTransformationIfPossible(for: transcript) {
                    nangyLog("handled transcript with inline text transformation", category: .assistant)
                    return
                }

                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                nangyLog("captured screens count=\(screenCaptures.count)", category: .assistant, level: .debug)

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so the model's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let fullResponseText = try await generateAssistantResponse(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: transcript
                )
                nangyLog(
                    "assistant response received length=\(fullResponseText.count) preview=\(NangyLogger.preview(fullResponseText, limit: 180))",
                    category: .assistant
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from the model response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if the model returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching the model's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // The model coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    nangyLog(
                        "element pointing x=\(Int(pointCoordinate.x)) y=\(Int(pointCoordinate.y)) label=\(parseResult.elementLabel ?? "element")",
                        category: .assistant
                    )
                } else {
                    nangyLog(
                        "element pointing skipped label=\(parseResult.elementLabel ?? "none")",
                        category: .assistant,
                        level: .debug
                    )
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                nangyLog("conversation history count=\(conversationHistory.count)", category: .assistant, level: .debug)

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        nangyLog(error: error, context: "TTS playback failed", category: .tts)
                        speakLocally(spokenText)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                nangyLog("assistant response pipeline cancelled", category: .assistant, level: .debug)
            } catch ClickyAssistantError.settingsRequired {
                nangyLog("assistant response requires settings before continuing", category: .assistant, level: .warning)
                openSettings()
                speakSettingsRequiredFallback()
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                nangyLog(error: error, context: "assistant response pipeline failed", category: .assistant)
                speakResponseErrorFallback(for: error)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func generateAssistantResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        let currentPreferences = preferences
        nangyLog(
            "routing assistant response authMode=\(currentPreferences.authMode.rawValue) model=\(currentPreferences.model) reasoning=\(currentPreferences.reasoningEffort.rawValue) tier=\(currentPreferences.serviceTier.rawValue)",
            category: .assistant
        )

        switch currentPreferences.authMode {
        case .apiKey:
            guard let apiKey = loadAPIKey(), !apiKey.isEmpty else {
                nangyLog("API key mode selected but no API key is saved", category: .assistant, level: .warning)
                throw ClickyAssistantError.settingsRequired
            }

            let (responseText, _) = try await openAIAPI.analyzeImage(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                apiKey: apiKey,
                model: currentPreferences.model,
                reasoning: currentPreferences.reasoningEffort,
                serviceTier: currentPreferences.serviceTier
            )
            nangyLog("assistant routed through direct OpenAI API", category: .assistant, level: .debug)
            return responseText

        case .chatGPTOAuth:
            if !codexAuthStatus.isLoggedIn {
                await codexCLIService.refreshStatus()
            }

            guard codexAuthStatus.isLoggedIn else {
                nangyLog("OAuth mode selected but Codex is not logged in", category: .assistant, level: .warning)
                throw ClickyAssistantError.settingsRequired
            }

            nangyLog("assistant routed through Codex CLI OAuth", category: .assistant, level: .debug)
            return try await codexCLIService.generateResponse(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                model: currentPreferences.model,
                reasoning: currentPreferences.reasoningEffort,
                serviceTier: currentPreferences.serviceTier
            )
        }
    }

    private func handleInlineTextTransformationIfPossible(for instruction: String) async throws -> Bool {
        guard NangyTextTransformPromptComposer.looksLikeTextTransformInstruction(instruction) else {
            return false
        }

        guard hasAccessibilityPermission && accessibilityTextService.hasPermission() else {
            nangyLog(
                "skipping inline text transformation because accessibility is unavailable",
                category: .assistant,
                level: .debug
            )
            return false
        }

        let selectionContext: NangySelectionContext
        do {
            selectionContext = try await accessibilityTextService.captureCurrentSelection()
        } catch NangySelectionCaptureError.noFocusedElement, NangySelectionCaptureError.noSelectedText {
            nangyLog("no highlighted text found for inline transformation", category: .assistant, level: .debug)
            return false
        } catch NangySelectionCaptureError.accessibilityPermissionDenied {
            nangyLog(
                "inline transformation blocked because accessibility permission is denied",
                category: .assistant,
                level: .warning
            )
            return false
        } catch {
            nangyLog(error: error, context: "failed to capture selected text", category: .assistant)
            return false
        }

        guard NangyTextTransformPromptComposer.shouldRewriteSelectedText(
            instruction: instruction,
            selectedText: selectionContext.selectedText
        ) else {
            return false
        }

        let prompt = NangyTextTransformPromptComposer.compose(
            instruction: instruction,
            selectedText: selectionContext.selectedText
        )
        nangyLog(
            "running inline transformation app=\(selectionContext.appName) captureMethod=\(String(describing: selectionContext.captureMethod)) selectedLength=\(selectionContext.selectedText.count)",
            category: .assistant
        )

        let replacementText = try await generateInlineTextTransformation(prompt: prompt)
        guard !Task.isCancelled else { return true }

        try await accessibilityTextService.replaceSelection(
            in: selectionContext,
            with: replacementText
        )

        nangyLog(
            "inline transformation replaced selection app=\(selectionContext.appName) replacementLength=\(replacementText.count)",
            category: .assistant
        )
        return true
    }

    private func generateInlineTextTransformation(prompt: String) async throws -> String {
        let currentPreferences = preferences
        nangyLog(
            "routing inline text transformation authMode=\(currentPreferences.authMode.rawValue) model=\(currentPreferences.model) reasoning=\(currentPreferences.reasoningEffort.rawValue) tier=\(currentPreferences.serviceTier.rawValue)",
            category: .assistant
        )

        switch currentPreferences.authMode {
        case .apiKey:
            guard let apiKey = loadAPIKey(), !apiKey.isEmpty else {
                throw ClickyAssistantError.settingsRequired
            }

            return try await openAIAPI.transformText(
                prompt: prompt,
                systemPrompt: NangyTextTransformPromptComposer.systemInstruction,
                apiKey: apiKey,
                model: currentPreferences.model,
                reasoning: currentPreferences.reasoningEffort,
                serviceTier: currentPreferences.serviceTier
            )

        case .chatGPTOAuth:
            if !codexAuthStatus.isLoggedIn {
                await codexCLIService.refreshStatus()
            }

            guard codexAuthStatus.isLoggedIn else {
                throw ClickyAssistantError.settingsRequired
            }

            return try await codexCLIService.transformText(
                prompt: prompt,
                systemPrompt: NangyTextTransformPromptComposer.systemInstruction,
                model: currentPreferences.model,
                reasoning: currentPreferences.reasoningEffort,
                serviceTier: currentPreferences.serviceTier
            )
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    private func speakLocally(_ utterance: String) {
        elevenLabsTTSClient.speakLocally(utterance)
        voiceState = .responding
        nangyLog(
            "using local speech fallback utteranceLength=\(utterance.count) preview=\(NangyLogger.preview(utterance, limit: 160))",
            category: .tts,
            level: .warning
        )
    }

    private func speakResponseErrorFallback(for error: Error) {
        let message = (error as? LocalizedError)?.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let utterance: String

        if let message, !message.isEmpty {
            utterance = "I hit an OpenAI error. \(message)"
        } else {
            utterance = "I hit an OpenAI error. Check your sign in, network, or model settings and try again."
        }

        nangyLog(
            "speaking response error fallback preview=\(NangyLogger.preview(utterance, limit: 180))",
            category: .tts,
            level: .warning
        )
        speakLocally(utterance)
    }

    private func speakSettingsRequiredFallback() {
        nangyLog("speaking settings required fallback", category: .tts, level: .warning)
        speakLocally("Open Nangy settings and connect OpenAI first.")
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from the model's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if the model said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of the model response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks the configured model to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                if preferences.authMode == .chatGPTOAuth && !codexAuthStatus.isLoggedIn {
                    await codexCLIService.refreshStatus()
                }

                guard isCurrentAuthReady else { return }

                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so the model can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let fullResponseText = try await generateAssistantResponse(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    conversationHistory: [],
                    userPrompt: "look around my screen and find something interesting to point at",
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses the
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
