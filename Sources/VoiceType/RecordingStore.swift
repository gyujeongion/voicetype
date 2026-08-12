import Foundation
import VoiceTypeCore

/// 녹음 회차 폴더와 manifest를 관리한다.
///
/// 받아쓰기 히스토리(~/Library/Application Support/VoiceType/)와 의도적으로 분리한다 —
/// 히스토리는 300건 cap과 30일 만료로 자동 삭제되므로 녹음이 휩쓸려 날아갈 수 있다.
/// 녹음 파일에는 어떤 자동 삭제도 적용하지 않는다.
@MainActor
final class RecordingStore {
    static let shared = RecordingStore()

    static let manifestName = "session.json"

    /// 회차 폴더들이 놓이는 루트. 설정에서 변경 가능.
    var rootURL: URL

    private let fm = FileManager.default

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? Self.defaultRoot
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
