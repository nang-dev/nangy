//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import Sparkle
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ClickySettingsView(companionManager: CompanionManager.shared)
        }
    }
}

@MainActor
final class NangySettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = NangySettingsWindowController()

    private var window: NSWindow?

    func show(companionManager: CompanionManager) {
        if window == nil {
            let hostingController = NSHostingController(
                rootView: ClickySettingsView(companionManager: companionManager)
            )

            let settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow.title = "Nangy Settings"
            settingsWindow.setContentSize(NSSize(width: 720, height: 620))
            settingsWindow.minSize = NSSize(width: 680, height: 560)
            settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            settingsWindow.titleVisibility = .visible
            settingsWindow.titlebarAppearsTransparent = false
            settingsWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.delegate = self
            settingsWindow.center()
            settingsWindow.setFrameAutosaveName("NangySettingsWindow")
            window = settingsWindow
        } else if let hostingController = window?.contentViewController as? NSHostingController<ClickySettingsView> {
            hostingController.rootView = ClickySettingsView(companionManager: companionManager)
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager.shared
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        nangyLog("application did finish launching", category: .app)
        nangyLog(
            "version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")",
            category: .app,
            level: .debug
        )
        nangyLog("diagnostic log path=\(NangyLogger.logFileURL.path)", category: .app, level: .debug)

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()

        // Auto-open the panel if setup is still incomplete.
        if !companionManager.allPermissionsGranted || !companionManager.isCurrentAuthReady {
            menuBarPanelManager?.showPanelOnLaunch()
        }

        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                nangyLog("registered as login item", category: .app)
            } catch {
                nangyLog(error: error, context: "failed to register as login item", category: .app)
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            nangyLog(error: error, context: "Sparkle updater failed to start", category: .app)
        }
    }
}

struct ClickySettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var apiKeyInput = ""
    @State private var saveStatusMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard
                authenticationCard
                modelCard
                statusCard
            }
            .padding(24)
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onAppear {
            apiKeyInput = companionManager.loadAPIKey() ?? ""
            companionManager.refreshCodexAuthStatus()
        }
    }

    private var heroCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nangy")
                    .font(.system(size: 30, weight: .semibold))

                Text("OpenAI-powered screen companion settings. Default profile is GPT-5.4 with XHigh reasoning on the Fast tier.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    statusPill(title: "Auth ready", active: companionManager.isCurrentAuthReady)
                    statusPill(title: "Permissions", active: companionManager.allPermissionsGranted)
                    statusPill(title: "Model", active: true)
                }
            }
        }
    }

    private var authenticationCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(
                    title: "Authentication",
                    subtitle: "Choose between ChatGPT OAuth through Codex CLI or a direct OpenAI API key."
                )

                Picker("Auth Mode", selection: authModeBinding) {
                    ForEach(ClickyAuthMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(companionManager.selectedAuthMode.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if companionManager.selectedAuthMode == .apiKey {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("API Key")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        SecureField("sk-...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 12) {
                            Button("Save Key") {
                                do {
                                    try companionManager.saveAPIKey(apiKeyInput)
                                    saveStatusMessage = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "API key removed."
                                        : "API key saved to your Keychain."
                                } catch {
                                    saveStatusMessage = error.localizedDescription
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            if !saveStatusMessage.isEmpty {
                                Text(saveStatusMessage)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    oauthStatusView
                }
            }
        }
    }

    private var oauthStatusView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(companionManager.codexAuthStatus.isLoggedIn ? "Codex CLI connected" : "Codex CLI not connected")
                        .font(.system(size: 14, weight: .semibold))

                    Text(companionManager.codexAuthStatus.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Refresh Status") {
                        companionManager.refreshCodexAuthStatus()
                    }
                    .buttonStyle(.bordered)

                    Button(companionManager.codexAuthStatus.isLoggedIn ? "Re-authenticate" : "Sign In with ChatGPT") {
                        companionManager.startCodexDeviceAuth()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            switch companionManager.codexLoginState {
            case .idle:
                EmptyView()
            case .checking:
                Text("Checking Codex auth status…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .awaitingBrowser(_, let code):
                Text("Browser sign-in started. If prompted, confirm code \(code).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .waitingForCompletion(let detail), .completed(let detail), .failed(let detail):
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(
                    title: "Model Defaults",
                    subtitle: "These settings drive both API key mode and OAuth mode."
                )

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        TextField("gpt-5.4", text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Reasoning")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Picker("Reasoning", selection: reasoningBinding) {
                                ForEach(ClickyReasoningEffort.allCases) { effort in
                                    Text(effort.title).tag(effort)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Speed Tier")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Picker("Speed Tier", selection: serviceTierBinding) {
                                ForEach(ClickyServiceTier.allCases) { tier in
                                    Text(tier.title).tag(tier)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                HStack {
                    Text("Current default: \(companionManager.currentAssistantSummary)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reset Defaults") {
                        companionManager.resetAssistantDefaults()
                        apiKeyInput = companionManager.loadAPIKey() ?? ""
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var statusCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    title: "Runtime Status",
                    subtitle: "Quick readout of the active assistant profile inside Nangy."
                )

                labeledValue(title: "Authentication", value: companionManager.currentAuthSummary)
                labeledValue(title: "Model", value: companionManager.selectedModel)
                labeledValue(title: "Reasoning", value: companionManager.selectedReasoningEffort.title)
                labeledValue(title: "Tier", value: companionManager.selectedServiceTier.title)
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    )
            )
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func statusPill(title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(active ? DS.Colors.accent.opacity(0.16) : Color.black.opacity(0.06))
            )
            .foregroundStyle(active ? DS.Colors.accent : Color.secondary)
    }

    private func labeledValue(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.system(size: 13))
        }
    }

    private var authModeBinding: Binding<ClickyAuthMode> {
        Binding(
            get: { companionManager.selectedAuthMode },
            set: { companionManager.setSelectedAuthMode($0) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { companionManager.selectedModel },
            set: { companionManager.setSelectedModel($0) }
        )
    }

    private var reasoningBinding: Binding<ClickyReasoningEffort> {
        Binding(
            get: { companionManager.selectedReasoningEffort },
            set: { companionManager.setSelectedReasoningEffort($0) }
        )
    }

    private var serviceTierBinding: Binding<ClickyServiceTier> {
        Binding(
            get: { companionManager.selectedServiceTier },
            set: { companionManager.setSelectedServiceTier($0) }
        )
    }
}
