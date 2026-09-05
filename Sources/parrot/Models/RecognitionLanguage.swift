import ArgumentParser
import Foundation
import WhisperKit

/// Canonicalizes Whisper language names/codes and keeps model compatibility
/// checks in one place. `auto` is a Parrot setting; decoder `nil` means that
/// WhisperKit should detect the language from the current recording.
enum RecognitionLanguage {
    static let automatic = "auto"

    static var supportedCodes: [String] {
        Constants.languageCodes.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1))
                == .orderedAscending
        }
    }

    static func canonicalize(_ raw: String) -> String? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        if [automatic, "automatic", "automatic detection", "detect", "detect automatically"]
            .contains(normalized) {
            return automatic
        }
        if let code = Constants.languages[normalized] { return code }
        if Constants.languageCodes.contains(normalized) { return normalized }
        if let base = normalized.split(separator: "-").first.map(String.init),
           Constants.languageCodes.contains(base) {
            return base
        }
        return nil
    }

    static func displayName(for code: String) -> String {
        guard code != automatic else { return "Automatic detection" }
        return Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: code)
            ?? code
    }

    static func isSupported(_ requested: String, by model: TranscriptionModel) -> Bool {
        guard let code = canonicalize(requested) else { return false }
        if code == automatic { return true }
        return model.languages.contains("multi") || model.languages.contains(code)
    }

    /// The language sent to the decoder. An English-only model constrains
    /// automatic selection to English and avoids paying for detection.
    static func decoderLanguage(
        requested: String,
        model: TranscriptionModel
    ) -> String? {
        guard let code = canonicalize(requested) else { return nil }
        if code != automatic { return code }
        if model.languages.contains("multi") { return nil }
        return model.languages.first(where: { $0 != "multi" })
    }

    static func displaySelection(_ requested: String, model: TranscriptionModel) -> String {
        guard let canonical = canonicalize(requested) else { return requested }
        if canonical == automatic,
           let constrained = decoderLanguage(requested: requested, model: model) {
            return "\(displayName(for: constrained)) (model fixed)"
        }
        return displayName(for: canonical)
    }

    static func supportsEnglishCleanup(_ detected: String) -> Bool {
        canonicalize(detected) == "en"
    }
}

struct Languages: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List languages supported by local multilingual Whisper models."
    )

    func run() {
        print("  auto  Automatic detection")
        for code in RecognitionLanguage.supportedCodes {
            let padded = code.padding(toLength: 5, withPad: " ", startingAt: 0)
            print("  \(padded) \(RecognitionLanguage.displayName(for: code))")
        }
        print("\nUse `parrot settings set --model whisper-base --language <code>`.")
        print("A fixed language skips automatic detection and minimizes latency.")
    }
}
