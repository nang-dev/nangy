//
//  NangyLogger.swift
//  leanring-buddy
//
//  Lightweight file-backed logger for app diagnostics. Writes to a stable
//  path under ~/Library/Logs/Nangy so failures can be reviewed after relaunch.
//

import Foundation

enum NangyLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

enum NangyLogCategory: String {
    case app
    case auth
    case assistant
    case codex
    case openai
    case permissions
    case transcription
    case tts
    case ui
    case voice
}

final class NangyLogger {
    nonisolated static let shared = NangyLogger()

    nonisolated static var logFileURL: URL {
        shared.currentLogFileURL
    }

    private let fileManager = FileManager.default
    private let writeQueue = DispatchQueue(label: "com.nang.nangy.logger", qos: .utility)
    private let currentLogFileURL: URL
    private let previousLogFileURL: URL
    private let sessionIdentifier = UUID().uuidString.prefix(8)
    private let maximumLogFileSizeInBytes = 1_000_000

    private init() {
        let logsDirectoryURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Nangy", isDirectory: true)

        currentLogFileURL = logsDirectoryURL.appendingPathComponent("nangy.log")
        previousLogFileURL = logsDirectoryURL.appendingPathComponent("nangy.previous.log")

        prepareLogDirectoryIfNeeded(at: logsDirectoryURL)
        rotateCurrentLogIfNeeded()

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        log(
            "session started id=\(sessionIdentifier) version=\(appVersion) build=\(buildNumber) pid=\(ProcessInfo.processInfo.processIdentifier)",
            category: .app,
            level: .info
        )
        log("log file path=\(currentLogFileURL.path)", category: .app, level: .debug)
    }

    nonisolated func log(
        _ message: String,
        category: NangyLogCategory = .app,
        level: NangyLogLevel = .info
    ) {
        let sanitizedMessage = Self.sanitize(message)
        guard !sanitizedMessage.isEmpty else { return }

        writeQueue.async { [currentLogFileURL] in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) [\(level.rawValue)] [\(category.rawValue)] \(sanitizedMessage)\n"
            self.appendLine(line, to: currentLogFileURL)
            fputs(line, stderr)
        }
    }

    nonisolated func log(
        error: Error,
        context: String,
        category: NangyLogCategory = .app
    ) {
        let details = Self.preview((error as NSError).userInfo.description, limit: 240)
        if details.isEmpty {
            log("\(context): \(error.localizedDescription)", category: category, level: .error)
        } else {
            log("\(context): \(error.localizedDescription) details=\(details)", category: category, level: .error)
        }
    }

    nonisolated static func preview(_ text: String?, limit: Int = 160) -> String {
        guard let text else { return "" }
        let flattenedText = sanitize(text)
        guard !flattenedText.isEmpty else { return "" }

        if flattenedText.count <= limit {
            return flattenedText
        }

        let endIndex = flattenedText.index(flattenedText.startIndex, offsetBy: limit)
        return "\(flattenedText[..<endIndex])…"
    }

    private func prepareLogDirectoryIfNeeded(at logsDirectoryURL: URL) {
        do {
            try fileManager.createDirectory(
                at: logsDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            if !fileManager.fileExists(atPath: currentLogFileURL.path) {
                fileManager.createFile(atPath: currentLogFileURL.path, contents: nil)
            }
        } catch {
            fputs("NangyLogger failed to prepare log directory: \(error)\n", stderr)
        }
    }

    private func rotateCurrentLogIfNeeded() {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: currentLogFileURL.path),
            let fileSize = attributes[.size] as? NSNumber,
            fileSize.intValue >= maximumLogFileSizeInBytes
        else {
            return
        }

        do {
            if fileManager.fileExists(atPath: previousLogFileURL.path) {
                try fileManager.removeItem(at: previousLogFileURL)
            }

            try fileManager.moveItem(at: currentLogFileURL, to: previousLogFileURL)
            fileManager.createFile(atPath: currentLogFileURL.path, contents: nil)
        } catch {
            fputs("NangyLogger failed to rotate log file: \(error)\n", stderr)
        }
    }

    private func appendLine(_ line: String, to fileURL: URL) {
        guard let data = line.data(using: .utf8) else { return }

        if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            do {
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
                try fileHandle.close()
            } catch {
                fputs("NangyLogger failed to append to log file: \(error)\n", stderr)
            }
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fputs("NangyLogger failed to create log file: \(error)\n", stderr)
        }
    }

    nonisolated private static func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@inline(__always)
nonisolated
func nangyLog(
    _ message: @autoclosure () -> String,
    category: NangyLogCategory = .app,
    level: NangyLogLevel = .info
) {
    NangyLogger.shared.log(message(), category: category, level: level)
}

@inline(__always)
nonisolated
func nangyLog(
    error: Error,
    context: String,
    category: NangyLogCategory = .app
) {
    NangyLogger.shared.log(error: error, context: context, category: category)
}
