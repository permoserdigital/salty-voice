import Foundation

/// Checks the GitHub releases feed for a newer version.
/// No auto-install -- it only surfaces a hint that links to the download page.
enum UpdateCheckService {
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/permoserdigital/salty-voice/releases/latest"
    )!
    static let releasesPageURL = URL(
        string: "https://github.com/permoserdigital/salty-voice/releases/latest"
    )!

    private struct Release: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Returns the newer version string if one is available, else nil.
    static func checkForUpdate() async -> String? {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return nil
        }

        var latest = release.tagName
        if latest.hasPrefix("v") { latest.removeFirst() }
        return isVersion(latest, newerThan: currentVersion) ? latest : nil
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}
