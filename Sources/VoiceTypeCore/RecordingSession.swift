import Foundation

/// 녹음 트랙 종류.
public enum TrackKind: String, Codable, Sendable, CaseIterable {
    case mic
    case system
    /// 마이크+시스템을 한 파일로 합친 트랙. 시스템 오디오가 잡힌 회차의 기본 산출물.
    case mixed
}

/// 캡처 중 발생한 시간 불연속 1건. 슬립·드롭아웃으로 생긴 공백을 진단하려고 남긴다.
public struct DiscontinuityRecord: Codable, Sendable, Equatable {
    /// 파일 내 시각(초)
    public let fileTime: Double
    /// 세션 시작 기준 실제 경과 시각(초)
    public let wallTime: Double
    /// 이 지점에 삽입한 무음 길이(초)
    public let gapSeconds: Double
    /// 원인 태그 (예: capture_gap, device_change)
    public let reason: String

    public init(fileTime: Double, wallTime: Double, gapSeconds: Double, reason: String) {
        self.fileTime = fileTime
        self.wallTime = wallTime
        self.gapSeconds = gapSeconds
        self.reason = reason
    }
}

/// 트랙 1개의 기록 결과.
public struct TrackInfo: Codable, Sendable, Equatable {
    public let kind: TrackKind
    public var fileName: String
    public var durationSeconds: Double
    public var discontinuities: [DiscontinuityRecord]

    public init(kind: TrackKind,
                fileName: String,
                durationSeconds: Double = 0,
                discontinuities: [DiscontinuityRecord] = []) {
        self.kind = kind
        self.fileName = fileName
        self.durationSeconds = durationSeconds
        self.discontinuities = discontinuities
    }

    enum CodingKeys: String, CodingKey {
        case kind, fileName, durationSeconds, discontinuities
    }

    /// 관대한 디코딩 — 중단된 세션의 manifest는 필드가 덜 쓰인 상태일 수 있다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(TrackKind.self, forKey: .kind)) ?? .mic
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
        durationSeconds = (try? c.decode(Double.self, forKey: .durationSeconds)) ?? 0
        discontinuities = (try? c.decode([DiscontinuityRecord].self, forKey: .discontinuities)) ?? []
    }
}

/// 캡처 진행 상태. 전사 상태와 분리한다 — 캡처는 끝났지만 전사가 실패한 상태를 표현해야 한다.
public enum CaptureStatus: String, Codable, Sendable {
    case recording
    case done
    case failed
}

/// 녹음 회차 1건의 메타데이터. 회차 폴더의 session.json에 저장된다.
///
/// F5는 녹음 전용 기능이다 — 앱 내부에 전사 파이프라인을 두지 않는다.
/// 전사가 필요하면 녹음 파일을 꺼내 별도 STT(Deepgram/로컬 Whisper 등)로 넘긴다.
public struct RecordingSession: Codable, Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public var durationSeconds: Double
    public var captureStatus: CaptureStatus
    public var tracks: [TrackInfo]

    public init(id: String,
                startedAt: Date,
                durationSeconds: Double = 0,
                captureStatus: CaptureStatus = .recording,
                tracks: [TrackInfo] = []) {
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.captureStatus = captureStatus
        self.tracks = tracks
    }

    enum CodingKeys: String, CodingKey {
        case id, startedAt, durationSeconds, captureStatus, tracks
    }

    /// 관대한 디코딩 — 필드가 빠지거나 알 수 없는 status 문자열이어도 안전한 기본값으로 읽는다.
    /// 크래시로 중단된 manifest를 반드시 읽을 수 있어야 복구가 성립한다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        startedAt = (try? c.decode(Date.self, forKey: .startedAt)) ?? Date(timeIntervalSince1970: 0)
        durationSeconds = (try? c.decode(Double.self, forKey: .durationSeconds)) ?? 0
        // 상태를 못 읽으면 .failed — 완료로 오인해 복구 대상에서 빠지는 쪽이 더 나쁘다
        captureStatus = (try? c.decode(CaptureStatus.self, forKey: .captureStatus)) ?? .failed
        tracks = (try? c.decode([TrackInfo].self, forKey: .tracks)) ?? []
    }

    /// 종류로 트랙을 찾는다. 시스템 트랙은 없을 수 있다(마이크만 녹음한 경우).
    public func track(_ kind: TrackKind) -> TrackInfo? {
        tracks.first { $0.kind == kind }
    }

    /// 캡처가 정상 종료되지 않은 세션 — 다음 실행 시 복구 대상.
    public var needsRecovery: Bool {
        captureStatus != .done
    }
}
