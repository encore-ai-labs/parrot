import Darwin
import Foundation

/// The macOS action attached to a bare Fn/Globe key press lives outside the
/// CGEvent stream we monitor. `TISUpdateFnUsageType` is the live HIToolbox path
/// used by System Settings; changing the plist alone leaves the running system
/// action cached and can still open Emoji & Symbols on a later isolated tap.
final class FnSystemActionOverride {
    enum State: Equatable {
        case alreadyDisabled
        case disabledForParrot
    }

    enum PreferenceError: LocalizedError {
        case liveAPIUnavailable
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .liveAPIUnavailable:
                return "the live macOS Fn/Globe settings API is unavailable"
            case .verificationFailed:
                return "macOS did not apply the Fn/Globe key setting"
            }
        }
    }

    let state: State

    private let store: FnSystemActionPreferenceStoring
    private let originalValue: Int
    private var restored = false

    init(store: FnSystemActionPreferenceStoring = SystemFnSystemActionPreferences()) throws {
        self.store = store
        originalValue = try store.read()

        if originalValue == 0 {
            state = .alreadyDisabled
            return
        }

        try store.write(0)
        guard try store.read() == 0 else {
            throw PreferenceError.verificationFailed
        }
        state = .disabledForParrot
    }

    /// Restore the user's prior effective choice. This is idempotent because
    /// shutdown can be requested from more than one source.
    func restore() throws {
        guard state == .disabledForParrot, !restored else { return }
        try store.write(originalValue)
        guard try store.read() == originalValue else {
            throw PreferenceError.verificationFailed
        }
        restored = true
    }
}

protocol FnSystemActionPreferenceStoring: AnyObject {
    func read() throws -> Int
    func write(_ value: Int) throws
}

/// Dynamically resolve the HIToolbox functions so Parrot does not acquire a
/// hard link-time dependency on undocumented symbols. These functions have
/// existed throughout Parrot's supported macOS range, and are the functions
/// the macOS Keyboard Settings extension itself calls for this exact control.
final class SystemFnSystemActionPreferences: FnSystemActionPreferenceStoring {
    private typealias GetFnUsageType = @convention(c) () -> UInt32
    private typealias UpdateFnUsageType = @convention(c) (UInt32) -> Void

    private static let frameworkPath =
        "/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/" +
        "HIToolbox.framework/Versions/A/HIToolbox"

    private let framework: UnsafeMutableRawPointer?
    private let getFnUsageType: GetFnUsageType?
    private let updateFnUsageType: UpdateFnUsageType?

    init() {
        framework = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL)
        if let framework,
           let getSymbol = dlsym(framework, "TISGetFnUsageType"),
           let updateSymbol = dlsym(framework, "TISUpdateFnUsageType") {
            getFnUsageType = unsafeBitCast(getSymbol, to: GetFnUsageType.self)
            updateFnUsageType = unsafeBitCast(updateSymbol, to: UpdateFnUsageType.self)
        } else {
            getFnUsageType = nil
            updateFnUsageType = nil
        }
    }

    deinit {
        if let framework { dlclose(framework) }
    }

    func read() throws -> Int {
        guard let getFnUsageType else {
            throw FnSystemActionOverride.PreferenceError.liveAPIUnavailable
        }
        return Int(getFnUsageType())
    }

    func write(_ value: Int) throws {
        guard let updateFnUsageType, value >= 0, value <= Int(UInt32.max) else {
            throw FnSystemActionOverride.PreferenceError.liveAPIUnavailable
        }
        updateFnUsageType(UInt32(value))
    }
}
