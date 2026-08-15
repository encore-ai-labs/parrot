import Darwin
import Foundation

/// Arrow-key menu for the terminal.
///
/// Puts the terminal into raw mode so we can see individual keypresses rather
/// than waiting on a newline. That makes restoring the original `termios` a
/// correctness issue, not a nicety — leaving raw mode set would give the user a
/// shell with no echo and no line editing. Every exit path restores, including
/// Ctrl-C, which we handle ourselves rather than letting SIGINT kill us
/// mid-render.
/// Set while a menu holds the terminal in raw mode, so an `atexit` handler can
/// put it back if we exit through a path that skips normal cleanup.
private nonisolated(unsafe) var savedTermios: termios?

enum TerminalSelect {
    struct Option {
        let label: String
        /// Dimmed text after the label.
        let detail: String?
        /// Shown in yellow — used for "this will wreck your audio" style notes.
        let warning: String?

        init(label: String, detail: String? = nil, warning: String? = nil) {
            self.label = label
            self.detail = detail
            self.warning = warning
        }
    }

    static var isAvailable: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1 }

    /// Present a menu. Returns the chosen index, or nil if the terminal can't
    /// support it or the user backed out.
    static func choose(
        title: String,
        options: [Option],
        initial: Int = 0,
        footer: String? = nil
    ) -> Int? {
        guard isAvailable, !options.isEmpty else { return nil }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }

        var raw = original
        // ISIG has to go too. Left on, Ctrl-C raises SIGINT instead of
        // delivering 0x03, the process dies before it can put the terminal
        // back, and the user is left in a shell with no echo and no line
        // editing. With it off we see the byte and handle the exit ourselves.
        raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON) | tcflag_t(ISIG))
        // Canonical mode overloads these slots with VEOF/VEOL, so without
        // setting them read() would block until 4 bytes arrived.
        raw.c_cc.16 = 1  // VMIN  — return after a single byte
        raw.c_cc.17 = 0  // VTIME — no timeout
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }

        // Belt and braces for any exit path that doesn't run our cleanup
        // (a caller calling exit(), say). Stashing it in a global is the only
        // way an atexit C function can see it.
        savedTermios = original
        atexit { if var t = savedTermios { tcsetattr(STDIN_FILENO, TCSANOW, &t) } }

        func restore() {
            write(esc("?25h"))  // show cursor
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            savedTermios = nil
        }

        var index = min(max(initial, 0), options.count - 1)
        write("\n\(bold(title))\n")
        write(esc("?25l"))  // hide cursor
        render(options: options, index: index, footer: footer, redraw: false)

        while true {
            var byte: UInt8 = 0
            let n = read(STDIN_FILENO, &byte, 1)
            guard n == 1 else { restore(); return nil }

            switch byte {
            case 0x1B:  // ESC — possibly an arrow sequence
                var seq = [UInt8](repeating: 0, count: 2)
                guard read(STDIN_FILENO, &seq, 2) == 2, seq[0] == 0x5B else { break }
                switch seq[1] {
                case 0x41: index = (index - 1 + options.count) % options.count  // up
                case 0x42: index = (index + 1) % options.count                  // down
                default: break
                }
                render(options: options, index: index, footer: footer, redraw: true)

            case 0x6B:  // k — vim up
                index = (index - 1 + options.count) % options.count
                render(options: options, index: index, footer: footer, redraw: true)

            case 0x6A:  // j — vim down
                index = (index + 1) % options.count
                render(options: options, index: index, footer: footer, redraw: true)

            case 0x0D, 0x0A:  // Enter
                restore()
                write("\n")
                return index

            case 0x03:  // Ctrl-C — quit, don't silently pick a default
                restore()
                write("\n")
                exit(130)

            case 0x71:  // q — back out, caller falls back to its default
                restore()
                write("\n")
                return nil

            case 0x31...0x39:  // 1-9 jump straight to an entry
                let n = Int(byte - 0x30) - 1
                if n < options.count {
                    index = n
                    render(options: options, index: index, footer: footer, redraw: true)
                }

            default:
                break
            }
        }
    }

    /// Two-option menu. Returns nil if cancelled or unavailable.
    static func confirm(
        title: String,
        yes: Option,
        no: Option,
        defaultYes: Bool
    ) -> Bool? {
        let choice = choose(
            title: title,
            options: [yes, no],
            initial: defaultYes ? 0 : 1,
            footer: "↑↓ to move · enter to choose"
        )
        guard let choice else { return nil }
        return choice == 0
    }

    // MARK: -

    private static func render(options: [Option], index: Int, footer: String?, redraw: Bool) {
        let lineCount = options.count + (footer == nil ? 0 : 1)
        if redraw {
            write(esc("\(lineCount)A"))  // back to the top of the block
        }

        let width = options.map(\.label.count).max() ?? 0
        for (i, option) in options.enumerated() {
            let selected = i == index
            let pointer = selected ? "❯ " : "  "
            let label = option.label.padding(toLength: width, withPad: " ", startingAt: 0)
            var line = pointer + (selected ? bold(label) : label)
            if let detail = option.detail { line += "  " + dim(detail) }
            if let warning = option.warning { line += "  " + yellow(warning) }
            write(esc("2K") + line + "\n")
        }
        if let footer {
            write(esc("2K") + dim(footer) + "\n")
        }
    }

    private static func write(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    private static func esc(_ s: String) -> String { "\u{1B}[" + s }
    private static func bold(_ s: String) -> String { "\u{1B}[1m" + s + "\u{1B}[0m" }
    private static func dim(_ s: String) -> String { "\u{1B}[2m" + s + "\u{1B}[0m" }
    private static func yellow(_ s: String) -> String { "\u{1B}[33m" + s + "\u{1B}[0m" }
}
