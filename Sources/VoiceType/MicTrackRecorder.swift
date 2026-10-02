import Foundation
@preconcurrency import AVFoundation
import VoiceTypeCore

/// 마이크 트랙 녹음. 기존 AudioCapture(AVAudioEngine)를 그대로 쓴다.
///
/// 이 경로는 화면 기록 권한이 필요 없고 macOS 14에서 동작하며 시작 지연이 밀리초다.
/// "맥북만 들고 F5로 즉시 녹음"의 핵심이라, 어떤 경우에도 시스템 오디오 실패에
/// 끌려가 중단되면 안 된다.
@MainActor
final class MicTrackRecorder {
    private let capture = AudioCapture()
    private var writer: CAFWriter?

    var onLevel: ((Float) -> Void)?
    /// 녹음 중 입력 장치가 바뀌어 다시 연결했을 때 (true=복구됨, false=입력 장치 없음)
    var onDeviceReconnected: ((Bool) -> Void)?
    var isRunning: Bool { capture.isRunning }
    var restartCount: Int { capture.restartCount }

    /// 설정의 마이크 우선순위를 적용해 녹음을 시작한다.
    func start(to url: URL) throws {
        let settings = SettingsStore.shared.settings
        // 우선순위에 맞는 장치가 없으면 nil → AVAudioEngine이 시스템 기본 입력을 쓴다
        let device = AudioDevices.resolve(selectedUID: settings.selectedMicrophoneUID,
                                          priority: settings.microphonePriority)
        let w = try CAFWriter(url: url)
        writer = w
        capture.onPCMDetailed = { [weak w] data, frames, wallTime in
            w?.write(data, frameCount: frames, wallTime: wallTime)
        }
        capture.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.onLevel?(level) }
        }
        // 장치가 바뀌면 그 시점 설정 규칙(에어팟 > 선택 > 우선순위 > 기본)으로 다시 고른다
        capture.deviceResolver = {
            MainActor.assumeIsolated {
                let s = SettingsStore.shared.settings
                return AudioDevices.resolve(selectedUID: s.selectedMicrophoneUID,
                                            priority: s.microphonePriority)?.deviceID
            }
        }
        capture.onReconfigured = { [weak self] ok in
            MainActor.assumeIsolated { self?.onDeviceReconnected?(ok) }
        }
        do {
            try capture.start(deviceID: device?.deviceID)
        } catch {
            capture.onPCMDetailed = nil
            capture.onLevel = nil
            writer = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// 자기검증용 — 장치 구성 변경 상황 재현
    func simulateConfigurationChange() { capture.simulateConfigurationChange() }

    func stop() -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord], dropped: Int) {
        capture.stop()
        capture.onPCMDetailed = nil
        capture.onLevel = nil
        capture.onReconfigured = nil
        capture.deviceResolver = nil
        guard let w = writer else { return (0, [], 0) }
        let result = w.finish()
        let dropped = w.droppedBufferCount
        writer = nil
        return (result.durationSeconds, result.discontinuities, dropped)
    }
}

/// GUI 없이 마이크 녹음만 실측하는 검증 모드. `VoiceType --record-audio 30`
enum RecordAudioCLI {
    @MainActor
    static func run(seconds: Double) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-record-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mic.caf")
        try? FileManager.default.removeItem(at: url)

        // 어느 장치가 실제로 잡혔는지 먼저 보여준다 — 무음 원인 대부분이 장치 오선택이다
        let settings = SettingsStore.shared.settings
        let chosen = AudioDevices.resolve(selectedUID: settings.selectedMicrophoneUID,
                                          priority: settings.microphonePriority)
        print("사용 가능한 입력 장치:")
        for d in AudioDevices.inputDevices() {
            let mark = (d.id == chosen?.id) ? " ◀ 선택됨" : ""
            print("  · \(d.name)  [\(d.id)]\(mark)")
        }
        if chosen == nil {
            print("  (우선순위 일치 없음 → 시스템 기본 입력 사용)")
        }
        print("")

        let rec = MicTrackRecorder()
        do {
            try rec.start(to: url)
        } catch {
            print("녹음 시작 실패: \(error.localizedDescription)")
            exit(1)
        }
        print("녹음 중… \(seconds)초. 목적지: \(url.path)")
        Thread.sleep(forTimeInterval: seconds)

        let r = rec.stop()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        // 실시간 레벨 콜백은 main 큐로 오는데 이 CLI는 Thread.sleep으로 main을 막고 있다.
        // 그래서 라이브 레벨이 아니라 실제로 디스크에 쓰인 파일을 다시 읽어 측정한다.
        // 파이프라인 끝단을 검증하므로 이쪽이 더 정확하다.
        let a = analyze(url)
        print("""

        ── 결과 ──
        기록 길이 : \(String(format: "%.2f", r.durationSeconds))초  (요청 \(seconds)초)
        파일 길이 : \(String(format: "%.2f", a.duration))초  (디스크 실측)
        파일 크기 : \(size) bytes
        불연속    : \(r.discontinuities.count)건
        드롭 버퍼 : \(r.dropped)개
        피크 진폭 : \(String(format: "%.4f", a.peak))
        RMS      : \(String(format: "%.5f", a.rms))
        무음 비율 : \(String(format: "%.1f%%", a.silentRatio * 100))
        """)
        for d in r.discontinuities {
            print("  gap \(String(format: "%.2f", d.gapSeconds))초 @ file \(String(format: "%.2f", d.fileTime))초 (\(d.reason))")
        }
        if a.peak < 0.001 {
            print("⚠️  파일이 사실상 무음이다. 마이크 권한·장치 라우팅·입력 게인을 확인할 것.")
        } else {
            print("✓ 오디오가 실제로 기록됐다.")
        }
        print("재생: afplay \(url.path)")
        exit(0)
    }

    /// 기록된 CAF를 다시 읽어 피크·RMS·무음 비율을 낸다.
    private static func analyze(_ url: URL) -> (duration: Double, peak: Float, rms: Float, silentRatio: Double) {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return (0, 0, 0, 1) }
        let n = Int(buf.frameLength)
        guard n > 0 else { return (0, 0, 0, 1) }
        let duration = Double(n) / file.fileFormat.sampleRate

        var peak: Float = 0
        var sumSq: Double = 0
        var silentFrames = 0
        if let ch = buf.int16ChannelData {
            for i in 0..<n {
                let v = abs(Float(ch[0][i]) / 32768.0)
                peak = max(peak, v)
                sumSq += Double(v) * Double(v)
                if v < 0.0005 { silentFrames += 1 }
            }
        } else if let ch = buf.floatChannelData {
            for i in 0..<n {
                let v = abs(ch[0][i])
                peak = max(peak, v)
                sumSq += Double(v) * Double(v)
                if v < 0.0005 { silentFrames += 1 }
            }
        }
        return (duration, peak, Float((sumSq / Double(n)).squareRoot()),
                Double(silentFrames) / Double(n))
    }
}

/// 녹음 중 입력 장치 구성 변경(에어팟 분리 등)이 와도 마이크 트랙이 이어지는지 실측한다.
/// `VoiceType --selftest-device-change 4` → 절반 지점에서 구성 변경을 재현하고,
/// 재연결 1회 이상 + 파일 길이 ≈ 요청 길이 + 뒷부분에 실제 오디오가 있으면 SELFTEST_PASS.
enum DeviceChangeSelfTest {
    @MainActor
    static func run(seconds: Double) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mic.caf")
        try? FileManager.default.removeItem(at: url)

        let rec = MicTrackRecorder()
        var reconnects: [Bool] = []
        rec.onDeviceReconnected = { reconnects.append($0) }
        do { try rec.start(to: url) } catch {
            print("SELFTEST_FAIL 녹음 시작 실패: \(error.localizedDescription)")
            exit(1)
        }
        // 메인 큐가 돌아야 재시작(asyncAfter)이 실행된다 — sleep 대신 런루프를 돌린다
        RunLoop.main.run(until: Date().addingTimeInterval(seconds / 2))
        print("구성 변경 재현")
        rec.simulateConfigurationChange()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds / 2))
        let r = rec.stop()

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        // 처리 포맷을 Int16으로 지정해야 int16ChannelData로 읽힌다 (기본은 Float32)
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(1, file.length))),
              (try? file.read(into: buf)) != nil, let ch = buf.int16ChannelData else {
            print("SELFTEST_FAIL 파일을 읽을 수 없음 (크기 \(size)B, 기록 \(r.durationSeconds)초, 재연결 \(reconnects))")
            exit(1)
        }
        let n = Int(buf.frameLength)
        let duration = Double(n) / file.fileFormat.sampleRate
        let tailStart = n * 3 / 4
        var nonZero = 0
        for i in tailStart..<n where ch[0][i] != 0 { nonZero += 1 }
        let tailRatio = Double(nonZero) / Double(max(1, n - tailStart))
        print(String(format: "재연결 %d회 %@ / 파일 %.2f초(요청 %.1f) / 기록 %.2f초 / 뒤 1/4 유효샘플 %.0f%% / 불연속 %d건",
                     rec.restartCount, reconnects.description, duration, seconds, r.durationSeconds,
                     tailRatio * 100, r.discontinuities.count))
        let ok = rec.restartCount >= 1 && reconnects.contains(true)
            && abs(duration - seconds) < 0.8 && tailRatio > 0.5
        print(ok ? "SELFTEST_PASS" : "SELFTEST_FAIL")
        exit(ok ? 0 : 1)
    }
}
