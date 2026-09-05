import ArgumentParser
import Darwin
import Foundation
import WhisperKit

/// Reproducible, fully local latency and accuracy measurement for one model.
/// Keeping this in Parrot means model recommendations can be based on the
/// user's microphone, voice, vocabulary, and Mac rather than vendor numbers.
struct ModelBenchmark: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark",
        abstract: "Benchmark one model against a local audio file."
    )

    @Argument(help: "Model id from `parrot models list`.")
    var id: String

    @Option(name: .long, help: "Local WAV, AIFF, M4A, or other AVFoundation-readable audio file.")
    var audio: String

    @Option(name: .long, help: "Expected transcript used to calculate word-error rate (WER).")
    var reference: String?

    @Option(name: .long, help: "UTF-8 file containing the expected transcript.")
    var referenceFile: String?

    @Option(name: .long, help: "Measured inference runs (1...20).")
    var runs: Int = 3

    @Flag(name: .long, help: "Benchmark the same spoken-command formatting used by --notes.")
    var notes = false

    @Flag(name: .long, help: "Ignore the saved personal vocabulary during this benchmark.")
    var noVocabulary = false

    @Flag(name: .long, help: "Print a machine-readable JSON report.")
    var json = false

    mutating func validate() throws {
        guard (1...20).contains(runs) else {
            throw ValidationError("--runs must be between 1 and 20")
        }
        guard reference == nil || referenceFile == nil else {
            throw ValidationError("pass at most one of --reference or --reference-file")
        }
    }

    func run() throws {
        guard let model = ModelRegistry.find(id) else {
            throw ValidationError("unknown model '\(id)'; run `parrot models list`")
        }

        let audioURL = URL(fileURLWithPath: audio).standardizedFileURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ValidationError("audio file does not exist: \(audioURL.path)")
        }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
        guard !samples.isEmpty else {
            throw ValidationError("audio file contains no samples")
        }
        let audioSeconds = Double(samples.count) / AudioCapture.targetSampleRate
        let expected = try loadReference()
        let vocabulary = try noVocabulary ? PersonalVocabulary() : PersonalVocabulary.load()
        let transcriber = WhisperKitTranscriber(
            model: model,
            vocabulary: vocabulary,
            additionalPromptTerms: notes ? NoteFormatter.promptTerms : []
        )

        if !json {
            print("model    \(model.id)")
            print("audio    \(audioURL.path)")
            print(String(format: "duration %.2fs", audioSeconds))
        }

        let loadStarted = ContinuousClock.now
        try waitForAsync { try await transcriber.warmUp() }
        let loadSeconds = elapsedSeconds(since: loadStarted)
        if !json {
            print(String(format: "load     %.3fs", loadSeconds))
        }

        var timings: [Double] = []
        var transcript = ""
        for index in 1...runs {
            let started = ContinuousClock.now
            let raw = try waitForAsync { try await transcriber.transcribe(samples) }
            transcript = notes ? NoteFormatter.format(raw) : raw
            let seconds = elapsedSeconds(since: started)
            timings.append(seconds)
            if !json {
                let speed = seconds > 0 ? audioSeconds / seconds : 0
                print(String(format: "run %-2d   %.3fs · %.1f× realtime", index, seconds, speed))
            }
        }

        let median = BenchmarkMath.median(timings)
        let mean = timings.reduce(0, +) / Double(timings.count)
        let rtf = audioSeconds > 0 ? median / audioSeconds : 0
        let wer = expected.map { BenchmarkMath.wordErrorRate(reference: $0, hypothesis: transcript) }
        let report = ModelBenchmarkReport(
            model: model.id,
            modelSizeMB: model.sizeMB,
            noteMode: notes,
            vocabularyTerms: vocabulary.entries.count,
            audioPath: audioURL.path,
            audioSeconds: audioSeconds,
            loadSeconds: loadSeconds,
            runSeconds: timings,
            medianSeconds: median,
            meanSeconds: mean,
            realTimeFactor: rtf,
            transcript: transcript,
            reference: expected,
            wordErrorRate: wer,
            hardwareModel: SystemProfile.hardwareModel,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString
        )

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(String(format: "median   %.3fs · RTF %.3f", median, rtf))
            print(String(format: "mean     %.3fs", mean))
            if let wer {
                print(String(format: "WER      %.1f%%", wer * 100))
            }
            print("\ntranscript\n\(transcript)")
        }
    }

    private func loadReference() throws -> String? {
        if let reference { return reference }
        guard let referenceFile else { return nil }
        let url = URL(fileURLWithPath: referenceFile).standardizedFileURL
        do {
            return try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ValidationError("couldn't read reference file \(url.path): \(error.localizedDescription)")
        }
    }

    private func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func waitForAsync<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AsyncResultBox<T>()
        Task.detached {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else { throw ModelBenchmarkError.missingAsyncResult }
        return try result.get()
    }
}

struct ModelBenchmarkReport: Codable {
    let model: String
    let modelSizeMB: Int
    let noteMode: Bool
    let vocabularyTerms: Int
    let audioPath: String
    let audioSeconds: Double
    let loadSeconds: Double
    let runSeconds: [Double]
    let medianSeconds: Double
    let meanSeconds: Double
    let realTimeFactor: Double
    let transcript: String
    let reference: String?
    let wordErrorRate: Double?
    let hardwareModel: String
    let macOS: String
}

private final class AsyncResultBox<Value>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

private enum ModelBenchmarkError: Error {
    case missingAsyncResult
}

private enum SystemProfile {
    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: bytes)
    }
}

enum BenchmarkMath {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Standard word-error rate: Levenshtein word edits divided by reference
    /// word count. Case and punctuation are ignored so the score reflects
    /// recognition rather than typography.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let expected = normalizedWords(reference)
        let actual = normalizedWords(hypothesis)
        guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }

        var previous = Array(0...actual.count)
        for (row, expectedWord) in expected.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: actual.count)
            for (column, actualWord) in actual.enumerated() {
                let substitution = previous[column] + (expectedWord == actualWord ? 0 : 1)
                let deletion = previous[column + 1] + 1
                let insertion = current[column] + 1
                current[column + 1] = min(substitution, deletion, insertion)
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let normalized = folded.unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(String(scalar)) }
            if scalar == "'" || scalar == "’" { return nil }
            return " "
        }
        return String(normalized).split(whereSeparator: \Character.isWhitespace).map(String.init)
    }
}
