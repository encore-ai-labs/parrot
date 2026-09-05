import Foundation

/// Inserts paragraph breaks at deliberate speech pauses without rewriting any
/// recognized words. Timed segments must reconstruct the full transcript
/// exactly (ignoring whitespace), otherwise the original text is returned.
enum AutomaticParagraphFormatter {
    static let pauseThreshold: TimeInterval = 1.2

    static func format(
        _ text: String,
        segments: [TimedTranscriptSegment],
        pauseThreshold: TimeInterval = pauseThreshold
    ) -> String {
        let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty,
              !fallback.contains("\n"),
              pauseThreshold >= 0
        else { return fallback }

        let ordered = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.startSeconds == $1.startSeconds {
                    return $0.endSeconds < $1.endSeconds
                }
                return $0.startSeconds < $1.startSeconds
            }
        guard ordered.count > 1 else { return fallback }

        let pieces = ordered.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalized(pieces.joined(separator: " ")) == normalized(fallback) else {
            return fallback
        }

        var insertedBreak = false
        var output = pieces[0]
        for index in 1..<ordered.count {
            let gap = max(0, ordered[index].startSeconds - ordered[index - 1].endSeconds)
            if gap >= pauseThreshold {
                output += "\n\n"
                insertedBreak = true
            } else {
                output += " "
            }
            output += pieces[index]
        }
        return insertedBreak ? output : fallback
    }

    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
