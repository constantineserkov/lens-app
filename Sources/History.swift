import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let number: Int
    let createdAt: Date
    let answer: Answer
    let model: String
    let reasoning: String
    let batch: BatchAnswer?

    var title: String {
        if let batch { return "Подборка · \(batch.taskCountText)" }
        let compact = answer.task.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return compact.isEmpty ? "Без названия" : String(compact.prefix(72)) + (compact.count > 72 ? "…" : "")
    }
}

/// Writes the new complete archive atomically; an unreadable archive is never replaced.
final class HistoryStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("history.json") }
    private(set) var entries: [HistoryEntry] = []
    private var loaded = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lens", isDirectory: true)
    }

    @discardableResult func load() throws -> [HistoryEntry] {
        if FileManager.default.fileExists(atPath: file.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([HistoryEntry].self, from: Data(contentsOf: file))
            guard Set(decoded.map(\.id)).count == decoded.count,
                  Set(decoded.map(\.number)).count == decoded.count,
                  decoded.allSatisfy({ $0.number > 0 }) else {
                throw LensError.message("Не удалось прочитать историю: повторяющиеся номера записей.")
            }
            entries = decoded.sorted { $0.number < $1.number }
        }
        loaded = true
        return entries
    }

    @discardableResult func append(_ answer: Answer, batch: BatchAnswer? = nil) throws -> HistoryEntry {
        if !loaded { try load() }
        let entry = HistoryEntry(id: UUID(), number: (entries.map(\.number).max() ?? 0) + 1,
                                 createdAt: Date(), answer: answer, model: Solver.model, reasoning: Solver.reasoning, batch: batch)
        let next = entries + [entry]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = next
        return entry
    }
}
