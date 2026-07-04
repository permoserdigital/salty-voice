import Foundation

/// Talks to the team vocabulary endpoint on the SALTY Voice team server.
///
/// API contract (implemented by the SALTYBRANDS platform):
///   GET  {base}/api/voice/team-words?code={teamCode}
///        -> 200 {"words": ["Salty Brands", ...]}
///   POST {base}/api/voice/team-words  body: {"code": "...", "word": "..."}
///        -> 200 {"words": [...updated list...]}
///   401/403 on wrong team code.
enum TeamVocabularyService {
    struct WordsResponse: Codable {
        let words: [String]
    }

    enum TeamVocabularyError: LocalizedError {
        case invalidURL
        case unauthorized
        case serverError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Die Team-Server-URL ist ungültig."
            case .unauthorized:
                return "Team-Code wurde vom Server abgelehnt."
            case .serverError(let status):
                return "Team-Server antwortete mit Status \(status)."
            }
        }
    }

    static func apiURL(serverURL: String, path: String) throws -> URL {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw TeamVocabularyError.invalidURL }
        if !base.lowercased().hasPrefix("http") {
            base = "https://" + base
        }
        guard let url = URL(string: base + path) else {
            throw TeamVocabularyError.invalidURL
        }
        return url
    }

    private static func endpoint(serverURL: String) throws -> URL {
        try apiURL(serverURL: serverURL, path: "/api/voice/team-words")
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403, 404:
            throw TeamVocabularyError.unauthorized
        default:
            throw TeamVocabularyError.serverError(http.statusCode)
        }
    }

    static func fetchWords(serverURL: String, teamCode: String) async throws -> [String] {
        var components = URLComponents(
            url: try endpoint(serverURL: serverURL),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "code", value: teamCode)]
        guard let url = components?.url else { throw TeamVocabularyError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(WordsResponse.self, from: data).words
    }

    // MARK: - Team proxy configuration

    /// Reads the team server configuration straight from the persisted
    /// settings file so static services (transcription, LLM) can use the
    /// team proxy without holding a reference to AppState.
    static func teamProxyConfiguration() -> (serverURL: String, code: String)? {
        struct SettingsPeek: Decodable {
            struct App: Decodable {
                var teamServerURL: String?
                var teamCode: String?
            }
            var app: App?
        }

        guard let data = try? Data(contentsOf: AppSupportPaths.settingsURL),
              let peek = try? JSONDecoder().decode(SettingsPeek.self, from: data),
              let serverURL = peek.app?.teamServerURL?.trimmingCharacters(in: .whitespaces),
              let code = peek.app?.teamCode?.trimmingCharacters(in: .whitespaces),
              !serverURL.isEmpty, !code.isEmpty else {
            return nil
        }
        return (serverURL, code)
    }

    static func addWord(serverURL: String, teamCode: String, word: String) async throws -> [String] {
        var request = URLRequest(url: try endpoint(serverURL: serverURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(["code": teamCode, "word": word])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(WordsResponse.self, from: data).words
    }
}
