import Foundation

enum StartupTUI {
    struct Details {
        let version: String
        let hotkey: String
        let model: String
        let language: String
        let microphone: String
        let mode: String
        let vocabularyCount: Int
        let snippetCount: Int
        let historyPath: String?
        let delivery: String
        let cleanup: Bool
        let automaticParagraphs: Bool
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
            let history = details.historyPath.map { " · history: \($0)" } ?? " · history: off"
            let systemAction = details.systemHotkeyAction.map { " · \($0)" } ?? ""
            write(
                "listening on \(details.hotkey) hold/double-tap · model: \(details.model)" +
                " · mic: \(details.microphone) · mode: \(details.mode)" +
                " · language: \(details.language)" +
                " · vocabulary: \(details.vocabularyCount)" +
                " · snippets: \(details.snippetCount)" +
                " · delivery: \(details.delivery)" +
                " · cleanup: \(details.cleanup ? "on (English speech)" : "off")" +
                " · paragraphs: \(details.automaticParagraphs ? "on in notes" : "off")" +
                " · capture: \(details.warmMicrophone ? "warm/pre-roll" : "cold/on press")" +
                "\(history)\(systemAction) · ^C to quit\n"
            )
            write("checking for updates…\n")
            return
        }

        let history = details.historyPath ?? "off (--no-history)"
        write("\n")
        write(row("version", details.version))
        write(row("hotkey", "\(details.hotkey)  ·  hold to talk / double-tap to lock / esc to cancel"))
        if let systemHotkeyAction = details.systemHotkeyAction {
            write(row("macOS key", systemHotkeyAction))
        }
        write(row("model", details.model))
        write(row("language", details.language))
        write(row(
            "mode",
            details.mode + (details.mode == "notes" ? "  (Markdown + local backtrack)" : "")
        ))
        write(row("microphone", details.microphone))
        write(row(
            "capture",
            details.warmMicrophone
                ? "warm  ·  300ms pre-roll · zero idle waveform work"
                : "cold  ·  opens on press · capture starts may clip"
        ))
        let vocabulary = details.vocabularyCount == 1
            ? "1 term"
            : "\(details.vocabularyCount) terms  (parrot vocabulary)"
        write(row("vocabulary", vocabulary))
        let snippets = details.snippetCount == 1
            ? "1 snippet"
            : "\(details.snippetCount) snippets  (parrot snippets)"
        write(row("snippets", snippets))
        write(row("cleanup", details.cleanup ? "on  ·  local deterministic · English speech" : "off"))
        write(row(
            "paragraphs",
            details.automaticParagraphs ? "on  ·  note pauses ≥1.2s" : "off"
        ))
        write(row("delivery", details.delivery))
        write(row("history", history))
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
