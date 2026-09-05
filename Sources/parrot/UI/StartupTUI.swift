import Foundation

enum StartupTUI {
    struct Details {
        let version: String
        let hotkey: String
        let noteHotkey: String?
        let noteJournal: String?
        let recognitionContext: String
        let model: String
        let language: String
        let microphone: String
        let mode: String
        let noteTemplate: String?
        let vocabularyCount: Int
        let snippetCount: Int
        let fillerCount: Int
        let templateCount: Int
        let historyPath: String?
        let historyRetentionDays: Int?
        let audioHistoryRetentionDays: Int?
        let delivery: String
        let cleanup: Bool
        let automaticParagraphs: Bool
        let compactLockedPauses: Bool
        let warmMicrophone: Bool
        let systemHotkeyAction: String?
    }

    private static let logo = #"""
        ____  ___    ____  ____  ____  ______
       / __ \/   |  / __ \/ __ \/ __ \/_  __/
      / /_/ / /| | / /_/ / /_/ / / / / /
     / ____/ ___ |/ _, _/ _, _/ /_/ / /
    /_/   /_/  |_/_/ |_/_/ |_|\____/ /_/
    """#

    static func showLogo() {
        guard TerminalSelect.isAvailable else { return }
        write("\n" + cyan(logo) + "\n")
        write("  " + dim("local, private, on-device dictation") + "\n")
    }

    static func show(_ details: Details) {
        guard TerminalSelect.isAvailable else {
            let retention = details.historyRetentionDays.map { " · keep \($0)d" } ?? ""
            let history = details.historyPath.map { " · history: \($0)\(retention)" }
                ?? " · history: off"
            let audioHistory = details.audioHistoryRetentionDays.map { " · audio history: \($0)d" }
                ?? " · audio history: off"
            let systemAction = details.systemHotkeyAction.map { " · \($0)" } ?? ""
            let noteHotkey = details.noteHotkey.map { " · notes key: \($0)" } ?? ""
            let noteJournal = details.noteJournal.map {
                " · note inbox: \(displayPath(URL(fileURLWithPath: $0)))"
            } ?? ""
            let context = details.recognitionContext == "off"
                ? ""
                : " · context: \(details.recognitionContext) (local)"
            let template = details.noteTemplate.map { " · template: \($0)" } ?? ""
            write(
                "listening on \(details.hotkey) hold/double-tap · model: \(details.model)" +
                " · mic: \(details.microphone) · mode: \(details.mode)\(template)" +
                " · language: \(details.language)" +
                " · vocabulary: \(details.vocabularyCount)" +
                " · snippets: \(details.snippetCount)" +
                " · fillers: \(details.fillerCount)" +
                " · templates: \(details.templateCount)" +
                " · delivery: \(details.delivery)" +
                " · cleanup: \(details.cleanup ? "on (English speech)" : "off")" +
                " · paragraphs: \(details.automaticParagraphs ? "on in notes" : "off")" +
                " · pause trim: \(details.compactLockedPauses ? "on when locked" : "off")" +
                " · capture: \(details.warmMicrophone ? "warm/pre-roll" : "cold/on press")" +
                "\(history)\(audioHistory)\(noteHotkey)\(noteJournal)\(context)\(systemAction) · ^C to quit\n"
            )
            write("checking for updates…\n")
            return
        }

        let retention = details.historyRetentionDays.map { " · rolling \($0)d" }
            ?? " · keep forever"
        let history = details.historyPath.map { $0 + retention } ?? "off (--no-history)"
        write("\n")
        write(row("version", details.version))
        write(row("hotkey", "\(details.hotkey)  ·  hold to talk / double-tap to lock / esc to cancel"))
        if let noteHotkey = details.noteHotkey {
            write(row("notes key", "\(noteHotkey)  ·  always starts note mode"))
        }
        if let noteJournal = details.noteJournal {
            write(row("note inbox", displayPath(URL(fileURLWithPath: noteJournal))))
        }
        if let systemHotkeyAction = details.systemHotkeyAction {
            write(row("macOS key", systemHotkeyAction))
        }
        write(row("model", details.model))
        write(row(
            "context",
            details.recognitionContext == "off"
                ? "off  ·  no selection or clipboard access"
                : "\(details.recognitionContext)  ·  bounded local Whisper hint"
        ))
        write(row("language", details.language))
        write(row(
            "mode",
            details.mode + (details.mode == "notes" ? "  (Markdown + local backtrack)" : "")
        ))
        write(row(
            "template",
            details.noteTemplate.map { "\($0)  ·  deterministic local Markdown" }
                ?? "off  ·  say ‘template <name>’ for one note"
        ))
        write(row("microphone", details.microphone))
        write(row(
            "capture",
            details.warmMicrophone
                ? "warm  ·  300ms pre-roll · zero idle waveform work"
                : "cold  ·  opens on press · capture starts may clip"
        ))
        let vocabulary = details.vocabularyCount == 1
            ? "1 term  ·  live reload"
            : "\(details.vocabularyCount) terms  ·  live reload  (parrot vocabulary)"
        write(row("vocabulary", vocabulary))
        let snippets = details.snippetCount == 1
            ? "1 snippet  ·  live reload"
            : "\(details.snippetCount) snippets  ·  live reload  (parrot snippets)"
        write(row("snippets", snippets))
        let fillers = details.fillerCount == 1
            ? "1 personal phrase  ·  live reload"
            : "\(details.fillerCount) personal phrases  ·  live reload  (parrot fillers)"
        write(row("fillers", fillers))
        let templates = details.templateCount == 1
            ? "1 note template  ·  live reload"
            : "\(details.templateCount) note templates  ·  live reload  (parrot templates)"
        write(row("templates", templates))
        write(row("cleanup", details.cleanup ? "on  ·  local deterministic · English speech" : "off"))
        write(row(
            "paragraphs",
            details.automaticParagraphs ? "on  ·  note pauses ≥1.2s" : "off"
        ))
        write(row(
            "pause trim",
            details.compactLockedPauses
                ? "on  ·  locked pauses ≥5s · original recovery audio preserved"
                : "off"
        ))
        write(row("delivery", details.delivery))
        write(row("history", history))
        write(row(
            "audio",
            details.audioHistoryRetentionDays.map {
                "private history · rolling \($0)d  (parrot history audio)"
            } ?? "off  ·  opt in with parrot settings set --audio-history-days 7"
        ))
        write(row("updates", "checking…"))
        write("\n  " + green("● ready") + dim("  ·  ^C to quit") + "\n\n")
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + cyan(label.padding(toLength: 10, withPad: " ", startingAt: 0)) + "  " + value + "\n"
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func cyan(_ text: String) -> String { "\u{1B}[1;36m" + text + "\u{1B}[0m" }
    private static func green(_ text: String) -> String { "\u{1B}[1;32m" + text + "\u{1B}[0m" }
    private static func dim(_ text: String) -> String { "\u{1B}[2m" + text + "\u{1B}[0m" }
}
