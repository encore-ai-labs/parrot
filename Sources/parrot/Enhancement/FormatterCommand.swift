import ArgumentParser
import Foundation

struct FormatterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "formatter",
        abstract: "Manage Parrot's optional lightweight local smart formatter.",
        subcommands: [Status.self, Install.self, On.self, Off.self, Remove.self, Test.self],
        defaultSubcommand: Status.self
    )

    struct Status: ParsableCommand {
        func run() {
            let model = FormatterModel.recommended
            let config = Config.load()
            let installed = FormatterModelStorage.default.isInstalled(model)
            let enabled = config.enhancementModel == model.id
            print("formatter  \(enabled ? "on" : "off")")
            print("model      \(model.displayName)")
            print(
                "download   \(installed ? "installed" : "not installed")"
                    + " · ~\(model.approximateSizeMB) MB"
                    + " + \(FormatterRuntime.recommended.approximateSizeMB) MB runtime"
            )
            print("privacy    fully local · no cloud/API key · runtime stops with Parrot")
            if !installed {
                print("\ninstall and enable with: parrot formatter install")
            } else if !enabled {
                print("\nenable with: parrot formatter on")
            }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download, verify-load, and enable the recommended local formatter."
        )

        @Flag(name: .customLong("download-only"), help: "Download and verify without enabling.")
        var downloadOnly = false

        func run() throws {
            let model = FormatterModel.recommended
            let totalSize = model.approximateSizeMB
                + FormatterRuntime.recommended.approximateSizeMB
            FileHandle.standardError.write(Data(
                "→ preparing \(model.displayName) · ~\(totalSize) MB total…\n".utf8
            ))
            let enhancer = LocalModelTextEnhancer(model: model)
            let progress = ModelDownloadProgress()
            try waitForAsync {
                try await enhancer.install(progress: progress)
            }
            if downloadOnly {
                print("✓ local smart formatter downloaded and verified")
            } else {
                var config = Config.load()
                config.enhancementModel = model.id
                config.enhancementCommand = nil
                try config.write()
                print("✓ local smart formatting is installed and enabled")
                print("restart a running Parrot daemon to apply the change")
            }
        }
    }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Enable an already-downloaded local formatter."
        )

        func run() throws {
            let model = FormatterModel.recommended
            guard FormatterModelStorage.default.isInstalled(model) else {
                throw ValidationError("formatter is not installed; run `parrot formatter install`")
            }
            var config = Config.load()
            config.enhancementModel = model.id
            config.enhancementCommand = nil
            try config.write()
            print("✓ local smart formatting enabled")
            print("restart a running Parrot daemon to apply the change")
        }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Disable enhancement without deleting its local model."
        )

        func run() throws {
            var config = Config.load()
            config.enhancementModel = nil
            config.enhancementCommand = nil
            try config.write()
            print("✓ smart formatting disabled; downloaded files were kept")
            print("restart a running Parrot daemon to apply the change")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Disable and delete the Parrot-managed formatter model."
        )

        func run() throws {
            let daemonLock: DaemonLock
            do {
                daemonLock = try DaemonLock.acquire()
            } catch DaemonLock.LockError.alreadyRunning {
                throw ValidationError("stop the running Parrot daemon before removing the formatter")
            }
            defer { daemonLock.release() }

            var config = Config.load()
            config.enhancementModel = nil
            config.enhancementCommand = nil
            try config.write()
            let bytes = try FormatterModelStorage.default.remove(.recommended)
            if bytes == 0 {
                print("formatter was not installed; smart formatting is off")
            } else {
                let reclaimed = ByteCountFormatter.string(
                    fromByteCount: bytes,
                    countStyle: .file
                )
                print("✓ removed local formatter · reclaimed \(reclaimed)")
            }
        }
    }

    struct Test: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run one transcript through the installed formatter without saving it."
        )

        @Argument(help: "Transcript text to format.")
        var text: String

        @Flag(name: .long, help: "Use note-formatting instructions.")
        var notes = false

        func run() throws {
            let model = FormatterModel.recommended
            guard FormatterModelStorage.default.isInstalled(model) else {
                throw ValidationError("formatter is not installed; run `parrot formatter install`")
            }
            let enhancer = LocalModelTextEnhancer(model: model)
            let started = ProcessInfo.processInfo.systemUptime
            let output: String = try waitForAsync {
                try await enhancer.warmUp()
                return try await enhancer.enhance(text, mode: notes ? .notes : .dictation)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            print(output)
            FileHandle.standardError.write(Data(String(
                format: "\n✦ formatted locally in %.2fs\n",
                elapsed
            ).utf8))
        }
    }
}

private final class AsyncResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

func waitForAsync<Value>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let box = AsyncResultBox<Value>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { semaphore.signal() }
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
    }
    semaphore.wait()
    return try box.load()!.get()
}
