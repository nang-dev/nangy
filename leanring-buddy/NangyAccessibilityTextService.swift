//
//  NangyAccessibilityTextService.swift
//  leanring-buddy
//
//  Reads selected text from the frontmost app and replaces it after an AI
//  transformation, matching the ai-on-mac rewrite flow.
//

import AppKit
import ApplicationServices
import Carbon

@MainActor
final class NangyAccessibilityTextService {
    func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func captureCurrentSelection() async throws -> NangySelectionContext {
        guard hasPermission() else {
            throw NangySelectionCaptureError.accessibilityPermissionDenied
        }

        let targetApplication = NSWorkspace.shared.frontmostApplication
        let appName = targetApplication?.localizedName ?? "Current App"
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        let focusedElement: AXUIElement?
        if focusedStatus == .success, let focusedValue {
            focusedElement = (focusedValue as! AXUIElement)
        } else {
            focusedElement = nil
        }

        if let focusedElement, let selectionContext = captureSelectionViaAccessibility(
            from: focusedElement,
            appName: appName,
            targetApplication: targetApplication
        ) {
            return selectionContext
        }

        if let selectionContext = await captureSelectionViaCopy(
            focusedElement: focusedElement,
            appName: appName,
            targetApplication: targetApplication
        ) {
            return selectionContext
        }

        if focusedElement == nil {
            throw NangySelectionCaptureError.noFocusedElement
        }

        throw NangySelectionCaptureError.noSelectedText
    }

    func replaceSelection(in context: NangySelectionContext, with replacement: String) async throws {
        if try directReplacement(in: context, with: replacement) {
            return
        }

        try await pasteReplacement(in: context, with: replacement)
    }

    private func captureSelectionViaAccessibility(
        from element: AXUIElement,
        appName: String,
        targetApplication: NSRunningApplication?
    ) -> NangySelectionContext? {
        var selectedTextValue: CFTypeRef?
        let textStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )
        guard textStatus == .success, let selectedText = selectedTextValue as? String else {
            return nil
        }

        let trimmedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelection.isEmpty else {
            return nil
        }

        var rangeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )

        let selectedRangeValue: AXValue?
        if let rangeValue {
            selectedRangeValue = (rangeValue as! AXValue)
        } else {
            selectedRangeValue = nil
        }

        return NangySelectionContext(
            focusedElement: element,
            selectedRangeValue: selectedRangeValue,
            selectedText: selectedText,
            appName: appName,
            targetApplication: targetApplication,
            captureMethod: .accessibility
        )
    }

    private func captureSelectionViaCopy(
        focusedElement: AXUIElement?,
        appName: String,
        targetApplication: NSRunningApplication?
    ) async -> NangySelectionContext? {
        let pasteboard = NSPasteboard.general
        let snapshot = NangyPasteboardSnapshot.capture(from: pasteboard)
        let originalChangeCount = pasteboard.changeCount

        postKeyboardShortcut(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(140))

        let copiedText = pasteboard.string(forType: .string)
        let didChange = pasteboard.changeCount != originalChangeCount
        snapshot.restore(to: pasteboard)

        guard didChange, let copiedText else {
            return nil
        }

        let trimmedSelection = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelection.isEmpty else {
            return nil
        }

        var rangeValue: CFTypeRef?
        if let focusedElement {
            AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                &rangeValue
            )
        }

        let selectedRangeValue: AXValue?
        if let rangeValue {
            selectedRangeValue = (rangeValue as! AXValue)
        } else {
            selectedRangeValue = nil
        }

        return NangySelectionContext(
            focusedElement: focusedElement,
            selectedRangeValue: selectedRangeValue,
            selectedText: copiedText,
            appName: appName,
            targetApplication: targetApplication,
            captureMethod: .clipboard
        )
    }

    private func directReplacement(in context: NangySelectionContext, with replacement: String) throws -> Bool {
        guard let focusedElement = context.focusedElement else {
            return false
        }

        var selectedTextSettable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        )

        if settableStatus == .success, selectedTextSettable.boolValue {
            let status = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextAttribute as CFString,
                replacement as CFTypeRef
            )
            if status == .success {
                return true
            }
        }

        guard
            let rangeValue = context.selectedRangeValue,
            let currentValue = valueString(for: focusedElement),
            let updatedValue = replacingRange(
                in: currentValue,
                rangeValue: rangeValue,
                replacement: replacement
            )
        else {
            return false
        }

        let status = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )

        return status == .success
    }

    private func pasteReplacement(in context: NangySelectionContext, with replacement: String) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = NangyPasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)

        context.targetApplication?.activate(options: [])
        try? await Task.sleep(for: .milliseconds(120))

        postKeyboardShortcut(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(260))

        snapshot.restore(to: pasteboard)
    }

    private func valueString(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard status == .success else {
            return nil
        }

        return value as? String
    }

    private func replacingRange(
        in currentValue: String,
        rangeValue: AXValue,
        replacement: String
    ) -> String? {
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else {
            return nil
        }

        let nsRange = NSRange(location: range.location, length: range.length)
        guard let swiftRange = Range(nsRange, in: currentValue) else {
            return nil
        }

        var updatedValue = currentValue
        updatedValue.replaceSubrange(swiftRange, with: replacement)
        return updatedValue
    }

    private func postKeyboardShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true)
        keyDownEvent?.flags = flags
        keyDownEvent?.post(tap: .cghidEventTap)

        let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        keyUpEvent?.flags = flags
        keyUpEvent?.post(tap: .cghidEventTap)
    }
}

private struct NangyPasteboardSnapshot {
    struct CapturedItem {
        let representations: [NSPasteboard.PasteboardType: Data]
    }

    let items: [CapturedItem]

    static func capture(from pasteboard: NSPasteboard) -> NangyPasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            let representations: [NSPasteboard.PasteboardType: Data] = Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                guard let data = item.data(forType: type) else {
                    return nil
                }

                return (type, data)
            })

            return CapturedItem(representations: representations)
        }

        return NangyPasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else {
            return
        }

        let rebuiltItems = items.map { capturedItem in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in capturedItem.representations {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }

        pasteboard.writeObjects(rebuiltItems)
    }
}
