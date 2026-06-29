import Foundation
import VoiceTypeCore

/// 받아쓰기 히스토리 저장소. settings와 동일 폴더의 history.json.
/// 재빌드/재설치와 무관하게 보존. 최근 N개 유지.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private let cap = 300

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    func add(profileName: String, raw: String, final: String, autoPasted: Bool) {
        let entry = HistoryEntry(timestamp: Date(),
                                 profileName: profileName,
                                 rawTranscript: raw,
                                 finalText: final,
                                 autoPasted: autoPasted)
        entries.insert(entry, at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        persist()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
