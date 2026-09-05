import Darwin
import Foundation

final class ModelDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let interactive: Bool
    private let sink: @Sendable (String) -> Void
    private var lastPercent = -1
    private var emitted = false

    init(
        interactive: Bool = isatty(STDERR_FILENO) == 1,
        sink: @escaping @Sendable (String) -> Void = { text in
            FileHandle.standardError.write(Data(text.utf8))
        }
    ) {
        self.interactive = interactive
        self.sink = sink
    }

    func update(_ progress: Progress) {
        let percent = min(100, max(0, Int((progress.fractionCompleted * 100).rounded())))
        lock.lock()
        defer { lock.unlock() }
        let step = interactive ? 1 : 10
        guard percent == 100 || lastPercent < 0 || percent >= lastPercent + step else { return }
        lastPercent = percent
        emitted = true
        if interactive {
            sink("\rdownloading model… \(percent)%")
        } else {
            sink("downloading model… \(percent)%\n")
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if emitted, interactive { sink("\n") }
        emitted = false
        lastPercent = -1
    }
}
