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
        // Component-wise numeric compare so "1" == "1.0" and "1.10" > "1.9".
        func components(_ version: String) -> [Int] {
            version.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
