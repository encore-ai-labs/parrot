import AppKit
import ApplicationServices
import Foundation

/// The only surrounding text smart cursor insertion is allowed to inspect.
/// Values are bounded before they cross back from another process.
struct CursorTextBoundary: Equatable, Sendable {
    let before: String
    /// Empty means the cursor is at the end. Nil means the target could not
    /// report a reliable following boundary, so legacy trailing-space behavior
    /// remains authoritative.
    let after: String?
}

struct CursorInsertionSnapshot: Equatable, Sendable {
    let processID: pid_t
    let boundary: CursorTextBoundary
}

/// Reads a tiny text window around the cursor through Accessibility. Capture
/// begins only after recording stops and runs outside the main actor with a
/// short cross-process timeout. Secure fields and unsupported applications
/// return nil, preserving the established insertion behavior.
enum CursorInsertionContextCapture {
    static let maximumCharactersBeforeCursor = 64
    static let maximumCharactersAfterCursor = 8
    static let messagingTimeout: Float = 0.05

    @MainActor
    static func start() -> Task<CursorInsertionSnapshot?, Never>? {
        guard AXIsProcessTrusted(),
              let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        return Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let boundary = readBoundary(processID: processID),
                  !Task.isCancelled
            else { return nil }
            return CursorInsertionSnapshot(processID: processID, boundary: boundary)
        }
    }

    @MainActor
    static func boundaryForCurrentApplication(
        _ snapshot: CursorInsertionSnapshot?
    ) -> CursorTextBoundary? {
        guard let snapshot,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.processID
        else { return nil }
        return snapshot.boundary
    }

    nonisolated static func readBoundary(processID: pid_t?) -> CursorTextBoundary? {
        guard let processID else { return nil }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }

        let focusedElement = focusedValue as! AXUIElement
        if isSecureSubrole(stringAttribute(kAXSubroleAttribute, from: focusedElement)) {
            return nil
        }

        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
        let selectedRangeValue,
        CFGetTypeID(selectedRangeValue) == AXValueGetTypeID()
        else { return nil }

        let rangeValue = selectedRangeValue as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange),
              selectedRange.location != kCFNotFound,
              selectedRange.location >= 0,
              selectedRange.length >= 0
        else { return nil }

        let beforeLength = min(selectedRange.location, maximumCharactersBeforeCursor)
        let beforeRange = CFRange(
            location: selectedRange.location - beforeLength,
            length: beforeLength
        )
        guard let before = string(in: beforeRange, from: focusedElement) else { return nil }

        let (selectionEnd, overflowed) = selectedRange.location.addingReportingOverflow(
            selectedRange.length
        )
        guard !overflowed else { return nil }
        let characterCount = numberAttribute(
            kAXNumberOfCharactersAttribute,
            from: focusedElement
        )
        let after: String?
        if let characterCount,
           characterCount >= 0,
           selectionEnd <= characterCount {
            let afterLength = min(
                characterCount - selectionEnd,
                maximumCharactersAfterCursor
            )
            after = string(
                in: CFRange(location: selectionEnd, length: afterLength),
                from: focusedElement
            )
        } else {
            after = nil
        }

        return CursorTextBoundary(before: before, after: after)
    }

    nonisolated static func isSecureSubrole(_ subrole: String?) -> Bool {
        subrole == (kAXSecureTextFieldSubrole as String)
    }

    private nonisolated static func string(
        in range: CFRange,
        from element: AXUIElement
    ) -> String? {
        if range.length == 0 { return "" }
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success
        else { return nil }
        return value as? String
    }

    private nonisolated static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success
        else { return nil }
        return value as? String
    }

    private nonisolated static func numberAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber
        else { return nil }
        return number.intValue
    }
}

/// Pure, conservative boundary formatting for text that is about to be
/// inserted at a cursor. It never touches persisted transcript output.
enum CursorInsertionFormatter {
    /// Only unambiguous English sentence starters are eligible for a leading
    /// case change. Proper nouns and all-caps words remain untouched.
    private static let lowercasableStarters: Set<String> = [
        "A", "An", "And", "Are", "As", "At", "Be", "Because", "But", "By",
        "Can", "Could", "Do", "Does", "For", "From", "Had", "Has", "Have",
        "Here", "How", "If", "In", "Is", "It", "Its", "My", "Next", "No",
        "Not", "Now", "Of", "On", "Or", "Our", "Please", "Should", "So",
        "That", "The", "Their", "Them", "Then", "There",
        "These", "They", "This", "Those", "To", "Today", "Tomorrow", "Was", "We",
        "Were", "What", "When", "Where", "Which", "While", "Who", "Why", "With",
        "Would", "Yes", "You", "Your",
    ]
    private static let sentenceEnders: Set<Character> = [".", "?", "!", "…"]
    private static let openingBoundaries: Set<Character> = [
        "(", "[", "{", "/", "<", "@", "#", "“", "‘", "\"", "—", "–", "-",
    ]
    private static let closingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "%", ")", "]", "}", ">", "»", "”", "’",
    ]
    private static let sentenceClosingWrappers: Set<Character> = [
        ")", "]", "}", "»", "”", "’", "\"", "'",
    ]

    static func prepare(
        _ text: String,
        appendSpace: Bool,
        boundary: CursorTextBoundary
    ) -> String {
        guard !text.isEmpty else { return text }
        if hasStructuralFormatting(text) {
            guard appendSpace, text.last?.isWhitespace != true else { return text }
            return text + " "
        }
        var output = isMidSentence(boundary.before)
            ? lowercasingSafeStarter(in: text)
            : text

        if needsLeadingSpace(output, after: boundary.before) {
            output.insert(" ", at: output.startIndex)
        }
        if appendSpace, needsTrailingSpace(output, before: boundary.after) {
            output.append(" ")
        }
        return output
    }

    private static func hasStructuralFormatting(_ text: String) -> Bool {
        if text.contains("\n") || text.contains("\r") { return true }
        guard let first = text.first else { return false }
        if ["#", ">", "`"].contains(first) { return true }
        if ["-", "*", "+"].contains(first), text.dropFirst().first?.isWhitespace == true {
            return true
        }
        let leadingDigits = text.prefix(while: { $0.isNumber })
        guard !leadingDigits.isEmpty else { return false }
        let suffix = text.dropFirst(leadingDigits.count)
        return suffix.hasPrefix(". ") || suffix.hasPrefix(") ")
    }

    private static func isMidSentence(_ before: String) -> Bool {
        guard !before.isEmpty else { return false }
        var trimmed = before[...]
        var crossedLineBreak = false
        while let last = trimmed.last, last.isWhitespace {
            crossedLineBreak = crossedLineBreak || last == "\n" || last == "\r"
            trimmed.removeLast()
        }
        if crossedLineBreak { return false }
        while let last = trimmed.last, sentenceClosingWrappers.contains(last) {
            trimmed.removeLast()
        }
        guard let last = trimmed.last else { return false }
        return !sentenceEnders.contains(last) && !openingBoundaries.contains(last)
    }

    private static func lowercasingSafeStarter(in text: String) -> String {
        guard let first = text.first, first.isLetter else { return text }
        let word = String(text.prefix { character in
            character.isLetter || character == "'" || character == "’"
        })
        guard lowercasableStarters.contains(word) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static func needsLeadingSpace(_ text: String, after before: String) -> Bool {
        guard let first = text.first, !first.isWhitespace,
              let prior = before.last, !prior.isWhitespace
        else { return false }
        if usesUnspacedScript(first) || usesUnspacedScript(prior) { return false }
        return !closingPunctuation.contains(first) && !openingBoundaries.contains(prior)
    }

    private static func needsTrailingSpace(_ text: String, before after: String?) -> Bool {
        guard let last = text.last, !last.isWhitespace else { return false }
        if usesUnspacedScript(last) { return false }
        guard let after else { return true }
        guard let following = after.first else { return true }
        guard !following.isWhitespace else { return false }
        if usesUnspacedScript(following) { return false }
        return !closingPunctuation.contains(following) && !openingBoundaries.contains(last)
    }

    private static func usesUnspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, // Thai and Lao
                 0x0F00...0x0FFF, // Tibetan
                 0x1000...0x109F, // Myanmar
                 0x1780...0x17FF, // Khmer
                 0x3040...0x30FF, // Hiragana and Katakana
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // Han
                 0x1100...0x11FF, 0xAC00...0xD7AF: // Hangul
                return true
            default:
                return false
            }
        }
    }
}
