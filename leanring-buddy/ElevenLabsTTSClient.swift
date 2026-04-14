//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Uses the streaming endpoint so
//  playback begins before the full audio has been generated.
//

import AVFoundation
import AppKit
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL?
    private let session: URLSession
    private var systemSynthesizer: NSSpeechSynthesizer?

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    init(proxyURL: String) {
        if proxyURL.contains("your-worker-name.your-subdomain.workers.dev") {
            self.proxyURL = nil
        } else {
            self.proxyURL = URL(string: proxyURL)
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        if self.proxyURL == nil {
            nangyLog("ElevenLabs proxy not configured, local speech fallback enabled", category: .tts, level: .warning)
        } else {
            nangyLog("ElevenLabs proxy configured", category: .tts, level: .debug)
        }
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        guard let proxyURL else {
            speakLocally(text)
            return
        }

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            nangyLog(
                "ElevenLabs proxy request failed status=\(httpResponse.statusCode) bodyPreview=\(NangyLogger.preview(errorBody, limit: 180))",
                category: .tts,
                level: .error
            )
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        nangyLog("playing ElevenLabs audio kb=\(data.count / 1024)", category: .tts)
    }

    func speakLocally(_ text: String) {
        let synthesizer = NSSpeechSynthesizer()
        systemSynthesizer = synthesizer
        synthesizer.startSpeaking(text)
        nangyLog(
            "using macOS speech synthesizer fallback textLength=\(text.count)",
            category: .tts,
            level: .warning
        )
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false) || (systemSynthesizer?.isSpeaking ?? false)
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        if isPlaying {
            nangyLog("stopping TTS playback", category: .tts, level: .debug)
        }
        audioPlayer?.stop()
        audioPlayer = nil
        systemSynthesizer?.stopSpeaking()
        systemSynthesizer = nil
    }
}
