import Foundation

struct NoteTemplateRenderer: @unchecked Sendable {
    struct Selection: Equatable, Sendable {
        let text: String
        let templateName: String?
        let wasTriggered: Bool
    }

    private let library: NoteTemplateLibrary
    private let triggerRegex: NSRegularExpression?
    private let literalRegex: NSRegularExpression?

    init(library: NoteTemplateLibrary = NoteTemplateLibrary()) {
        self.library = library
        let alternatives = library.entries
            .sorted { $0.name.count > $1.name.count }
            .map { entry in
                entry.name
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .map(NSRegularExpression.escapedPattern(for:))
                    .joined(separator: #"[ \t\r\n]+"#)
            }
            .joined(separator: "|")
        guard !alternatives.isEmpty else {
            triggerRegex = nil
            literalRegex = nil
            return
        }
        let separator = #"(?:[ \t\r\n]*[,:;.!?][ \t\r\n]*|[ \t\r\n]+|\z)"#
        triggerRegex = try? NSRegularExpression(
            pattern: #"\A[ \t\r\n]*template[ \t\r\n]+("#
                + alternatives + ")" + separator,
            options: .caseInsensitive
        )
        literalRegex = try? NSRegularExpression(
            pattern: #"\A[ \t\r\n]*literal[ \t\r\n]+(?=template[ \t\r\n]+(?:"#
                + alternatives + ")" + separator + ")",
            options: .caseInsensitive
        )
    }

    var count: Int { library.entries.count }

    func contains(_ name: String) -> Bool {
        library.entry(matching: name) != nil
    }

    func resolve(_ text: String) -> Selection {
        guard !text.isEmpty, let triggerRegex else {
            return Selection(text: text, templateName: nil, wasTriggered: false)
        }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        if let literal = literalRegex?.firstMatch(in: text, range: fullRange) {
            return Selection(
                text: source.substring(from: NSMaxRange(literal.range)),
                templateName: nil,
                wasTriggered: false
            )
        }
        guard let match = triggerRegex.firstMatch(in: text, range: fullRange),
              let entry = library.entry(matching: source.substring(with: match.range(at: 1)))
        else {
            return Selection(text: text, templateName: nil, wasTriggered: false)
        }
        return Selection(
            text: source.substring(from: NSMaxRange(match.range)),
            templateName: entry.name,
            wasTriggered: true
        )
    }

    func render(
        _ transcript: String,
        templateName: String?,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let templateName,
              let entry = library.entry(matching: templateName)
        else { return text }

        let values = Self.dateValues(date, calendar: calendar)
        return entry.body
            .replacingOccurrences(of: "{{transcript}}", with: text)
            .replacingOccurrences(of: "{{datetime}}", with: values.datetime)
            .replacingOccurrences(of: "{{date}}", with: values.date)
            .replacingOccurrences(of: "{{time}}", with: values.time)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dateValues(
        _ date: Date,
        calendar: Calendar
    ) -> (date: String, time: String, datetime: String) {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let dateText = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        let timeText = String(
            format: "%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0
        )
        let seconds = String(format: "%02d", components.second ?? 0)
        let offsetSeconds = calendar.timeZone.secondsFromGMT(for: date)
        let offsetSign = offsetSeconds < 0 ? "-" : "+"
        let absoluteOffset = abs(offsetSeconds)
        let offsetHours = absoluteOffset / 3_600
        let offsetMinutes = (absoluteOffset % 3_600) / 60
        let offset = String(format: "%@%02d:%02d", offsetSign, offsetHours, offsetMinutes)
        return (dateText, timeText, "\(dateText)T\(timeText):\(seconds)\(offset)")
    }
}
