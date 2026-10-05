import Foundation
import AVFoundation
import VoiceTypeCore

/// 녹음 회차 폴더와 manifest를 관리한다.
///
/// 받아쓰기 히스토리(~/Library/Application Support/VoiceType/)와 의도적으로 분리한다 —
/// 히스토리는 300건 cap과 30일 만료로 자동 삭제되므로 녹음이 휩쓸려 날아갈 수 있다.
/// 녹음 파일에는 어떤 자동 삭제도 적용하지 않는다.
@MainActor
final class RecordingStore: ObservableObject {
    static let shared = RecordingStore()

    static let manifestName = "session.json"

    /// History 탭 표시용 — 회차 1건.
    struct Entry: Identifiable, Equatable {
        let session: RecordingSession
        let folder: URL
        var id: String { session.id }

        /// 전사·재생에 쓸 대표 오디오 파일. mixed(마이크+시스템) > system > mic 순으로 고른다.
        var primaryAudioURL: URL? {
            let track = session.track(.mixed) ?? session.track(.system) ?? session.track(.mic)
            guard let fileName = track?.fileName, !fileName.isEmpty else { return nil }
            return folder.appendingPathComponent(fileName)
        }
    }

    /// F6 시스템 소리 녹음 1건 — 세션 폴더·json 없이 m4a 파일 하나가 전부다.
    struct Clip: Identifiable, Equatable {
        let url: URL
        let startedAt: Date
        let durationSeconds: Double
        var id: String { url.lastPathComponent }
    }

    /// F6 파일들이 쌓이는 단일 폴더 (회차 폴더 루트 바로 아래).
    static let systemClipsFolderName = "System Audio"
    var systemClipsURL: URL { rootURL.appendingPathComponent(Self.systemClipsFolderName, isDirectory: true) }

    /// 회차 폴더들이 놓이는 루트. 설정에서 변경 가능.
    var rootURL: URL {
        didSet { refresh() }
    }

    /// GUI(History 탭)가 구독하는 전체 회차 목록. 최신순.
    @Published private(set) var entries: [Entry] = []
    /// GUI(History 탭)용 F6 파일 목록. 최신순.
    @Published private(set) var clips: [Clip] = []

    private let fm = FileManager.default

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? Self.defaultRoot
        refresh()
    }

    /// 디스크를 다시 스캔해 `entries`를 갱신한다. 녹음 종료 직후·루트 변경 시 호출.
    func refresh() {
        refreshClips()
        guard let items = try? fm.contentsOfDirectory(at: rootURL,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else {
            entries = []
            return
        }
        entries = items.compactMap { folder -> Entry? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
                  let session = try? load(from: folder) else { return nil }
            return Entry(session: session, folder: folder)
        }.sorted { $0.session.startedAt > $1.session.startedAt }
    }

    private func refreshClips() {
        guard let files = try? fm.contentsOfDirectory(at: systemClipsURL,
                                                      includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles]) else {
            clips = []
            return
        }
        clips = files.filter { $0.pathExtension.lowercased() == "m4a" }.map { url -> Clip in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let date = SystemClipName.parse(url.lastPathComponent) ?? created ?? .distantPast
            var seconds = 0.0
            if let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 {
                seconds = Double(f.length) / f.fileFormat.sampleRate
            }
            return Clip(url: url, startedAt: date, durationSeconds: seconds)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    /// 새 F6 녹음의 파일 위치. 같은 초에 겹치면 " (2)"를 붙인다.
    func newSystemClipTarget(at date: Date = Date()) throws -> (caf: URL, m4a: URL) {
        try fm.createDirectory(at: systemClipsURL, withIntermediateDirectories: true)
        let base = SystemClipName.make(from: date)
        var name = base
        var n = 2
        while fm.fileExists(atPath: systemClipsURL.appendingPathComponent(name + ".m4a").path)
                || fm.fileExists(atPath: systemClipsURL.appendingPathComponent(name + ".caf").path) {
            name = "\(base) (\(n))"
            n += 1
        }
        return (systemClipsURL.appendingPathComponent(name + ".caf"),
                systemClipsURL.appendingPathComponent(name + ".m4a"))
    }

    /// 파일을 휴지통으로 옮긴다 (영구 삭제 아님).
    @discardableResult
    func moveToTrash(_ clip: Clip) -> String? {
        defer { refresh() }
        do { try fm.trashItem(at: clip.url, resultingItemURL: nil); return nil }
        catch { return error.localizedDescription }
    }

    /// 크래시·강제종료로 m4a가 못 된 F6 녹음(.caf)을 찾는다. 지금 녹음 중인 파일은 제외한다.
    func orphanSystemClipCAFs(excluding active: URL?) -> [URL] {
        guard let files = try? fm.contentsOfDirectory(at: systemClipsURL, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "caf" && $0 != active }
    }

    /// 회차 폴더를 휴지통으로 옮긴다. 회의 녹음은 되돌릴 수 없으면 안 되므로 영구 삭제하지 않는다.
    /// 휴지통이 없는 볼륨(일부 네트워크 드라이브)이면 실패 사유를 돌려주고 아무것도 지우지 않는다.
    @discardableResult
    func moveToTrash(_ entry: Entry) -> String? {
        defer { refresh() }
        do {
            try fm.trashItem(at: entry.folder, resultingItemURL: nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType Recordings", isDirectory: true)
    }

    // MARK: - 생성

    /// 새 회차 폴더를 만들고 초기 manifest를 쓴다.
    func createSession(startedAt: Date = Date()) throws -> (session: RecordingSession, folder: URL) {
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // 같은 초 + 같은 랜덤이 겹치는 극단적 경우엔 다시 뽑는다
        var folder: URL
        var id: String
        var attempt = 0
        repeat {
            id = RecordingID.make(from: startedAt, random: RecordingID.randomSuffix())
            folder = rootURL.appendingPathComponent(id, isDirectory: true)
            attempt += 1
        } while fm.fileExists(atPath: folder.path) && attempt < 10
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)

        let session = RecordingSession(id: id, startedAt: startedAt, captureStatus: .recording)
        try save(session, in: folder)
        return (session, folder)
    }

    // MARK: - 입출력

    /// manifest를 원자적으로 교체한다. 녹음 중 크래시가 나도 반쯤 쓰인 JSON이 남지 않는다.
    func save(_ session: RecordingSession, in folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(session)
        try data.write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    func load(from folder: URL) throws -> RecordingSession {
        let data = try Data(contentsOf: folder.appendingPathComponent(Self.manifestName))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(RecordingSession.self, from: data)
    }

    // MARK: - 복구

    /// 캡처가 정상 종료되지 않은 회차들. 앱 시작 시 복구에 쓴다. 최신순.
    func incompleteSessions() -> [(session: RecordingSession, folder: URL)] {
        guard let entries = try? fm.contentsOfDirectory(at: rootURL,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { folder -> (RecordingSession, URL)? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
                  let s = try? load(from: folder), s.needsRecovery else { return nil }
            return (s, folder)
        }.sorted { $0.0.startedAt > $1.0.startedAt }
    }

    // MARK: - 디스크

    /// 여유 공간 검사. 16kHz mono LPCM 2트랙은 시간당 약 230MB를 쓴다.
    func hasEnoughDiskSpace(at url: URL, requiredBytes: Int64) -> Bool {
        // 볼륨 정보는 존재하는 경로에서만 읽힌다. 아직 없으면 상위로 거슬러 올라간다.
        var probe = url
        while !fm.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return true   // 알 수 없으면 막지 않는다
        }
        return available >= requiredBytes
    }

    /// 쓰기 가능 여부. 녹음 시작 전에 확인해 중간 실패를 막는다.
    func isWritable(_ url: URL) -> Bool {
        if !fm.fileExists(atPath: url.path) {
            guard (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) != nil else {
                return false
            }
        }
        return fm.isWritableFile(atPath: url.path)
    }
}
