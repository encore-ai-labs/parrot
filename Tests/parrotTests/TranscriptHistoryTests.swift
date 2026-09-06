import XCTest

@testable import parrot

final class TranscriptHistoryTests: XCTestCase {
    func testEntryIDsRemainUniqueForSameMillisecondCaptures() async throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let instant = try date(
            year: 2024, month: 9, day: 5, hour: 12, minute: 34, second: 56,
            calendar: calendar
        )

        let first = try await store.appendEntry("first", at: instant)
        let second = try await store.appendEntry("second", at: instant)

        XCTAssertEqual(first?.id, "20240905-123456-000")
        XCTAssertEqual(second?.id, "20240905-123456-000-2")
        XCTAssertEqual(
            Set(try TranscriptHistoryReader(
                directory: directory,
                calendar: calendar
            ).all().map(\.id)),
            Set([try XCTUnwrap(first).id, try XCTUnwrap(second).id])
        )
    }

    func testHistorySearchAcceptsMultipleWordsAndTrailingOptions() throws {
        let parsed = try History.Search.parseAsRoot([
            "project", "roadmap", "--limit", "7",
        ])
        let command = try XCTUnwrap(parsed as? History.Search)

        XCTAssertEqual(command.query, ["project", "roadmap"])
        XCTAssertEqual(command.limit, 7)
    }

    func testOriginalHistoryFlagsParseForRecoveryCommands() throws {
        let show = try XCTUnwrap(
            try History.Show.parseAsRoot(["entry-id", "--original"]) as? History.Show
        )
        XCTAssertEqual(show.id, "entry-id")
        XCTAssertTrue(show.original)

        let last = try XCTUnwrap(
            try History.Last.parseAsRoot(["--original"]) as? History.Last
        )
        XCTAssertTrue(last.original)

        let copy = try XCTUnwrap(
            try History.Copy.parseAsRoot(["latest", "--original"]) as? History.Copy
        )
        XCTAssertTrue(copy.original)
    }

    func testHistoryPruneCommandDefaultsToPreviewAndValidatesDays() throws {
        let preview = try XCTUnwrap(
            try History.Prune.parseAsRoot(["--keep-days", "30"]) as? History.Prune
        )
        XCTAssertEqual(preview.keepDays, 30)
        XCTAssertFalse(preview.confirm)

        let confirmed = try XCTUnwrap(
            try History.Prune.parseAsRoot(["--keep-days", "7", "--confirm"])
                as? History.Prune
        )
        XCTAssertTrue(confirmed.confirm)
        XCTAssertThrowsError(try History.Prune.parseAsRoot(["--keep-days", "0"]))
        XCTAssertThrowsError(try History.Prune.parseAsRoot(["--keep-days", "3651"]))
    }

    func testRetentionPreviewAndPruneUseExactRollingCutoff() async throws {
        let root = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history", isDirectory: true)
        let calendar = utcCalendar()
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let now = try date(
            year: 2024, month: 9, day: 5, hour: 12, minute: 0,
            calendar: calendar
        )

        try await store.append(
            "old full day",
            at: try date(year: 2024, month: 9, day: 3, hour: 20, calendar: calendar)
        )
        try await store.append(
            "expired boundary entry",
            at: try date(year: 2024, month: 9, day: 4, hour: 11, calendar: calendar)
        )
        try await store.append(
            "retained boundary entry",
            at: try date(year: 2024, month: 9, day: 4, hour: 13, calendar: calendar)
        )
        try await store.append(
            "today",
            at: try date(year: 2024, month: 9, day: 5, hour: 9, calendar: calendar)
        )

        let unrelated = directory.appendingPathComponent("notes.md")
        try "user note".write(to: unrelated, atomically: true, encoding: .utf8)
        let dateShapedUnrelated = directory.appendingPathComponent("2024-09-02.md")
        try "# Personal daily note\n\nkeep me".write(
            to: dateShapedUnrelated,
            atomically: true,
            encoding: .utf8
        )
        let outside = root.appendingPathComponent("outside.md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let symlink = directory.appendingPathComponent("2024-09-01.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let policy = try HistoryRetentionPolicy(days: 1)
        let pruner = HistoryRetentionPruner(directory: directory, calendar: calendar)
        let preview = try pruner.preview(policy: policy, at: now)

        XCTAssertEqual(preview.entriesRemoved, 2)
        XCTAssertEqual(preview.filesAffected, 2)
        XCTAssertEqual(preview.filesDeleted, 1)
        XCTAssertEqual(preview.filesRewritten, 1)
        XCTAssertGreaterThan(preview.bytesRemoved, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("2024-09-03.md").path
        ))
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("2024-09-04.md"))
            .contains("expired boundary entry"))

        let applied = try pruner.prune(policy: policy, at: now)
        XCTAssertEqual(applied.entriesRemoved, preview.entriesRemoved)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("2024-09-03.md").path
        ))
        let records = try TranscriptHistoryReader(
            directory: directory,
            calendar: calendar
        ).all()
        XCTAssertEqual(Set(records.map(\.text)), ["retained boundary entry", "today"])
        XCTAssertEqual(try String(contentsOf: unrelated), "user note")
        XCTAssertEqual(
            try String(contentsOf: dateShapedUnrelated),
            "# Personal daily note\n\nkeep me"
        )
        XCTAssertEqual(try String(contentsOf: outside), "outside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertEqual(
            permissions(at: directory.appendingPathComponent("2024-09-04.md")),
            0o600
        )
        XCTAssertEqual(permissions(at: directory.appendingPathComponent(".history.lock")), 0o600)
    }

    func testRetentionDeletesEmptyBoundaryFileButPreservesLegacyBoundaryData() async throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let now = try date(
            year: 2024, month: 9, day: 5, hour: 12, calendar: calendar
        )
        let boundary = directory.appendingPathComponent("2024-09-04.md")
        try await store.append(
            "expired",
            at: try date(year: 2024, month: 9, day: 4, hour: 10, calendar: calendar)
        )

        let pruner = HistoryRetentionPruner(directory: directory, calendar: calendar)
        _ = try pruner.prune(policy: HistoryRetentionPolicy(days: 1), at: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: boundary.path))

        try """
        # Parrot transcripts — 2024-09-04

        ## 10:00:00

        legacy entry
        """.write(to: boundary, atomically: true, encoding: .utf8)
        let plan = try pruner.prune(policy: HistoryRetentionPolicy(days: 1), at: now)
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertTrue(try String(contentsOf: boundary).contains("legacy entry"))
    }

    func testActorRetentionCheckIsHourlyAndOptIn() async throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let now = try date(
            year: 2024, month: 9, day: 5, hour: 12, calendar: calendar
        )
        let forever = TranscriptHistory(directory: directory, calendar: calendar)
        let foreverResult = try await forever.pruneExpiredIfDue(at: now, force: true)
        XCTAssertNil(foreverResult)

        let retained = TranscriptHistory(
            directory: directory,
            calendar: calendar,
            retentionDays: 30
        )
        let first = try await retained.pruneExpiredIfDue(at: now, force: true)
        let throttled = try await retained.pruneExpiredIfDue(
            at: now.addingTimeInterval(3_599)
        )
        let due = try await retained.pruneExpiredIfDue(
            at: now.addingTimeInterval(3_600)
        )
        XCTAssertNotNil(first)
        XCTAssertNil(throttled)
        XCTAssertNotNil(due)
    }

    func testHistoryLockSerializesReadersAndCleanupWriters() throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let exclusiveAcquired = expectation(description: "exclusive lock acquired")
        let sharedFinished = expectation(description: "shared lock finished")
        let releaseExclusive = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var sharedEntered = false

        DispatchQueue.global().async {
            try! HistoryFileLock.withLock(directory: directory, mode: .exclusive) {
                exclusiveAcquired.fulfill()
                releaseExclusive.wait()
            }
        }
        wait(for: [exclusiveAcquired], timeout: 1)

        DispatchQueue.global().async {
            try! HistoryFileLock.withLock(directory: directory, mode: .shared) {
                stateLock.lock()
                sharedEntered = true
                stateLock.unlock()
            }
            sharedFinished.fulfill()
        }
        usleep(50_000)
        stateLock.lock()
        let enteredBeforeRelease = sharedEntered
        stateLock.unlock()
        XCTAssertFalse(enteredBeforeRelease)

        releaseExclusive.signal()
        wait(for: [sharedFinished], timeout: 1)
        stateLock.lock()
        let enteredAfterRelease = sharedEntered
        stateLock.unlock()
        XCTAssertTrue(enteredAfterRelease)
    }

    func testRetentionPreviewPerformanceAcrossTwoThousandEntries() throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var markdown = "# Parrot transcripts — 2024-09-04\n"
        for index in 0..<2_000 {
            let minute = index / 60
            let second = index % 60
            let time = String(format: "00:%02d:%02d", minute, second)
            let id = "20240904-\(time.replacingOccurrences(of: ":", with: ""))-000"
            markdown += "\n<!-- parrot-entry: \(id) -->\n## \(time)\n\nnote \(index)\n"
        }
        try markdown.write(
            to: directory.appendingPathComponent("2024-09-04.md"),
            atomically: true,
            encoding: .utf8
        )
        let calendar = utcCalendar()
        let now = try date(
            year: 2024, month: 9, day: 5, hour: 0, minute: 16, second: 40,
            calendar: calendar
        )
        let pruner = HistoryRetentionPruner(directory: directory, calendar: calendar)
        var plan: HistoryPrunePlan?
        measure {
            plan = try! pruner.preview(
                policy: HistoryRetentionPolicy(days: 1),
                at: now
            )
        }
        XCTAssertEqual(plan?.entriesRemoved, 1_000)
        XCTAssertEqual(plan?.filesRewritten, 1)
    }

    func testAppendsTranscriptsToPrivateDailyMarkdownFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024, month: 9, day: 4, hour: 20, minute: 38, second: 27
        )))

        let firstURL = try await store.append("first transcript", at: date)
        let secondURL = try await store.append("second transcript", at: date.addingTimeInterval(5))

        XCTAssertEqual(firstURL, secondURL)
        let url = try XCTUnwrap(firstURL)
        XCTAssertEqual(url.lastPathComponent, "2024-09-04.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(markdown, """
        # Parrot transcripts — 2024-09-04

        <!-- parrot-entry: 20240904-203827-000 -->
        ## 20:38:27

        first transcript

        <!-- parrot-entry: 20240904-203832-000 -->
        ## 20:38:32

        second transcript

        """)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testReadsSearchesAndResolvesMarkedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let first = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024, month: 9, day: 4, hour: 20, minute: 38, second: 27,
            nanosecond: 123_000_000
        )))
        try await store.append("RustPond planning\n\n## 12:34:56\n\nThis is note content.", at: first)
        try await store.append("Café follow-up with the design team", at: first.addingTimeInterval(5))

        let reader = TranscriptHistoryReader(directory: directory, calendar: calendar)
        let all = try reader.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].id, "20240904-203832-123")
        XCTAssertEqual(all[1].id, "20240904-203827-123")
        XCTAssertTrue(all[1].text.contains("## 12:34:56"))
        XCTAssertEqual(try reader.search("CAFE design", limit: 20).map(\.id), [all[0].id])
        XCTAssertEqual(try reader.resolve("203827-123")?.text, all[1].text)
        XCTAssertEqual(try reader.resolve("latest")?.id, all[0].id)
    }

    func testStoresAndReadsOptionalLocalTimingMetrics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024, month: 9, day: 4, hour: 20, minute: 38, second: 27
        )))
        let store = TranscriptHistory(directory: directory, calendar: calendar)

        let writtenURL = try await store.append(
            "timed transcript",
            at: date,
            audioDuration: 3.364,
            processingDuration: 0.084,
            enhancementDuration: 0.021,
            language: "Spanish",
            modelID: "whisper-base.en",
            mode: .notes
        )
        let url = try XCTUnwrap(writtenURL)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains(
            "<!-- parrot-metrics: audio-ms=3364 processing-ms=84 enhancement-ms=21 language=es "
                + "model=whisper-base.en mode=notes -->"
        ))

        let record = try XCTUnwrap(
            TranscriptHistoryReader(directory: directory, calendar: calendar).all().first
        )
        XCTAssertEqual(try XCTUnwrap(record.audioDuration), 3.364, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(record.processingDuration), 0.084, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(record.enhancementDuration), 0.021, accuracy: 0.0001)
        XCTAssertEqual(record.language, "es")
        XCTAssertEqual(record.modelID, "whisper-base.en")
        XCTAssertEqual(record.mode, .notes)
        XCTAssertEqual(record.text, "timed transcript")
    }

    func testRejectsUnsafeModelMetadataWithoutDroppingTranscript() async throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let instant = try date(
            year: 2024, month: 9, day: 5, hour: 12, calendar: calendar
        )

        _ = try await store.appendEntry(
            "safe note",
            at: instant,
            modelID: "bad -->\n## injected",
            mode: .dictation
        )

        let record = try XCTUnwrap(
            TranscriptHistoryReader(directory: directory, calendar: calendar).all().first
        )
        XCTAssertEqual(record.text, "safe note")
        XCTAssertNil(record.modelID)
        XCTAssertEqual(record.mode, .dictation)
    }

    func testStoresOriginalRecognitionHiddenAndSearchableOnlyWhenDifferent() async throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let date = try date(
            year: 2024, month: 9, day: 5, hour: 12, calendar: calendar
        )
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let original = "Um, private marker -->\nRust pond launch tomorrow."

        _ = try await store.appendEntry(
            "RustPond launch tomorrow.",
            at: date,
            originalText: original
        )
        _ = try await store.appendEntry(
            "unchanged recognition",
            at: date.addingTimeInterval(1),
            originalText: "unchanged recognition"
        )

        let url = TranscriptHistory.fileURL(
            for: date,
            directory: directory,
            calendar: calendar
        )
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(markdown.contains(original))
        XCTAssertEqual(markdown.components(separatedBy: "parrot-original-v1:").count - 1, 1)

        let reader = TranscriptHistoryReader(directory: directory, calendar: calendar)
        let records = try reader.all()
        let changed = try XCTUnwrap(records.first(where: { $0.text == "RustPond launch tomorrow." }))
        XCTAssertEqual(changed.originalText, original)
        let unchanged = try XCTUnwrap(records.first(where: { $0.text == "unchanged recognition" }))
        XCTAssertNil(unchanged.originalText)
        XCTAssertEqual(try reader.search("private marker", limit: 20).map(\.id), [changed.id])
    }

    func testMalformedOriginalMetadataCannotHideFinalTranscript() throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("2024-09-05.md")
        try """
        # Parrot transcripts — 2024-09-05

        <!-- parrot-entry: 20240905-120000-000 -->
        ## 12:00:00

        <!-- parrot-original-v1: definitely-not-base64! -->
        final text survives
        """.write(to: url, atomically: true, encoding: .utf8)

        let record = try XCTUnwrap(
            TranscriptHistoryReader(directory: directory, calendar: utcCalendar()).all().first
        )
        XCTAssertEqual(record.text, "final text survives")
        XCTAssertNil(record.originalText)
    }

    func testReadsOriginalMetadataFromCRLFHistory() throws {
        let directory = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("2024-09-05.md")
        let original = "recognized before cleanup"
        let metadata = try XCTUnwrap(
            OriginalTranscriptMetadata.line(originalText: original, finalText: "cleaned text")
        )
        let markdown = [
            "# Parrot transcripts — 2024-09-05",
            "",
            "<!-- parrot-entry: 20240905-120000-000 -->",
            "## 12:00:00",
            "",
            metadata,
            "cleaned text",
            ""
        ].joined(separator: "\r\n")
        try markdown.write(to: url, atomically: true, encoding: .utf8)

        let record = try XCTUnwrap(
            TranscriptHistoryReader(directory: directory, calendar: utcCalendar()).all().first
        )
        XCTAssertEqual(record.text, "cleaned text")
        XCTAssertEqual(record.originalText, original)
    }

    func testOriginalMetadataRoundTripCostIsBounded() {
        let original = String(repeating: "A long recognized note. ", count: 1_000)
        let final = "processed note"
        var decoded: String?

        measure {
            for _ in 0..<100 {
                let line = OriginalTranscriptMetadata.line(
                    originalText: original,
                    finalText: final
                )!
                decoded = OriginalTranscriptMetadata.extract(
                    from: line + "\n" + final
                ).originalText
            }
        }
        XCTAssertEqual(decoded, original.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testReadsLegacyHistoryAndDisambiguatesSameSecond() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("2024-09-04.md")
        try """
        # Parrot transcripts — 2024-09-04

        ## 20:38:27

        first

        ## 20:38:27

        second
        """.write(to: url, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let records = try TranscriptHistoryReader(directory: directory, calendar: calendar).all()

        XCTAssertEqual(Set(records.map(\.id)), ["20240904-203827", "20240904-203827-2"])
        XCTAssertEqual(Set(records.map(\.text)), ["first", "second"])
    }

    func testLocalSearchPerformanceAcrossTwoThousandEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var markdown = "# Parrot transcripts — 2024-09-04\n"
        for index in 0..<2_000 {
            let hour = index / 3_600
            let minute = (index % 3_600) / 60
            let second = index % 60
            let time = String(format: "%02d:%02d:%02d", hour, minute, second)
            let id = "20240904-\(time.replacingOccurrences(of: ":", with: ""))-000"
            let searchable = index == 1_337 ? "needle project roadmap" : "ordinary local note"
            markdown += "\n<!-- parrot-entry: \(id) -->\n## \(time)\n\n\(searchable) \(index)\n"
        }
        try markdown.write(
            to: directory.appendingPathComponent("2024-09-04.md"),
            atomically: true,
            encoding: .utf8
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reader = TranscriptHistoryReader(directory: directory, calendar: calendar)
        var matches: [TranscriptRecord] = []
        measure {
            matches = try! reader.search("project roadmap", limit: 20)
        }
        XCTAssertEqual(matches.map(\.text), ["needle project roadmap 1337"])
    }

    func testDoesNotCreateAFileForEmptyTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TranscriptHistory(directory: directory)
        let result = try await store.append("  \n ")

        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAppendRefusesDailySymlinkWithoutChangingItsTarget() async throws {
        let root = temporaryHistoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let calendar = utcCalendar()
        let recordedAt = try date(
            year: 2024, month: 9, day: 5, hour: 12, calendar: calendar
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("2024-09-05.md"),
            withDestinationURL: outside
        )

        let store = TranscriptHistory(directory: directory, calendar: calendar)
        do {
            _ = try await store.append("must not escape history", at: recordedAt)
            XCTFail("append should reject a daily symlink")
        } catch let error as TranscriptHistory.HistoryError {
            guard case .unsafeDailyFile = error else {
                return XCTFail("unexpected history error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: outside), "outside")
    }

    private func temporaryHistoryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-retention-tests-\(UUID().uuidString)")
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        second: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}
