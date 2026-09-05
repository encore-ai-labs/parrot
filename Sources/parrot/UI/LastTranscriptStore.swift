import Foundation

/// Session-local recovery state for cursor insertion. History can seed it at
/// startup, but successful `--no-history` dictations remain recoverable too.
@MainActor
final class LastTranscriptStore {
    private(set) var text: String?

    func update(_ rawText: String) {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = rawText
    }
}
