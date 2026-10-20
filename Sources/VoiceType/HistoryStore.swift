import Foundation
import VoiceTypeCore

/// 받아쓰기 히스토리 저장소. settings와 동일 폴더의 history.json.
/// 재빌드/재설치와 무관하게 보존. 최근 N개 유지.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    /// 원본 오디오(m4a) 저장 폴더 — 히스토리 항목과 1:1.
    let recordingsDir: URL
    private let cap = 300
    /// 원본 오디오 보관 기간 — 텍스트 기록은 그대로 두고 오디오 파일만 정리
    private static let audioRetentionSeconds: TimeInterval = 30 * 24 * 3600
    private var retentionTimer: Timer?

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        recordingsDir = dir.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        load()
        purgeExpiredRecordings()
        // 메뉴바 앱은 재시작 없이 오래 떠 있으므로 하루 주기로도 재점검
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.purgeExpiredRecordings() }
        }
    }

    private static let recordingNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 녹음 시작 전 미리 발급하는 원본 오디오 목적지 (m4a). 파일명 = YYMMDD_HHmmss, 찾기 쉽게 시간순 정렬.
    func newRecordingURL() -> URL {
        let base = Self.recordingNameFormatter.string(from: Date())
        var url = recordingsDir.appendingPathComponent(base + ".m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsDir.appendingPathComponent("\(base)_\(n).m4a")
            n += 1
        }
        return url
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        return recordingsDir.appendingPathComponent(name)
    }

    func add(profileName: String, raw: String, final: String, autoPasted: Bool, audioFileName: String? = nil) {
        let entry = HistoryEntry(timestamp: Date(),
                                 profileName: profileName,
                                 rawTranscript: raw,
                                 finalText: final,
                                 autoPasted: autoPasted,
                                 audioFileName: audioFileName)
        entries.insert(entry, at: 0)
        if entries.count > cap {
            let overflow = entries.suffix(entries.count - cap)
            overflow.forEach(deleteAudioFile)
            entries.removeLast(entries.count - cap)
        }
        persist()
    }

    func delete(_ id: UUID) {
        if let entry = entries.first(where: { $0.id == id }) { deleteAudioFile(entry) }
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.forEach(deleteAudioFile)
        entries.removeAll()
        persist()
    }

    private func deleteAudioFile(_ entry: HistoryEntry) {
        guard let url = audioURL(for: entry) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 30일 지난 원본 오디오만 지운다. 전사 텍스트(rawTranscript/finalText)는 보존.
    func purgeExpiredRecordings() {
        let cutoff = Date().addingTimeInterval(-Self.audioRetentionSeconds)
        var didChange = false
        for i in entries.indices {
            guard let name = entries[i].audioFileName, entries[i].timestamp < cutoff else { continue }
            try? FileManager.default.removeItem(at: recordingsDir.appendingPathComponent(name))
            let e = entries[i]
            entries[i] = HistoryEntry(id: e.id, timestamp: e.timestamp, profileName: e.profileName,
                                      rawTranscript: e.rawTranscript, finalText: e.finalText,
                                      autoPasted: e.autoPasted, audioFileName: nil)
            didChange = true
        }
        // 크래시 등으로 히스토리에 못 붙고 남은 고아 파일도 오래됐으면 정리
        if let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let referenced = Set(entries.compactMap { $0.audioFileName })
            for file in files where !referenced.contains(file.lastPathComponent) {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if mtime < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
        if didChange { persist() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    /// 디스크 쓰기 전용 직렬 큐. 히스토리 파일이 수백 KB라 메인에서 인코딩·쓰기를 하면
    /// 받아쓰기 결과를 붙여넣는 순간 UI와 키 입력 처리가 잠깐 멈춘다.
    nonisolated private static let ioQueue = DispatchQueue(label: "com.ion.voicetype.history.io", qos: .utility)

    /// 앱 종료 직전, 대기 중인 히스토리 쓰기를 끝까지 기다린다.
    nonisolated static func flushPendingWrites() {
        ioQueue.sync { }
    }

    private func persist() {
        let snapshot = entries   // 값 타입 복사 — 백그라운드에서 안전하게 인코딩
        let url = fileURL
        Self.ioQueue.async {
            // 들여쓰기 없는 JSON: 크기가 크게 줄고 읽기 호환은 그대로다
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
