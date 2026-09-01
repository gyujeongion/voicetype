import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import VoiceTypeCore

/// 시스템 오디오(컴퓨터에서 나는 소리) 트랙 녹음.
///
/// 마이크는 MicTrackRecorder가 따로 담당한다. 여기서 `captureMicrophone`(macOS 15+)을
/// 쓰지 않는 이유는 배포 타겟 macOS 14를 유지하기 위해서다. `capturesAudio`는 macOS 13+다.
///
/// 이 레이어의 실패는 녹음 실패가 아니다. 화면 기록 권한이 없거나 스트림이 죽어도
/// 마이크 트랙은 계속되어야 하므로, 실패는 onFailure로만 알린다.
///
/// 알려진 한계: ScreenCaptureKit의 오디오 필터는 창이 아니라 앱 단위라
/// 회의 소리 외에 알림음·음악도 함께 녹음된다. 사용자가 감안하기로 확인한 사항이다.
final class SystemTrackRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: CAFWriter?
    private var startHostTime: UInt64 = 0
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let sampleQueue = DispatchQueue(label: "com.ion.voicetype.scstream.audio", qos: .userInitiated)

    /// 시스템 오디오 레벨(RMS 0~1). 메인 스레드로 전달된다.
    var onLevel: ((Float) -> Void)?
    /// 스트림이 중간에 죽었을 때. 마이크 녹음은 계속된다.
    var onFailure: ((String) -> Void)?

    /// 세션 시작(마이크 시작) 대비 이 트랙이 실제로 녹음을 시작한 지연(초).
    /// 권한 확인·SCStream 기동에 수백ms~수 초가 걸려 마이크보다 항상 늦게 시작한다.
    /// 병합 시 이 값만큼 무음을 앞에 채워야 두 트랙이 맞는다.
    private(set) var startOffsetSeconds: Double = 0

    override init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16000,
                                     channels: 1,
                                     interleaved: true)!
        super.init()
    }

    /// 화면 기록 권한 여부. 권한이 없으면 콘텐츠 조회 자체가 실패한다.
    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    func start(to url: URL, sessionStartedAt: Date) async throws {
        // 오디오만 필요하지만 SCStream은 유효한 SCContentFilter를 요구한다.
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemTrackRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "캡처 가능한 디스플레이가 없습니다."])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // 자기 자신의 소리는 제외한다 (디지털 경로만. 스피커→마이크 물리 누설은 못 막는다)
        config.excludesCurrentProcessAudio = true
        // 영상은 안 쓰지만 스트림이 프레임을 만들긴 하므로 비용을 최소화한다.
        // .screen 출력은 등록하지 않아 프레임이 시스템 단계에서 폐기되게 한다.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let w = try CAFWriter(url: url)
        writer = w

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
        startHostTime = mach_absolute_time()
        startOffsetSeconds = max(0, Date().timeIntervalSince(sessionStartedAt))
    }

    func stop() async -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord], dropped: Int) {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        guard let w = writer else { return (0, [], 0) }
        let result = w.finish()
        let dropped = w.droppedBufferCount
        writer = nil
        return (result.durationSeconds, result.discontinuities, dropped)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let pcm = Self.pcmBuffer(from: sampleBuffer),
              let converted = convert(pcm),
              let ch = converted.int16ChannelData, converted.frameLength > 0 else { return }

        let n = Int(converted.frameLength)
        let data = Data(bytes: ch[0], count: n * MemoryLayout<Int16>.size)
        writer?.write(data, frameCount: n, wallTime: AudioCapture.secondsSince(startHostTime))

        if let onLevel = onLevel {
            var sum: Float = 0
            for i in 0..<n {
                let v = Float(ch[0][i]) / 32768.0
                sum += v * v
            }
            let rms = (sum / Float(n)).squareRoot()
            DispatchQueue.main.async { onLevel(rms) }
        }
    }

    /// CMSampleBuffer → AVAudioPCMBuffer. SCStream은 보통 Float32로 준다.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }

    /// 입력 포맷은 출력 장치 변경(HDMI·블루투스)으로 도중에 바뀔 수 있어 그때마다 컨버터를 다시 만든다.
    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
        }
        guard let converter = converter else { return nil }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        // 값 타입 var를 캡처하면 Sendable 경고가 난다. AudioCapture와 같은 참조 타입 가드를 쓴다.
        let consumed = ConsumedFlag()
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed.value { status.pointee = .noDataNow; return nil }
            consumed.value = true
            status.pointee = .haveData
            return input
        }
        return err == nil ? out : nil
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        let msg = "시스템 오디오 녹음이 중단됐습니다: \(error.localizedDescription)"
        DispatchQueue.main.async { [weak self] in self?.onFailure?(msg) }
    }
}
