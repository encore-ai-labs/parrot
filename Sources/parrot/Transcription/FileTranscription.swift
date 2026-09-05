import ArgumentParser
import AVFoundation
import Darwin
import Foundation

enum TranscriptOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case markdown
    case text
    case json

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .text: return "txt"
        case .json: return "json"
        }
    }
}

struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe local audio or video files entirely on this Mac."
    )

    @Argument(help: "One or more AVFoundation-readable audio or video files.")
    var files: [String]

    @Option(name: .long, help: "Model id. Defaults to the saved model.")
    var model: String?

    @Option(name: .long, help: "Language code/name, or auto. Defaults to the saved language.")
    var language: String?

    @Flag(name: .long, help: "Apply deterministic spoken-command Markdown formatting.")
    var notes = false

    @Flag(name: .long, help: "Use plain dictation formatting.")
    var dictation = false

    @Flag(name: .long, help: "Lowercase transcript text.")
    var lowercase = false

    @Flag(name: .long, help: "Preserve transcript casing even if lowercase is saved.")
    var noLowercase = false

    @Flag(name: .long, help: "Remove conservative speech fillers and false starts locally.")
    var cleanup = false

    @Flag(name: .customLong("no-cleanup"), help: "Preserve disfluencies even if cleanup is saved.")
    var noCleanup = false

    @Flag(
        name: .customLong("auto-paragraphs"),
        help: "Insert paragraphs at deliberate pauses while using note mode."
    )
    var automaticParagraphs = false

    @Flag(
        name: .customLong("no-auto-paragraphs"),
        help: "Keep note-mode output continuous even if automatic paragraphs are saved."
    )
    var noAutomaticParagraphs = false

    @Flag(name: .long, help: "Ignore saved personal vocabulary.")
    var noVocabulary = false

    @Flag(name: .long, help: "Ignore saved voice snippets.")
    var noSnippets = false

    @Flag(name: .long, help: "Do not remove saved personal filler phrases from output.")
    var noFillers = false

    @Option(name: .long, help: "Output format: markdown, text, or json.")
    var format: TranscriptOutputFormat = .markdown

    @Option(name: .long, help: "Exact output path; valid for one input file.")
    var output: String?

    @Option(name: .long, help: "Write one named output per input into this directory.")
    var outputDirectory: String?

    @Flag(name: .customLong("stdout"), help: "Write one result to stdout instead of a file.")
    var writeToStandardOutput = false

    @Flag(
        name: .customLong("timestamps"),
        inversion: .prefixedNo,
        help: "Include a timestamped segment timeline in Markdown and JSON."
    )
    var timestamps = true

    @Flag(name: .long, help: "Replace existing output files atomically.")
    var force = false

    mutating func validate() throws {
        guard !(notes && dictation) else {
            throw ValidationError("pass at most one of --notes or --dictation")
        }
        guard !(lowercase && noLowercase) else {
            throw ValidationError("pass at most one of --lowercase or --no-lowercase")
        }
        guard !(cleanup && noCleanup) else {
            throw ValidationError("pass at most one of --cleanup or --no-cleanup")
        }
        guard !(automaticParagraphs && noAutomaticParagraphs) else {
            throw ValidationError(
                "pass at most one of --auto-paragraphs or --no-auto-paragraphs"
            )
        }
        guard output == nil || outputDirectory == nil else {
            throw ValidationError("pass at most one of --output or --output-directory")
        }
        guard !writeToStandardOutput || (output == nil && outputDirectory == nil) else {
            throw ValidationError("--stdout cannot be combined with an output path")
        }
        guard files.count == 1 || output == nil else {
            throw ValidationError("--output is valid only with one input file")
        }
        guard files.count == 1 || !writeToStandardOutput else {
            throw ValidationError("--stdout is valid only with one input file")
        }
    }

    mutating func run() throws {
        let command = self
        try FileTranscriptionAsyncBridge.wait {
            try await command.runAsync()
        }
    }

    private func runAsync() async throws {
        let jobs = try FileTranscriptionPlan.makeJobs(
            filePaths: files,
            format: format,
            outputPath: output,
            outputDirectoryPath: outputDirectory,
            standardOutput: writeToStandardOutput,
            force: force
        )
        let config = Config.load()
        guard let recommended = ModelRegistry.recommended()?.id else {
            throw ValidationError("no transcription models are registered")
        }
        let modelID = model ?? config.model ?? recommended
        guard let selectedModel = ModelRegistry.find(modelID) else {
            throw ValidationError("unknown model '\(modelID)'; run `parrot models list`")
        }
        let requestedLanguage = language ?? config.language ?? RecognitionLanguage.automatic
        guard let canonicalLanguage = RecognitionLanguage.canonicalize(requestedLanguage) else {
            throw ValidationError("unknown language '\(requestedLanguage)'; run `parrot languages`")
        }
        guard RecognitionLanguage.isSupported(canonicalLanguage, by: selectedModel) else {
            throw ValidationError(
                "\(selectedModel.id) cannot transcribe \(canonicalLanguage); "
                    + "choose whisper-base/whisper-small or use --language en"
            )
        }
        let mode: DictationMode
        if notes {
            mode = .notes
        } else if dictation {
            mode = .dictation
        } else {
            mode = config.mode ?? .dictation
        }
        let lowercaseOutput: Bool
        if lowercase || noLowercase {
            lowercaseOutput = lowercase
        } else {
            lowercaseOutput = config.lowercase ?? false
        }
        let cleanupOutput: Bool
        if cleanup || noCleanup {
            cleanupOutput = cleanup
        } else {
            cleanupOutput = config.cleanup ?? false
        }
        let automaticParagraphsOutput: Bool
        if automaticParagraphs || noAutomaticParagraphs {
            automaticParagraphsOutput = automaticParagraphs
        } else {
            automaticParagraphsOutput = config.automaticParagraphs ?? true
        }

        let vocabulary = try noVocabulary ? PersonalVocabulary() : PersonalVocabulary.load()
        let snippets = try noSnippets ? SnippetLibrary() : SnippetLibrary.load()
        let fillers = try noFillers ? PersonalFillerLibrary() : PersonalFillerLibrary.load()
        let snippetExpander = SnippetExpander(entries: snippets.entries)
        let fillerRemover = PersonalFillerRemover(entries: fillers.entries)
        let transcriber = TranscriberFactory.make(
            model: selectedModel,
            language: canonicalLanguage,
            automaticParagraphs: mode == .notes && automaticParagraphsOutput,
            vocabulary: vocabulary,
            additionalPromptTerms: snippets.promptTerms,
            notePromptTerms: NoteFormatter.promptTerms
        )

        FileHandle.standardError.write(Data(
            "transcribing \(jobs.count) file\(jobs.count == 1 ? "" : "s") locally"
                .appending(" · \(selectedModel.id) · \(canonicalLanguage) · \(mode.rawValue)\n").utf8
        ))
        try await transcriber.warmUp()

        var failures = 0
        for (index, job) in jobs.enumerated() {
            let position = "[\(index + 1)/\(jobs.count)]"
            FileHandle.standardError.write(Data(
                "→ \(position) \(job.input.lastPathComponent)\n".utf8
            ))
            let started = ContinuousClock.now
            do {
                let transcription = try await transcriber.transcribeFile(at: job.input, mode: mode)
                let applyCleanup = cleanupOutput
                    && RecognitionLanguage.supportsEnglishCleanup(transcription.language)
                if cleanupOutput && !applyCleanup {
                    FileHandle.standardError.write(Data(
                        "  cleanup skipped for detected language \(transcription.language)\n".utf8
                    ))
                }
                let text = TranscriptProcessing.process(
                    transcription.text,
                    mode: mode,
                    lowercase: lowercaseOutput,
                    cleanup: applyCleanup,
                    fillers: fillerRemover,
                    automaticParagraphs: automaticParagraphsOutput,
                    segments: transcription.segments,
                    snippets: snippetExpander
                )
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FileTranscriptionError.noSpeech(job.input.path)
                }
                let processingSeconds = Self.elapsedSeconds(since: started)
                let fallbackDuration = transcription.segments.map(\.endSeconds).max() ?? 0
                let audioSeconds = await Self.audioDuration(
                    at: job.input,
                    fallback: fallbackDuration
                )
                let segments = TranscriptProcessing.processSegments(
                    transcription.segments,
                    cleanup: applyCleanup,
                    fillers: fillerRemover
                )
                let report = FileTranscriptReport(
                    source: job.input.path,
                    sourceName: job.input.lastPathComponent,
                    model: selectedModel.id,
                    mode: mode.rawValue,
                    automaticParagraphs: mode == .notes && automaticParagraphsOutput,
                    language: transcription.language,
                    transcribedAt: Self.timestamp(Date()),
                    audioSeconds: audioSeconds,
                    processingSeconds: processingSeconds,
                    realTimeFactor: audioSeconds > 0 ? processingSeconds / audioSeconds : 0,
                    text: text,
                    segments: timestamps ? segments : []
                )
                let rendered = try FileTranscriptRenderer.render(report, format: format)
                if let destination = job.destination {
                    try SafeTranscriptWriter.write(
                        Data(rendered.utf8),
                        to: destination,
                        force: force
                    )
                    let speed = processingSeconds > 0 ? audioSeconds / processingSeconds : 0
                    FileHandle.standardError.write(Data(
                        String(
                            format: "✓ %@ %.2fs audio · %.2fs · %.1f× realtime\n  %@\n",
                            position,
                            audioSeconds,
                            processingSeconds,
                            speed,
                            destination.path
                        ).utf8
                    ))
                } else {
                    FileHandle.standardOutput.write(Data(rendered.utf8))
                }
            } catch {
                failures += 1
                FileHandle.standardError.write(Data(
                    "× \(position) \(job.input.lastPathComponent): \(error.localizedDescription)\n".utf8
                ))
            }
        }

        if failures > 0 {
            FileHandle.standardError.write(Data(
                "\(failures) of \(jobs.count) files failed\n".utf8
            ))
            throw ExitCode.failure
        }
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func audioDuration(at url: URL, fallback: Double) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite,
              duration.seconds >= 0
        else { return fallback }
        return duration.seconds
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private enum FileTranscriptionAsyncBridge {
    static func wait<T>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else {
            throw BridgeError.missingResult
        }
        return try result.get()
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        var result: Result<Value, Error>?
    }

    private enum BridgeError: Error {
        case missingResult
    }
}

struct FileTranscriptionJob: Equatable {
    let input: URL
    let destination: URL?
}

enum FileTranscriptionPlan {
    static func makeJobs(
        filePaths: [String],
        format: TranscriptOutputFormat,
        outputPath: String?,
        outputDirectoryPath: String?,
        standardOutput: Bool,
        force: Bool,
        fileManager: FileManager = .default
    ) throws -> [FileTranscriptionJob] {
        let inputs = try filePaths.map { path -> URL in
            let url = fileURL(path)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { throw FileTranscriptionError.inputMissing(url.path) }
            guard fileManager.isReadableFile(atPath: url.path) else {
                throw FileTranscriptionError.inputUnreadable(url.path)
            }
            return url
        }

        let exactOutput = outputPath.map(fileURL)
        let outputDirectory = outputDirectoryPath.map(fileURL)
        if let outputDirectory {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
               !isDirectory.boolValue
            {
                throw FileTranscriptionError.outputDirectoryInvalid(outputDirectory.path)
            }
        }
        var jobs: [FileTranscriptionJob] = []
        for input in inputs {
            let destination: URL?
            if standardOutput {
                destination = nil
            } else if let exactOutput {
                destination = exactOutput
            } else {
                let directory = outputDirectory ?? input.deletingLastPathComponent()
                let stem = input.deletingPathExtension().lastPathComponent
                destination = directory
                    .appendingPathComponent(stem.isEmpty ? "transcript" : stem)
                    .appendingPathExtension(format.fileExtension)
                    .standardizedFileURL
            }

            if let destination {
                guard canonicalPath(destination) != canonicalPath(input) else {
                    throw FileTranscriptionError.outputMatchesInput(input.path)
                }
                if fileManager.fileExists(atPath: destination.path), !force {
                    throw FileTranscriptionError.outputExists(destination.path)
                }
            }
            jobs.append(FileTranscriptionJob(input: input, destination: destination))
        }

        var destinations = Set<String>()
        for destination in jobs.compactMap(\.destination) {
            let path = canonicalPath(destination)
            guard destinations.insert(path).inserted else {
                throw FileTranscriptionError.duplicateOutput(destination.path)
            }
        }
        return jobs
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum TranscriptProcessing {
    struct Result: Equatable {
        let text: String
        let mode: DictationMode
        let usedSpokenModeTrigger: Bool
    }

    static func process(
        _ raw: String,
        mode: DictationMode,
        lowercase: Bool,
        cleanup: Bool = false,
        fillers: PersonalFillerRemover = PersonalFillerRemover(entries: []),
        automaticParagraphs: Bool = false,
        segments: [TimedTranscriptSegment] = [],
        snippets: SnippetExpander
    ) -> String {
        processResult(
            raw,
            mode: mode,
            lowercase: lowercase,
            cleanup: cleanup,
            fillers: fillers,
            automaticParagraphs: automaticParagraphs,
            segments: segments,
            snippets: snippets,
            spokenModeTrigger: false
        ).text
    }

    /// Live dictation may opt into an exact leading voice trigger without
    /// changing file transcription or other callers that process stored media.
    static func processWithSpokenModeTrigger(
        _ raw: String,
        fallbackMode: DictationMode,
        lowercase: Bool,
        cleanup: Bool = false,
        fillers: PersonalFillerRemover = PersonalFillerRemover(entries: []),
        automaticParagraphs: Bool = false,
        segments: [TimedTranscriptSegment] = [],
        snippets: SnippetExpander
    ) -> Result {
        processResult(
            raw,
            mode: fallbackMode,
            lowercase: lowercase,
            cleanup: cleanup,
            fillers: fillers,
            automaticParagraphs: automaticParagraphs,
            segments: segments,
            snippets: snippets,
            spokenModeTrigger: true
        )
    }

    private static func processResult(
        _ raw: String,
        mode fallbackMode: DictationMode,
        lowercase: Bool,
        cleanup: Bool,
        fillers: PersonalFillerRemover,
        automaticParagraphs: Bool,
        segments: [TimedTranscriptSegment],
        snippets: SnippetExpander,
        spokenModeTrigger: Bool
    ) -> Result {
        let selection = spokenModeTrigger
            ? SpokenModeTrigger.resolve(raw, fallbackMode: fallbackMode)
            : SpokenModeTrigger.Selection(
                text: raw,
                mode: fallbackMode,
                wasTriggered: false
            )
        // Format pauses against the original transcript so the timed segments
        // still reconstruct it exactly. Strip the trigger from the structured
        // result afterward; its matcher also accepts inserted line breaks.
        let structured = selection.mode == .notes && automaticParagraphs
            ? AutomaticParagraphFormatter.format(raw, segments: segments)
            : raw
        let selectedText = spokenModeTrigger
            ? SpokenModeTrigger.resolve(structured, fallbackMode: fallbackMode).text
            : structured
        let personalized = fillers.applying(to: selectedText)
        let cleaned = cleanup ? SpeechCleanup.clean(personalized) : personalized
        let formatted = selection.mode == .notes ? NoteFormatter.format(cleaned) : cleaned
        let edited = selection.mode == .notes ? SpokenEditProcessor.apply(formatted) : formatted
        let cased = lowercase ? edited.lowercased() : edited
        return Result(
            text: snippets.applying(to: cased)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            mode: selection.mode,
            usedSpokenModeTrigger: selection.wasTriggered
        )
    }

    static func processSegments(
        _ segments: [TimedTranscriptSegment],
        cleanup: Bool,
        fillers: PersonalFillerRemover = PersonalFillerRemover(entries: [])
    ) -> [TimedTranscriptSegment] {
        guard cleanup || fillers.count > 0 else { return segments }
        return segments.compactMap { segment in
            let personalized = fillers.applying(to: segment.text)
            let text = cleanup ? SpeechCleanup.clean(personalized) : personalized
            guard !text.isEmpty else { return nil }
            return TimedTranscriptSegment(
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                text: text
            )
        }
    }
}

struct FileTranscriptReport: Codable, Equatable {
    var schemaVersion = 1
    let source: String
    let sourceName: String
    let model: String
    let mode: String
    let automaticParagraphs: Bool
    let language: String
    let transcribedAt: String
    let audioSeconds: Double
    let processingSeconds: Double
    let realTimeFactor: Double
    let text: String
    let segments: [TimedTranscriptSegment]
}

enum FileTranscriptRenderer {
    static func render(
        _ report: FileTranscriptReport,
        format: TranscriptOutputFormat
    ) throws -> String {
        switch format {
        case .text:
            return report.text + "\n"
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            return String(decoding: data, as: UTF8.self) + "\n"
        case .markdown:
            var output = "# \(escapeHeading(report.sourceName))\n\n"
            output += "<!-- parrot-file-transcript: schema=\(report.schemaVersion) -->\n"
            output += "- Source: `\(escapeCode(report.sourceName))`\n"
            output += "- Transcribed: \(report.transcribedAt)\n"
            output += "- Model: `\(escapeCode(report.model))`\n"
            output += "- Mode: \(report.mode)\n"
            output += "- Automatic paragraphs: \(report.automaticParagraphs ? "on" : "off")\n"
            output += "- Language: \(report.language)\n"
            output += "- Duration: \(timestamp(report.audioSeconds))\n"
            output += String(
                format: "- Processing: %.2fs · %.1f× realtime\n",
                report.processingSeconds,
                report.processingSeconds > 0 ? report.audioSeconds / report.processingSeconds : 0
            )
            output += "\n## Transcript\n\n\(report.text)\n"
            if !report.segments.isEmpty {
                output += "\n## Timeline\n\n"
                for segment in report.segments {
                    let text = segment.text
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    output += "- **[\(timestamp(segment.startSeconds))–\(timestamp(segment.endSeconds))]** \(text)\n"
                }
            }
            return output
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, wholeSeconds, remainder)
        }
        return String(format: "%02d:%02d.%03d", minutes, wholeSeconds, remainder)
    }

    private static func escapeHeading(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["#", "*", "_", "[", "]", "<", ">", "`"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return escaped
    }

    private static func escapeCode(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "ʼ")
    }
}

enum SafeTranscriptWriter {
    static func write(_ data: Data, to url: URL, force: Bool) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try ensurePrivateDirectory(directory, fileManager: fileManager)

        var template = Array(
            directory.appendingPathComponent(".parrot-transcript.XXXXXX").path.utf8CString
        )
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw FileTranscriptionError.outputWriteFailed(url.path, errorMessage(errno))
        }
        let temporary = URL(fileURLWithPath: String(cString: template))
        do {
            try write(data, to: descriptor, outputPath: url.path)
            if force {
                let status = temporary.withUnsafeFileSystemRepresentation { source in
                    url.withUnsafeFileSystemRepresentation { destination in
                        Darwin.rename(source, destination)
                    }
                }
                guard status == 0 else {
                    throw FileTranscriptionError.outputWriteFailed(url.path, errorMessage(errno))
                }
            } else {
                let status = temporary.withUnsafeFileSystemRepresentation { source in
                    url.withUnsafeFileSystemRepresentation { destination in
                        Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
                    }
                }
                guard status == 0 else {
                    if errno == EEXIST { throw FileTranscriptionError.outputExists(url.path) }
                    throw FileTranscriptionError.outputWriteFailed(url.path, errorMessage(errno))
                }
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func ensurePrivateDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw FileTranscriptionError.outputDirectoryInvalid(directory.path)
            }
            return
        }

        var missing: [URL] = []
        var cursor = directory
        while !fileManager.fileExists(atPath: cursor.path, isDirectory: &isDirectory) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {
                throw FileTranscriptionError.outputDirectoryInvalid(directory.path)
            }
            cursor = parent
        }
        guard isDirectory.boolValue else {
            throw FileTranscriptionError.outputDirectoryInvalid(cursor.path)
        }

        for candidate in missing.reversed() {
            try fileManager.createDirectory(
                at: candidate,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: candidate.path
            )
        }
    }

    private static func write(_ data: Data, to descriptor: Int32, outputPath: String) throws {
        var writeError: String?
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    writeError = errorMessage(errno)
                    return
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        if writeError == nil, fsync(descriptor) != 0 {
            writeError = errorMessage(errno)
        }
        if close(descriptor) != 0, writeError == nil {
            writeError = errorMessage(errno)
        }
        if let writeError {
            throw FileTranscriptionError.outputWriteFailed(outputPath, writeError)
        }
    }

    private static func errorMessage(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "error \(code)" }
        return String(cString: message)
    }
}

enum FileTranscriptionError: LocalizedError {
    case inputMissing(String)
    case inputUnreadable(String)
    case outputExists(String)
    case outputMatchesInput(String)
    case duplicateOutput(String)
    case outputDirectoryInvalid(String)
    case outputWriteFailed(String, String)
    case noSpeech(String)

    var errorDescription: String? {
        switch self {
        case .inputMissing(let path):
            return "input file does not exist: \(path)"
        case .inputUnreadable(let path):
            return "input file is not readable: \(path)"
        case .outputExists(let path):
            return "output already exists: \(path) (pass --force to replace it)"
        case .outputMatchesInput(let path):
            return "refusing to replace the input file: \(path)"
        case .duplicateOutput(let path):
            return "multiple inputs resolve to the same output: \(path)"
        case .outputDirectoryInvalid(let path):
            return "output directory is not a directory: \(path)"
        case .outputWriteFailed(let path, let reason):
            return "couldn't write \(path): \(reason)"
        case .noSpeech(let path):
            return "no speech was recognized in \(path)"
        }
    }
}
