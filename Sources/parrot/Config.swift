import Foundation

/// Settings that persist between runs, at `~/.config/parrot/config.json`.
///
/// JSON rather than the TOML the original design called for: Codable gives it
/// to us for free, and pulling in a TOML parser to store three keys wasn't
/// worth a dependency.
///
/// Every field is optional and means "not yet decided" when nil — that's what
/// distinguishes a first run (ask the user) from a later one (respect that they
/// already chose, including choosing "no").
struct Config: Codable {
    /// Lowercase everything before injecting it.
    var lowercase: Bool?
    /// CoreAudio UID of the last microphone chosen, used to preselect it.
    var inputDeviceUID: String?
    /// Set once first-run setup completes, so we don't re-ask every launch.
    var setupCompleted: Bool?

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parrot", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("config.json") }

    /// Missing or unreadable config is not an error — it's a first run.
    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return decoded
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: Self.directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.url, options: .atomic)
        } catch {
            // Losing a preference is not worth failing a launch over.
            FileHandle.standardError.write(Data(
                "warning: couldn't save config to \(Self.url.path): \(error)\n".utf8
            ))
        }
    }
}
