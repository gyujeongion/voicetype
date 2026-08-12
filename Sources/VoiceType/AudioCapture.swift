import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// AVAudioConverter inputBlock 의 1회 공급 가드 (참조 타입으로 캡처)
final class ConsumedFlag: @unchecked Sendable {
    var value = false
}

/// 마이크 → 16kHz mono s16le PCM 스트림.
/// 선택된 입력 장치를 AVAudioEngine 입력 유닛에 적용하고, tap에서 실시간 변환해 콜백한다.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private(set) var isRunning = false
    /// 원본 오디오 녹음 파일 (m4a/AAC). recordingURL이 주어졌을 때만 생성.
    private var audioFile: AVAudioFile?

    /// 변환된 PCM(s16le) 청크 콜백 (오디오 스레드에서 호출됨)
    var onPCM: ((Data) -> Void)?
    /// 입력 레벨(RMS, 0~1) — 인디케이터 레벨미터용 (메인 스레드로 전달)
    var onLevel: (@Sendable (Float) -> Void)?
    /// 변환된 PCM + 프레임 수 + 세션 시작 기준 경과 초. 녹음(CAFWriter)용.
    /// 기존 onPCM은 받아쓰기 STT 전송용으로 그대로 둔다.
    var onPCMDetailed: ((Data, Int, Double) -> Void)?
    /// 경과 시각 산출 기준. start()에서 설정된다.
    private var sessionStartHostTime: UInt64 = 0

    init() {
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16000,
                                     channels: 1,
                                     interleaved: true)!
    }

    enum CaptureError: Error { case deviceSet(OSStatus), engineStart(Error), micDenied }

    /// 마이크 권한 요청 (비동기)
    static func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default: completion(false)
        }
    }

    /// - Parameter recordingURL: 주어지면 16kHz mono AAC(m4a)로 원본 오디오를 동시에 파일로 기록.
    func start(deviceID: AudioDeviceID?, recordingURL: URL? = nil) throws {
        guard !isRunning else { return }
        if let dev = deviceID {
            try setInputDevice(dev)
        }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw CaptureError.micDenied }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        if let recordingURL = recordingURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: targetFormat.sampleRate,
                AVNumberOfChannelsKey: targetFormat.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioFile = try? AVAudioFile(forWriting: recordingURL, settings: settings,
                                         commonFormat: .pcmFormatInt16, interleaved: true)
        }

        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            throw CaptureError.engineStart(error)
        }
        sessionStartHostTime = mach_absolute_time()
        isRunning = true
    }

    // MARK: - 호스트 시각

    /// mach_absolute_time 차이를 초로 환산한다. timebase는 한 번만 조회해 캐시한다.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// 주어진 호스트 시각 이후 경과한 초. 캡처 경로가 다른 두 트랙을 공통 축에 올리는 데 쓴다.
    static func secondsSince(_ startHostTime: UInt64) -> Double {
        guard startHostTime != 0 else { return 0 }
        let delta = mach_absolute_time() &- startHostTime
        let nanos = Double(delta) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        audioFile = nil   // dealloc이 파일을 finalize/close
    }

    // MARK: - 장치 지정

    private func setInputDevice(_ dev: AudioDeviceID) throws {
        guard let unit = engine.inputNode.audioUnit else { return }
        var d = dev
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &d,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { throw CaptureError.deviceSet(status) }
    }

    // MARK: - 변환

    private func process(_ buffer: AVAudioPCMBuffer) {
        // 받아쓰기는 onPCM만, 녹음은 onPCMDetailed만 쓴다. 둘 다 없을 때만 건너뛴다.
        guard let converter = converter, onPCM != nil || onPCMDetailed != nil else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var err: NSError?
        let consumed = ConsumedFlag()
        converter.convert(to: out, error: &err) { _, status in
            if consumed.value {
                status.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil { return }
        guard let ch = out.int16ChannelData, out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        let byteCount = n * MemoryLayout<Int16>.size
        let data = Data(bytes: ch[0], count: byteCount)
        onPCM?(data)
        if let onPCMDetailed = onPCMDetailed {
            onPCMDetailed(data, n, Self.secondsSince(sessionStartHostTime))
        }
        if let audioFile = audioFile {
            try? audioFile.write(from: out)
        }

        // 입력 레벨(RMS) 계산 → 레벨미터
        if let onLevel = onLevel {
            let ptr = ch[0]
            var sum: Float = 0
            for i in 0..<n {
                let s = Float(ptr[i]) / 32768.0
                sum += s * s
            }
            let rms = (n > 0) ? (sum / Float(n)).squareRoot() : 0
            DispatchQueue.main.async { onLevel(rms) }
        }
    }
}
