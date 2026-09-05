import Foundation

enum AppVersion {
    // Release builds replace this value with their v* tag in release.yml.
    // Development builds deliberately do not pretend to be a published version.
    static let current = "development"
}

struct AvailableUpdate: Equatable {
    let version: String
    let releaseURL: URL
}

enum UpdateChecker {
    static let updateCommand =
        "curl -fsSL https://raw.githubusercontent.com/encore-ai-labs/parrot/master/scripts/install.sh | sh"

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/encore-ai-labs/parrot/releases/latest"
    )!

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Check once for each daemon launch. This is intentionally asynchronous:
    /// no network condition should delay or prevent dictation from starting.
    /// Failures are silent because an unavailable update service is not an app
    /// error and will naturally be retried on the next launch.
    static func check(completion: @escaping (AvailableUpdate) -> Void) {
        guard AppVersion.current != "development" else { return }

        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 4)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("parrot/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let data,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  isNewer(release.tagName, than: AppVersion.current)
            else { return }

            completion(AvailableUpdate(version: release.tagName, releaseURL: release.htmlURL))
        }.resume()
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = numericVersion(candidate),
              let current = numericVersion(current)
        else { return false }

        let count = max(candidate.count, current.count)
        for index in 0..<count {
            let candidatePart = index < candidate.count ? candidate[index] : 0
            let currentPart = index < current.count ? current[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    private static func numericVersion(_ raw: String) -> [Int]? {
        var version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.first == "v" || version.first == "V" {
            version.removeFirst()
        }
        // GitHub's latest endpoint returns stable releases, but ignoring build
        // and prerelease suffixes keeps comparison predictable if tags contain one.
        version = String(version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? "")
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }
}
