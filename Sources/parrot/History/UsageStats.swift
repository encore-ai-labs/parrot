import Foundation

enum StatsPeriod: String, CaseIterable, Codable {
    case all
    case today
    case week
    case month
}

struct UsageSummary: Codable, Equatable {
    let period: StatsPeriod
    let dictations: Int
    let words: Int
    let characters: Int
    let activeDays: Int
    let averageWordsPerDictation: Double
    let currentStreakDays: Int
    let longestStreakDays: Int
    let measuredDictations: Int
    let voiceSeconds: TimeInterval
    let processingSeconds: TimeInterval
    let enhancementAttempts: Int
    let enhancementSeconds: TimeInterval
    let averageEnhancementSeconds: TimeInterval?
    let averageSpeakingWPM: Double?
    let processingRealtimeFactor: Double?
    let estimatedTypingSeconds: TimeInterval
    let estimatedTimeSavedSeconds: TimeInterval?
    let assumedTypingWPM: Double
    let models: [ModelUsageSummary]
    let modes: [ModeUsageSummary]
}

struct ModelUsageSummary: Codable, Equatable {
    let modelID: String
    let dictations: Int
    let measuredDictations: Int
    let voiceSeconds: TimeInterval
    let processingSeconds: TimeInterval
    let processingRealtimeFactor: Double?
}

struct ModeUsageSummary: Codable, Equatable {
    let mode: DictationMode
    let dictations: Int
}

enum UsageStats {
    static func summarize(
        _ records: [TranscriptRecord],
        period: StatsPeriod = .all,
        now: Date = Date(),
        calendar: Calendar = .current,
        typingWPM: Double = 40
    ) -> UsageSummary {
        let filtered = records.filter { record in
            guard record.recordedAt <= now else { return false }
            guard let start = startDate(for: period, now: now, calendar: calendar) else {
                return true
            }
            return record.recordedAt >= start
        }
        let wordCounts = filtered.map { wordCount($0.text) }
        let totalWords = wordCounts.reduce(0, +)
        let days = Set(filtered.map { calendar.startOfDay(for: $0.recordedAt) })
        let streaks = streakLengths(days: days, now: now, calendar: calendar)

        var measuredDictations = 0
        var measuredWords = 0
        var voiceSeconds: TimeInterval = 0
        var processingSeconds: TimeInterval = 0
        for (record, words) in zip(filtered, wordCounts) {
            guard let audio = record.audioDuration, audio > 0 else { continue }
            measuredDictations += 1
            measuredWords += words
            voiceSeconds += audio
            processingSeconds += max(0, record.processingDuration ?? 0)
        }
        let enhancementDurations = filtered.compactMap { record -> TimeInterval? in
            guard let duration = record.enhancementDuration,
                  duration.isFinite,
                  duration >= 0
            else { return nil }
            return duration
        }
        let enhancementSeconds = enhancementDurations.reduce(0, +)

        let safeTypingWPM = max(1, typingWPM)
        let measuredTypingSeconds = Double(measuredWords) / safeTypingWPM * 60
        let models = Dictionary(grouping: filtered.compactMap { record in
            record.modelID.map { ($0, record) }
        }, by: { $0.0 })
        .map { modelID, pairs -> ModelUsageSummary in
            let records = pairs.map(\.1)
            let measured = records.compactMap { record -> (TimeInterval, TimeInterval)? in
                guard let audio = record.audioDuration,
                      let processing = record.processingDuration,
                      audio.isFinite, processing.isFinite,
                      audio > 0, processing >= 0
                else { return nil }
                let enhancement: TimeInterval
                if let duration = record.enhancementDuration,
                   duration.isFinite,
                   duration >= 0 {
                    enhancement = duration
                } else {
                    enhancement = 0
                }
                return (audio, max(0, processing - enhancement))
            }
            let voice = measured.reduce(0) { $0 + $1.0 }
            let processing = measured.reduce(0) { $0 + $1.1 }
            return ModelUsageSummary(
                modelID: modelID,
                dictations: records.count,
                measuredDictations: measured.count,
                voiceSeconds: voice,
                processingSeconds: processing,
                processingRealtimeFactor: voice > 0 ? processing / voice : nil
            )
        }
        .sorted {
            if $0.dictations != $1.dictations { return $0.dictations > $1.dictations }
            return $0.modelID < $1.modelID
        }
        let modes = DictationMode.allCases.compactMap { mode -> ModeUsageSummary? in
            let count = filtered.lazy.filter { $0.mode == mode }.count
            return count > 0 ? ModeUsageSummary(mode: mode, dictations: count) : nil
        }
        return UsageSummary(
            period: period,
            dictations: filtered.count,
            words: totalWords,
            characters: filtered.reduce(0) { $0 + $1.text.count },
            activeDays: days.count,
            averageWordsPerDictation: filtered.isEmpty
                ? 0
                : Double(totalWords) / Double(filtered.count),
            currentStreakDays: streaks.current,
            longestStreakDays: streaks.longest,
            measuredDictations: measuredDictations,
            voiceSeconds: voiceSeconds,
            processingSeconds: processingSeconds,
            enhancementAttempts: enhancementDurations.count,
            enhancementSeconds: enhancementSeconds,
            averageEnhancementSeconds: enhancementDurations.isEmpty
                ? nil
                : enhancementSeconds / Double(enhancementDurations.count),
            averageSpeakingWPM: voiceSeconds > 0
                ? Double(measuredWords) / (voiceSeconds / 60)
                : nil,
            processingRealtimeFactor: voiceSeconds > 0
                ? processingSeconds / voiceSeconds
                : nil,
            estimatedTypingSeconds: Double(totalWords) / safeTypingWPM * 60,
            estimatedTimeSavedSeconds: measuredDictations > 0
                ? max(0, measuredTypingSeconds - voiceSeconds - processingSeconds)
                : nil,
            assumedTypingWPM: safeTypingWPM,
            models: models,
            modes: modes
        )
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    private static func startDate(
        for period: StatsPeriod,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        switch period {
        case .all:
            return nil
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start
        }
    }

    private static func streakLengths(
        days: Set<Date>,
        now: Date,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        guard !days.isEmpty else { return (0, 0) }
        let sorted = days.sorted()
        var longest = 1
        var run = 1
        for index in 1..<sorted.count {
            if calendar.dateComponents([.day], from: sorted[index - 1], to: sorted[index]).day == 1 {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        guard days.contains(today) || days.contains(yesterday) else { return (0, longest) }
        var cursor = days.contains(today) ? today : yesterday
        var current = 0
        while days.contains(cursor) {
            current += 1
            guard let prior = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prior
        }
        return (current, longest)
    }
}
