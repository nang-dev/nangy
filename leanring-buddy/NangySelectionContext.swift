//
//  NangySelectionContext.swift
//  leanring-buddy
//
//  Selection metadata captured from the frontmost app so Nangy can rewrite
//  highlighted text in place.
//

import AppKit
import ApplicationServices

enum NangySelectionCaptureMethod {
    case accessibility
    case clipboard
}

struct NangySelectionContext {
    let focusedElement: AXUIElement?
    let selectedRangeValue: AXValue?
    let selectedText: String
    let appName: String
    let targetApplication: NSRunningApplication?
    let captureMethod: NangySelectionCaptureMethod
}

enum NangySelectionCaptureError: LocalizedError {
    case accessibilityPermissionDenied
    case noFocusedElement
    case noSelectedText
    case replacementFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility access is required so Nangy can read and replace selected text."
        case .noFocusedElement:
            return "No editable text field is focused right now."
        case .noSelectedText:
            return "Highlight some text first."
        case .replacementFailed:
            return "Nangy could not replace the selected text in that app."
        }
    }
}
