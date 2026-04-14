//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    private static let modifierOnlyReleaseDebounceSeconds = 0.12
    private static let modifierOnlyReleasePollIntervalSeconds = 0.12

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var pendingReleaseWorkItem: DispatchWorkItem?
    private var modifierOnlyReleasePollTimer: Timer?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            nangyLog("could not create CGEvent tap", category: .voice, level: .warning)
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            nangyLog("could not create event tap run loop source", category: .voice, level: .warning)
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        nangyLog("global push-to-talk event tap started", category: .voice, level: .debug)
    }

    func stop() {
        pendingReleaseWorkItem?.cancel()
        pendingReleaseWorkItem = nil
        modifierOnlyReleasePollTimer?.invalidate()
        modifierOnlyReleasePollTimer = nil
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }

        nangyLog("global push-to-talk event tap stopped", category: .voice, level: .debug)
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            pendingReleaseWorkItem?.cancel()
            pendingReleaseWorkItem = nil
            isShortcutCurrentlyPressed = true
            startModifierOnlyReleasePollIfNeeded()
            nangyLog("shortcut transition=pressed", category: .voice, level: .debug)
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            if BuddyPushToTalkShortcut.currentShortcutOption.modifierOnlyFlags != nil {
                pendingReleaseWorkItem?.cancel()

                let releaseWorkItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingReleaseWorkItem = nil
                    guard self.isShortcutCurrentlyPressed else { return }
                    self.stopModifierOnlyReleasePoll()
                    self.isShortcutCurrentlyPressed = false
                    nangyLog("shortcut transition=released (debounced)", category: .voice, level: .debug)
                    self.shortcutTransitionPublisher.send(.released)
                }

                pendingReleaseWorkItem = releaseWorkItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.modifierOnlyReleaseDebounceSeconds,
                    execute: releaseWorkItem
                )
            } else {
                stopModifierOnlyReleasePoll()
                isShortcutCurrentlyPressed = false
                nangyLog("shortcut transition=released", category: .voice, level: .debug)
                shortcutTransitionPublisher.send(.released)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func startModifierOnlyReleasePollIfNeeded() {
        guard BuddyPushToTalkShortcut.currentShortcutOption.modifierOnlyFlags != nil else { return }
        guard modifierOnlyReleasePollTimer == nil else { return }

        modifierOnlyReleasePollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.modifierOnlyReleasePollIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.pollModifierOnlyShortcutState()
        }
    }

    private func stopModifierOnlyReleasePoll() {
        modifierOnlyReleasePollTimer?.invalidate()
        modifierOnlyReleasePollTimer = nil
    }

    private func pollModifierOnlyShortcutState() {
        guard let requiredModifierFlags = BuddyPushToTalkShortcut.currentShortcutOption.modifierOnlyFlags else {
            stopModifierOnlyReleasePoll()
            return
        }

        guard isShortcutCurrentlyPressed else {
            stopModifierOnlyReleasePoll()
            return
        }

        let currentModifierFlags = NSEvent.ModifierFlags(
            rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        )
        .intersection(.deviceIndependentFlagsMask)

        guard !currentModifierFlags.contains(requiredModifierFlags) else { return }

        pendingReleaseWorkItem?.cancel()
        pendingReleaseWorkItem = nil
        stopModifierOnlyReleasePoll()
        isShortcutCurrentlyPressed = false
        nangyLog("shortcut release synthesized from modifier poll", category: .voice, level: .warning)
        shortcutTransitionPublisher.send(.released)
    }
}
