import Foundation

/// Converts engine-specific word timings into stable sentence/pause-sized
/// segments shared by live paragraphing and file timelines.
enum TimedSegmentBuilder {
    static func segments(
        from words: [TimedWord],
        vocabularyReplacer: VocabularyReplacer,
        maximumDuration: TimeInterval? = nil
    ) -> [TimedTranscriptSegment] {
        guard !words.isEmpty else { return [] }
        var output: [TimedTranscriptSegment] = []
        var group: [TimedWord] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            var text = group.map(\.text).joined(separator: " ")
            text = text.replacingOccurrences(
                of: #"\s+([,.;:!?])"#,
                with: "$1",
                options: .regularExpression
            )
            text = vocabularyReplacer.applying(to: TranscriptSanitizer.sanitize(text))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let start = min(max(0, first.start), maximumDuration ?? .infinity)
                let end = min(max(start, last.end), maximumDuration ?? .infinity)
                output.append(TimedTranscriptSegment(
                    startSeconds: start,
                    endSeconds: end,
                    text: text
                ))
            }
            group.removeAll(keepingCapacity: true)
        }

        for (index, word) in words.enumerated() {
            let cleanWord = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanWord.isEmpty else { continue }
            group.append(TimedWord(text: cleanWord, start: word.start, end: word.end))
            let nextGap = index + 1 < words.count
                ? words[index + 1].start - word.end
                : .infinity
            let sentenceEnded = cleanWord.last.map { ".!?".contains($0) } ?? false
            if sentenceEnded || nextGap >= 0.8 || group.count >= 28 {
                flush()
            }
        }
        flush()
        return output
    }
}
