import Foundation

struct TranscriptionHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let text: String
    let workflowType: WorkflowType
    let date: Date
}

/// Keeps the last transcriptions in a local JSON file
/// (~/Library/Application Support/Blitztext/history.json). Local only --
/// nothing ever leaves the Mac.
enum TranscriptionHistoryService {
    static let maxEntries = 50

    private static var historyURL: URL {
        AppSupportPaths.appSupportDirectoryURL.appendingPathComponent("history.json")
    }

    static func load() -> [TranscriptionHistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL),
              let entries = try? JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Prepends the entry (newest first) and returns the updated list.
    static func append(text: String, workflowType: WorkflowType) -> [TranscriptionHistoryEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }

        var entries = load()
        entries.insert(
            TranscriptionHistoryEntry(text: trimmed, workflowType: workflowType, date: Date()),
            at: 0
        )
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save(entries)
        return entries
    }

    static func clear() {
        try? FileManager.default.removeItem(at: historyURL)
    }

    private static func save(_ entries: [TranscriptionHistoryEntry]) {
        try? AppSupportPaths.ensureAppSupportDirectoryExists()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: historyURL, options: [.atomic])
        }
    }
}
