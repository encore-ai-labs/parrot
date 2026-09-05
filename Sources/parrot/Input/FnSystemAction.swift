import CoreFoundation
import Foundation

/// The macOS action attached to a bare Fn/Globe key press lives outside the
/// event stream we monitor. Temporarily setting it to `0` (Do Nothing) keeps
/// macOS from opening Emoji & Symbols, changing input source, or starting its
/// own dictation while Parrot owns Fn.
final class FnSystemActionOverride {
    enum State: Equatable {
        case alreadyDisabled
        case disabledForParrot
    }

    enum PreferenceError: LocalizedError {
        case writeFailed
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .writeFailed:
                return "macOS did not save the Fn/Globe key setting"
            case .verificationFailed:
                return "macOS did not apply the Fn/Globe key setting"
            }
        }
    }

    let state: State

    private let store: FnSystemActionPreferenceStoring
    private let originalValue: Int?
    private var restored = false

    init(store: FnSystemActionPreferenceStoring = SystemFnSystemActionPreferences()) throws {
        self.store = store
        originalValue = store.read()

        if originalValue == 0 {
            state = .alreadyDisabled
            return
        }

        try store.write(0)
        guard store.read() == 0 else {
            throw PreferenceError.verificationFailed
        }
        state = .disabledForParrot
    }

    /// Restore the exact prior choice, including an unset preference. This is
    /// idempotent because shutdown can be requested from more than one source.
    func restore() throws {
        guard state == .disabledForParrot, !restored else { return }
        try store.write(originalValue)
        guard store.read() == originalValue else {
            throw PreferenceError.verificationFailed
        }
        restored = true
    }
}

protocol FnSystemActionPreferenceStoring: AnyObject {
    func read() -> Int?
    func write(_ value: Int?) throws
}

final class SystemFnSystemActionPreferences: FnSystemActionPreferenceStoring {
    private let key = "AppleFnUsageType" as CFString
    private let domain = "com.apple.HIToolbox" as CFString

    func read() -> Int? {
        guard let value = CFPreferencesCopyValue(
            key,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    func write(_ value: Int?) throws {
        let preferenceValue: CFPropertyList? = value.map { NSNumber(value: $0) }
        CFPreferencesSetValue(
            key,
            preferenceValue,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else {
            throw FnSystemActionOverride.PreferenceError.writeFailed
        }
    }
}
