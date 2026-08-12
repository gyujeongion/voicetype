import Foundation
import AppKit
@preconcurrency import AVFoundation
import VoiceTypeCore

/// F5 녹음 전체 흐름 제어.
///
/// 핵심 규칙: 마이크 트랙은 어떤 경우에도 시스템 오디오 실패에 끌려가지 않는다.
/// 시스템 오디오는 "되면 얹히는" 부가 레이어다.
@MainActor
final class RecorderController {
    enum State { case idle, starting, recording, stopping, finalizing }

    private(set) var state: State = .idle

    private let mic = MicTrackRecorder()
    private var system: SystemTrackRecorder?
    private let power = PowerAssertion()
    private var store: RecordingStore { RecordingStore.shared }

    private var session: RecordingSession?
    private var folder: URL?
    private var startedAt: Date?
    private var diskTimer: Timer?
    /// 화면 기록 권한 안내를 이미 띄웠는지 (녹음마다 반복하면 성가시다)
    private static var screenPermissionWarned = false

    /// 녹음 시작 최소 여유 공간 — LPCM 2트랙 2시간분 + 여유
    private static let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// 녹음 중 이 밑으로 떨어지면 정상 종료로 전환
    private static let criticalFreeBytes: Int64 = 300 * 1024 * 1024

    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?
    var onMicLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?
    /// 완료된 회차 폴더
    var onFinished: ((URL) -> Void)?

    var isRecording: Bool { state == .recording }
    var elapsedSeconds: Double {
        guard let startedAt = startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - 토글

    func toggle() {
        switch state {
        case .idle:      start()
        case .recording: Task { await stop() }
        default:         break   // starting/stopping/finalizing 중엔 무시
        }
    }

    // MARK: - 시작

    private func start() {
        setState(.starting)

        guard store.isWritable(store.rootURL) else {
            onError?("녹음 폴더에 쓸 수 없습니다:\n\(store.rootURL.path)\n설정에서 다른 폴더를 지정하세요.")
            setState(.idle)
            return
        }
        guard store.hasEnoughDiskSpace(at: store.rootURL, requiredBytes: Self.minFreeBytes) else {
            onError?("디스크 여유 공간이 부족합니다. 최소 2GB가 필요합니다.")
            setState(.idle)
            return
        }

        AudioCapture.requestPermission { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard ok else {
                    self.onError?("마이크 권한이 거부되었습니다.\n시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 VoiceType을 허용하세요.")
                    self.setState(.idle)
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let now = Date()
        let created: (session: RecordingSession, folder: URL)
        do {
            created = try store.createSession(startedAt: now)
        } catch {
            onError?("녹음 폴더 생성 실패: \(error.localizedDescription)")
            setState(.idle)
            return
        }
        session = created.session
        folder = created.folder
        startedAt = now

        // 레이어 1 — 마이크. 이게 실패하면 녹음 자체가 실패다.
        mic.onLevel = { [weak self] in self?.onMicLevel?($0) }
        do {
            try mic.start(to: created.folder.appendingPathComponent("mic.caf"))
        } catch {
            onError?("마이크 녹음 시작 실패: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: created.folder)
            resetAll()
            setState(.idle)
            return
        }

        power.acquire(reason: "VoiceType 녹음 중")
        startDiskWatch()
        setState(.recording)

        // 레이어 2 — 시스템 오디오. 실패해도 마이크는 계속된다.
        Task { [weak self] in
            await self?.attachSystemTrack(in: created.folder)
        }
    }

    private func attachSystemTrack(in folder: URL) async {
        // 녹음이 이미 끝났으면(짧게 눌렀다 뗀 경우) 붙이지 않는다
        guard state == .recording else { return }

        guard await SystemTrackRecorder.hasPermission() else {
            if !Self.screenPermissionWarned {
                Self.screenPermissionWarned = true
                onError?("""
                화면 기록 권한이 없어 컴퓨터 소리는 녹음되지 않습니다. 마이크 녹음은 계속됩니다.

                시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 VoiceType을 허용한 뒤 앱을 다시 실행하세요.
                (오디오만 사용하며 화면은 녹화하지 않습니다)
                """)
            }
            return
        }
        guard state == .recording else { return }

        let rec = SystemTrackRecorder()
        rec.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.onSystemLevel?(level) }
        }
        rec.onFailure = { [weak self] msg in
            MainActor.assumeIsolated { self?.onError?(msg) }
        }
        do {
            try await rec.start(to: folder.appendingPathComponent("system.caf"))
            // await 사이에 녹음이 끝났을 수 있다
            if state == .recording {
                system = rec
            } else {
                _ = await rec.stop()
            }
        } catch {
            onError?("컴퓨터 소리 녹음을 시작하지 못했습니다. 마이크 녹음은 계속됩니다.\n\(error.localizedDescription)")
        }
    }

    // MARK: - 디스크 감시

    private func startDiskWatch() {
        diskTimer?.invalidate()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.state == .recording else { return }
                guard !self.store.hasEnoughDiskSpace(at: self.store.rootURL,
                                                     requiredBytes: Self.criticalFreeBytes) else { return }
                self.onError?("디스크 여유 공간이 부족해 녹음을 종료합니다.")
                Task { await self.stop() }
            }
        }
    }

    // MARK: - 종료

    private func stop() async {
        guard state == .recording, let folder = folder, var session = session else { return }
        setState(.stopping)
        diskTimer?.invalidate(); diskTimer = nil
        power.release()

        let micResult = mic.stop()
        let sysResult = await system?.stop()
        system = nil

        setState(.finalizing)

        // CAF → m4a 변환. 실패해도 원본 CAF를 절대 먼저 지우지 않는다.
        var tracks: [TrackInfo] = []
        if let info = await finalizeTrack(.mic, in: folder,
                                          duration: micResult.durationSeconds,
                                          discontinuities: micResult.discontinuities) {
            tracks.append(info)
        }
        if let sys = sysResult, sys.durationSeconds > 0,
           let info = await finalizeTrack(.system, in: folder,
                                          duration: sys.durationSeconds,
                                          discontinuities: sys.discontinuities) {
            tracks.append(info)
        }

        session.tracks = tracks
        session.durationSeconds = micResult.durationSeconds
        session.captureStatus = tracks.isEmpty ? .failed : .done
        // 전사는 다음 단계의 범위 — 여기서는 대기 상태로 남긴다
        session.transcriptionStatus = .pending
        try? store.save(session, in: folder)

        self.session = nil
        self.folder = nil
        self.startedAt = nil
        setState(.idle)
        onFinished?(folder)
    }

    /// CAF를 m4a로 바꾸고 TrackInfo를 만든다. 변환 실패 시 CAF를 그대로 보관한다.
    private func finalizeTrack(_ kind: TrackKind,
                               in folder: URL,
                               duration: Double,
                               discontinuities: [DiscontinuityRecord]) async -> TrackInfo? {
        let base = kind.rawValue
        let caf = folder.appendingPathComponent("\(base).caf")
        guard FileManager.default.fileExists(atPath: caf.path) else { return nil }
        let m4a = folder.appendingPathComponent("\(base).m4a")
        do {
            try await AudioTranscoder.toM4A(from: caf, to: m4a)
            try? FileManager.default.removeItem(at: caf)
            return TrackInfo(kind: kind, fileName: "\(base).m4a",
                             durationSeconds: duration, discontinuities: discontinuities)
        } catch {
            onError?("\(base) 변환에 실패해 원본(caf)을 그대로 보관합니다.\n\(error.localizedDescription)")
            return TrackInfo(kind: kind, fileName: "\(base).caf",
                             durationSeconds: duration, discontinuities: discontinuities)
        }
    }

    // MARK: - 복구

    /// 앱 시작 시 호출. 캡처가 정상 종료되지 않은 회차의 CAF를 m4a로 마감한다.
    /// 크래시로 남은 CAF는 마지막 바이트까지 유효하므로 그대로 변환하면 된다.
    @discardableResult
    func recoverIncompleteSessions() async -> Int {
        let pending = store.incompleteSessions()
        guard !pending.isEmpty else { return 0 }
        var recovered = 0
        for (var s, folder) in pending {
            var tracks: [TrackInfo] = []
            for kind in TrackKind.allCases {
                let caf = folder.appendingPathComponent("\(kind.rawValue).caf")
                if FileManager.default.fileExists(atPath: caf.path) {
                    if let info = await finalizeTrack(kind, in: folder,
                                                      duration: Self.audioDuration(at: caf),
                                                      discontinuities: []) {
                        tracks.append(info)
                    }
                    continue
                }
                // 변환 직후 크래시한 경우 m4a만 남아 있다
                let m4a = folder.appendingPathComponent("\(kind.rawValue).m4a")
                if FileManager.default.fileExists(atPath: m4a.path) {
                    tracks.append(TrackInfo(kind: kind, fileName: "\(kind.rawValue).m4a",
                                            durationSeconds: Self.audioDuration(at: m4a)))
                }
            }
            s.tracks = tracks
            s.captureStatus = tracks.isEmpty ? .failed : .done
            s.durationSeconds = tracks.first?.durationSeconds ?? 0
            try? store.save(s, in: folder)
            if !tracks.isEmpty { recovered += 1 }
        }
        return recovered
    }

    /// 오디오 길이를 파일에서 직접 읽는다 (크래시로 manifest에 안 남은 경우).
    private static func audioDuration(at url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: -

    private func resetAll() {
        session = nil; folder = nil; startedAt = nil
        diskTimer?.invalidate(); diskTimer = nil
        power.release()
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }
}
