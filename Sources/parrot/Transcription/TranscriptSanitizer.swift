import Foundation

/// Removes Whisper's non-speech annotations without eating dictated text.
///
/// Whisper narrates what it hears when there's no speech — `[BLANK_AUDIO]`,
/// `(silence)`, `[MUSIC]`, `*laughs*` — and pasting those into an editor is
/// nonsense. The obvious fix, deleting anything between brackets, is worse than
/// the problem: it silently turns "multiply 2 * 3 and then 5 * 6" into
/// "multiply 2 6", and "use array[0]" into "use array".
///
/// So a bracketed span is only removed when we have a positive reason to think
/// it's an annotation:
///
/// 1. `<|...|>` — Whisper control tokens. Always removed; speech can't produce them.
/// 2. Contents match a known non-speech phrase (`silence`, `music`, `applause`, …).
/// 3. Square brackets holding a SHOUTED_TAG, which is Whisper's house style for
///    annotations and vanishingly rare in dictation.
/// 4. The span is the *entire* transcript — people don't dictate a lone
///    parenthetical, but a silent recording often yields exactly one tag.
///
/// Anything else is left alone. When in doubt we keep the text: a stray
/// `[MUSIC]` is a visible annoyance the user can delete, whereas silently
/// dropping half a sentence is a bug they may never notice.
enum TranscriptSanitizer {
    static func sanitize(_ text: String) -> String {
        var out = text

        // 1. Control tokens — unconditional.
        out = out.replacingOccurrences(
            of: #"<\|[^|>]*\|>"#, with: " ", options: .regularExpression
        )

        // 2-4. Delimited spans, each judged on its contents.
        out = stripSpans(out, open: "[", close: "]", allowShoutedTag: true)
        out = stripSpans(out, open: "(", close: ")", allowShoutedTag: false)
        out = stripAsteriskSpans(out)

        return tidy(out)
    }

    // MARK: - Span handling

    /// Remove `open…close` spans whose contents look like an annotation.
    private static func stripSpans(
        _ text: String, open: String, close: String, allowShoutedTag: Bool
    ) -> String {
        let pattern = "\(NSRegularExpression.escapedPattern(for: open))"
            + "([^\(NSRegularExpression.escapedPattern(for: close))]*)"
            + "\(NSRegularExpression.escapedPattern(for: close))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        // A span covering the whole transcript is an annotation by elimination.
        let wholeTranscript = matches.count == 1
            && ns.substring(with: matches[0].range).trimmingCharacters(in: .whitespaces)
                == text.trimmingCharacters(in: .whitespaces)

        var result = text
        // Back to front so earlier ranges stay valid.
        for match in matches.reversed() {
            let content = ns.substring(with: match.range(at: 1))
            let remove = wholeTranscript
                || isNonSpeech(content)
                || (allowShoutedTag && isShoutedTag(content))
            if remove {
                result = (result as NSString).replacingCharacters(in: match.range, with: " ")
            }
        }
        return result
    }

    /// `*...*` is the riskiest delimiter — asterisks are also multiplication and
    /// Markdown emphasis — so it needs both markers adjacent to their content
    /// (`*laughs*`, never `2 * 3`) *and* a known phrase inside.
    private static func stripAsteriskSpans(_ text: String) -> String {
        // \*(\S[^*]*?)\* — opening marker must be followed by non-space, closing
        // preceded by non-space. "2 * 3 and 5 * 6" can't match.
        guard let regex = try? NSRegularExpression(pattern: #"\*(\S[^*]*?\S|\S)\*"#) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let wholeTranscript = matches.count == 1
            && ns.substring(with: matches[0].range).trimmingCharacters(in: .whitespaces)
                == text.trimmingCharacters(in: .whitespaces)

        var result = text
        for match in matches.reversed() {
            let content = ns.substring(with: match.range(at: 1))
            if wholeTranscript || isNonSpeech(content) {
                result = (result as NSString).replacingCharacters(in: match.range, with: " ")
            }
        }
        return result
    }

    // MARK: - Classification

    /// Whisper writes annotations as `[BLANK_AUDIO]`, `[SPEAKER_01]`, `[MUSIC]`.
    /// Requires 3+ chars so `array[0]` and `list[N]` survive.
    private static func isShoutedTag(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        guard trimmed.range(of: #"^[A-Z][A-Z0-9 _\-]{2,}$"#, options: .regularExpression) != nil
        else { return false }
        // Needs at least one letter — "0 1 2" isn't a tag.
        return trimmed.rangeOfCharacter(from: .letters) != nil
    }

    static func isNonSpeech(_ raw: String) -> Bool {
        var s = raw.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Drop surrounding punctuation but keep interior words intact.
        while let first = s.first, first.isPunctuation || first.isSymbol { s.removeFirst() }
        while let last = s.last, last.isPunctuation || last.isSymbol { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)

        if s.isEmpty { return true }
        if phrases.contains(s) { return true }

        // Productive forms Whisper generates that a fixed list can't cover.
        let patterns = [
            #"^.{0,20}\bnoise$"#,                    // background noise, wind noise
            #"^sounds? of\b.*$"#,                    // sound of a door
            #"^speaking (in )?\w+( language)?$"#,    // speaking in Spanish
            #"^\w+ (music|sound|sounds|noises?)$"#,  // upbeat music
            #"^(music|audio) (playing|continues|stops|fades)$"#,
            #"^no (speech|audio|sound)$"#,
            #"^\w+ (laughs|laughing|chuckles|sighs|coughs)$"#,
        ]
        return patterns.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    /// Known non-speech annotations, normalized (lowercase, underscores as spaces).
    private static let phrases: Set<String> = [
        "blank audio", "blank", "silence", "silent", "pause", "long pause",
        "music", "musique", "music playing", "upbeat music", "soft music",
        "instrumental", "theme music", "outro music", "intro music",
        "applause", "clapping", "cheering", "cheers",
        "laughter", "laughs", "laughing", "chuckles", "chuckling", "giggles",
        "inaudible", "unintelligible", "indistinct", "indistinct chatter",
        "crosstalk", "overlapping speech",
        "noise", "static", "beep", "beeping", "click", "clicking", "clicks",
        "typing", "keyboard", "keyboard clicking", "mouse click",
        "cough", "coughs", "coughing", "sneeze", "sneezes",
        "sigh", "sighs", "sighing", "groans", "grunts", "sniffles",
        "breath", "breathing", "breathes", "exhales", "inhales", "heavy breathing",
        "clears throat", "throat clearing",
        "wind", "wind blowing", "rain", "thunder", "footsteps",
        "door closes", "door opens", "knocking", "phone ringing", "ringing",
        "engine", "engine revving", "car horn", "siren", "birds chirping",
        "no speech", "nospeech", "end of audio", "endoftext",
        "foreign", "foreign language", "non english", "non-english",
        "background", "ambient", "ambience", "silence continues",
        "video", "audio", "sound", "sounds", "sound effect", "sfx",
    ]

    // MARK: - Cleanup

    /// Removing a span mid-sentence leaves doubled spaces and orphaned spacing
    /// before punctuation.
    private static func tidy(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression
        )
        // A leading orphan like ", hello" after stripping a lead-in tag.
        out = out.replacingOccurrences(
            of: #"^[\s,;:.]+"#, with: "", options: .regularExpression
        )
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
