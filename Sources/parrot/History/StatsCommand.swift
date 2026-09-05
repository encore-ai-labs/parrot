import ArgumentParser
import Foundation

extension StatsPeriod: ExpressibleByArgument {}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show private usage insights calculated from local transcript history."
    )

    @Option(name: .long, help: "Time period: all, today, week, or month.")
    var period: StatsPeriod = .all

    @Option(
        name: .long,
        help: "Typing speed used to estimate time saved (1...300 words per minute)."
    )
    var typingWpm: Double = 40

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json: Bool = false

    func validate() throws {
        guard (1...300).contains(typingWpm) else {
            throw ValidationError("--typing-wpm must be between 1 and 300")
        }
    }

    func run() throws {
        let records = try TranscriptHistoryReader().all()
        let summary = UsageStats.summarize(records, period: period, typingWPM: typingWpm)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(summary), as: UTF8.self))
            return
        }
        guard summary.dictations > 0 else {
            print("no saved transcripts for \(periodLabel(period))")
            print("history: \(TranscriptHistory.defaultDirectory.path)")
            return
        }

        print("Parrot stats · \(periodLabel(period))")
        print("  dictations       \(integer(summary.dictations))")
        print("  words            \(integer(summary.words))")
        print("  characters       \(integer(summary.characters))")
        print("  active days      \(integer(summary.activeDays))")
        print("  words/dictation  \(decimal(summary.averageWordsPerDictation))")
        print(
            "  typing equivalent \(duration(summary.estimatedTypingSeconds)) "
                + "at \(decimal(summary.assumedTypingWPM)) wpm"
        )
        print("  current streak   \(summary.currentStreakDays) day\(plural(summary.currentStreakDays))")
        print("  longest streak   \(summary.longestStreakDays) day\(plural(summary.longestStreakDays))")

        if summary.measuredDictations > 0 {
            print()
            print("Measured voice activity")
            print("  coverage         \(summary.measuredDictations)/\(summary.dictations) dictations")
            print("  voice time       \(duration(summary.voiceSeconds))")
            if let pace = summary.averageSpeakingWPM {
                print("  speaking pace    \(integer(Int(pace.rounded()))) wpm")
            }
            if let factor = summary.processingRealtimeFactor {
                print("  processing       \(duration(summary.processingSeconds)) · \(decimal(factor))× realtime")
            }
            if let saved = summary.estimatedTimeSavedSeconds {
                print("  estimated saved  \(duration(saved)) in measured dictations")
            }
        } else {
            print()
            print("Voice-time metrics begin with newly recorded dictations; older Markdown stays valid.")
        }

        if !summary.models.isEmpty {
            print()
            print("Model performance")
            for model in summary.models {
                let count = "\(model.dictations) dictation\(plural(model.dictations))"
                if let factor = model.processingRealtimeFactor {
                    let coverage = model.measuredDictations == model.dictations
                        ? ""
                        : " · \(model.measuredDictations) timed"
                    print(
                        "  \(model.modelID)  \(count) · \(duration(model.voiceSeconds)) voice"
                            + " · \(decimal(factor))× realtime\(coverage)"
                    )
                } else {
                    print("  \(model.modelID)  \(count) · timing unavailable")
                }
            }
        }

        if !summary.modes.isEmpty {
            print()
            print("Workflow modes")
            for mode in summary.modes {
                print("  \(mode.mode.rawValue)  \(mode.dictations) dictation\(plural(mode.dictations))")
            }
        }
        print()
        print("Calculated locally from \(TranscriptHistory.defaultDirectory.path)")
    }
}

private func periodLabel(_ period: StatsPeriod) -> String {
    switch period {
    case .all: return "all time"
    case .today: return "today"
    case .week: return "this week"
    case .month: return "this month"
    }
}

private func integer(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private func decimal(_ value: Double) -> String {
    String(format: value >= 10 ? "%.0f" : "%.2f", value)
}

private func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remainder = total % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(remainder)s" }
    return "\(remainder)s"
}

private func plural(_ count: Int) -> String { count == 1 ? "" : "s" }
