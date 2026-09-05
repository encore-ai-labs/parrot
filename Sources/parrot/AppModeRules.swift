import Foundation

struct AppModeRule: Codable, Equatable {
    let bundleIdentifier: String
    let applicationName: String?
    let mode: DictationMode

    func matches(bundleIdentifier candidate: String) -> Bool {
        bundleIdentifier.caseInsensitiveCompare(candidate) == .orderedSame
    }
}

struct AppModeSelection: Equatable {
    let mode: DictationMode
    let automaticApplicationName: String?

    var isAutomatic: Bool { automaticApplicationName != nil }
}

/// A dedicated note shortcut has explicit per-capture precedence over app
/// rules and the fallback mode. The primary selection stays lazy so hitting
/// the note key does not inspect or retain the frontmost application at all.
enum HotkeyModeRouter {
    enum DeliveryRoute: Equatable {
        case primary
        case noteJournal
    }

    static func selection(
        source: String,
        noteHotkeyName: String?,
        primarySelection: () -> AppModeSelection
    ) -> AppModeSelection {
        guard source != noteHotkeyName else {
            return AppModeSelection(mode: .notes, automaticApplicationName: nil)
        }
        return primarySelection()
    }

    static func deliveryRoute(
        source: String,
        noteHotkeyName: String?,
        hasNoteJournal: Bool
    ) -> DeliveryRoute {
        source == noteHotkeyName && hasNoteJournal ? .noteJournal : .primary
    }
}

/// Small in-memory policy object used on the main event-tap path. It performs
/// no I/O and never retains or records the active application identifier.
final class DictationModeController {
    private(set) var fallbackMode: DictationMode
    private var rules: [AppModeRule]
    private let automaticRulesEnabled: Bool
    private let configURL: URL?
    private var configSignature: ConfigFileSignature?

    init(
        fallbackMode: DictationMode,
        rules: [AppModeRule],
        automaticRulesEnabled: Bool = true,
        reloadRulesFrom configURL: URL? = nil
    ) {
        self.fallbackMode = fallbackMode
        self.rules = rules
        self.automaticRulesEnabled = automaticRulesEnabled
        self.configURL = configURL
        configSignature = configURL.flatMap(Self.signature)
    }

    func setFallbackMode(_ mode: DictationMode) {
        fallbackMode = mode
    }

    func selection(frontmostBundleIdentifier: String?) -> AppModeSelection {
        reloadRulesIfNeeded()
        guard automaticRulesEnabled,
              let bundleIdentifier = frontmostBundleIdentifier,
              let rule = rules.last(where: { $0.matches(bundleIdentifier: bundleIdentifier) })
        else {
            return AppModeSelection(mode: fallbackMode, automaticApplicationName: nil)
        }
        return AppModeSelection(
            mode: rule.mode,
            automaticApplicationName: rule.applicationName ?? rule.bundleIdentifier
        )
    }

    private func reloadRulesIfNeeded() {
        guard let configURL else { return }
        let currentSignature = Self.signature(configURL)
        guard currentSignature != configSignature else { return }
        rules = Config.load(from: configURL).savedAppRules
        configSignature = currentSignature
    }

    private static func signature(_ url: URL) -> ConfigFileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return ConfigFileSignature(
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

private struct ConfigFileSignature: Equatable {
    let modificationDate: Date?
    let size: UInt64?
    let fileNumber: UInt64?
}

extension Config {
    var savedAppRules: [AppModeRule] { appRules ?? [] }

    mutating func setAppRule(_ rule: AppModeRule) {
        var rules = savedAppRules.filter {
            !$0.matches(bundleIdentifier: rule.bundleIdentifier)
        }
        rules.append(rule)
        appRules = rules.sorted {
            $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier)
                == .orderedAscending
        }
    }

    mutating func removeAppRule(matching query: String) -> AppModeRule? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = savedAppRules.firstIndex(where: { rule in
            rule.bundleIdentifier.caseInsensitiveCompare(normalized) == .orderedSame
                || rule.applicationName?.caseInsensitiveCompare(normalized) == .orderedSame
        }) else { return nil }
        var rules = savedAppRules
        let removed = rules.remove(at: index)
        appRules = rules.isEmpty ? nil : rules
        return removed
    }
}
