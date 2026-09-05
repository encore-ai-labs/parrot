import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let modelLabel: NSMenuItem
    private let stateLabel: NSMenuItem
    private let modeLabel: NSMenuItem
    private let dictationModeItem: NSMenuItem
    private let notesModeItem: NSMenuItem
    private let retryRecordingItem: NSMenuItem
    private let forgetRecordingItem: NSMenuItem
    private let updateLabel: NSMenuItem
    private let modelID: String
    private let idleTitle: String
    private var updateAction: (() -> Void)?
    private var modeAction: ((DictationMode) -> Void)?
    private var retryRecordingAction: (() -> Void)?
    private var forgetRecordingAction: (() -> Void)?
    private var recordingRecoveryAvailable = false
    private var recordingRecoveryBusy = false

    init(
        modelID: String,
        language: String,
        hotkeyName: String,
        noteHotkeyName: String?,
        mode: DictationMode,
        onModeChange: @escaping (DictationMode) -> Void
    ) {
        self.modelID = modelID
        self.idleTitle = noteHotkeyName.map {
            "idle · \(hotkeyName) · notes: \($0)"
        } ?? "idle · hold or double-tap \(hotkeyName)"
        self.modeAction = onModeChange
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: idleTitle, action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        modelLabel = NSMenuItem(
            title: "model: \(modelID) · \(language)",
            action: nil,
            keyEquivalent: ""
        )
        modelLabel.isEnabled = false
        menu.addItem(modelLabel)

        updateLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        modeLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        modeLabel.isEnabled = true
        dictationModeItem = NSMenuItem(
            title: "Dictation",
            action: #selector(dictationModeClicked),
            keyEquivalent: ""
        )
        notesModeItem = NSMenuItem(
            title: "Notes",
            action: #selector(notesModeClicked),
            keyEquivalent: ""
        )
        retryRecordingItem = NSMenuItem(
            title: "Retry Last Recording",
            action: #selector(retryRecordingClicked),
            keyEquivalent: ""
        )
        forgetRecordingItem = NSMenuItem(
            title: "Forget Last Recording",
            action: #selector(forgetRecordingClicked),
            keyEquivalent: ""
        )
        dictationModeItem.target = self
        notesModeItem.target = self
        dictationModeItem.isEnabled = true
        notesModeItem.isEnabled = true
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        modeMenu.addItem(dictationModeItem)
        modeMenu.addItem(notesModeItem)
        modeLabel.submenu = modeMenu
        menu.addItem(modeLabel)

        retryRecordingItem.target = self
        forgetRecordingItem.target = self
        retryRecordingItem.isEnabled = false
        forgetRecordingItem.isEnabled = false
        menu.addItem(retryRecordingItem)
        menu.addItem(forgetRecordingItem)

        updateLabel.isEnabled = false
        updateLabel.isHidden = true
        menu.addItem(updateLabel)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        setMode(mode)
        configureButton(recording: false)
    }

    func setRecording(_ recording: Bool) {
        stateLabel.title = recording ? "● recording" : idleTitle
    }

    func setTranscribing() {
        stateLabel.title = "transcribing…"
    }

    func setRecordingRecovery(
        available: Bool,
        restored: Bool = false,
        retry: (() -> Void)? = nil,
        forget: (() -> Void)? = nil
    ) {
        if let retry { retryRecordingAction = retry }
        if let forget { forgetRecordingAction = forget }
        recordingRecoveryAvailable = available
        retryRecordingItem.title = restored
            ? "Retry Recovered Recording"
            : "Retry Last Recording"
        updateRecordingRecoveryItems()
    }

    func setRecordingRecoveryBusy(_ busy: Bool) {
        recordingRecoveryBusy = busy
        updateRecordingRecoveryItems()
    }

    private func updateRecordingRecoveryItems() {
        retryRecordingItem.isEnabled = recordingRecoveryAvailable
            && !recordingRecoveryBusy
            && retryRecordingAction != nil
        forgetRecordingItem.isEnabled = recordingRecoveryAvailable
            && !recordingRecoveryBusy
            && forgetRecordingAction != nil
    }

    func setMode(_ mode: DictationMode, automaticApplicationName: String? = nil) {
        if let applicationName = automaticApplicationName {
            modeLabel.title = "mode: \(mode.rawValue) · \(applicationName) (automatic)"
            modeLabel.toolTip = "An app rule controls this mode until focus changes."
            dictationModeItem.isEnabled = false
            notesModeItem.isEnabled = false
        } else {
            modeLabel.title = "mode: \(mode.rawValue)"
            modeLabel.toolTip = nil
            dictationModeItem.isEnabled = true
            notesModeItem.isEnabled = true
        }
        dictationModeItem.state = mode == .dictation ? .on : .off
        notesModeItem.state = mode == .notes ? .on : .off
    }

    func setUpdateAvailable(_ version: String, action: @escaping () -> Void) {
        updateAction = action
        updateLabel.title = "Update Parrot to \(version)…"
        updateLabel.target = self
        updateLabel.action = #selector(updateClicked)
        updateLabel.isEnabled = true
        updateLabel.isHidden = false
    }

    func setUpdating(_ version: String) {
        updateLabel.title = "Updating to \(version)…"
        updateLabel.isEnabled = false
    }

    func setUpdateFailed(_ version: String) {
        updateLabel.title = "Update failed · try Parrot \(version) again…"
        updateLabel.isEnabled = true
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func updateClicked() {
        updateAction?()
    }

    @objc private func dictationModeClicked() {
        modeAction?(.dictation)
        setMode(.dictation)
    }

    @objc private func notesModeClicked() {
        modeAction?(.notes)
        setMode(.notes)
    }

    @objc private func retryRecordingClicked() {
        retryRecordingAction?()
    }

    @objc private func forgetRecordingClicked() {
        forgetRecordingAction?()
    }
}
