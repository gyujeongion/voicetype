import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// AVAudioConverter inputBlock 의 1회 공급 가드 (참조 타입으로 캡처)
private final class ConsumedFlag: @unchecked Sendable {
    var value = false
}

/// 마이크 → 16kHz mono s16le PCM 스트림.
/// 선택된 입력 장치를 AVAudioEngine 입력 유닛에 적용하고, tap에서 실시간 변환해 콜백한다.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private(set) var isRunning = false

    /// 변환된 PCM(s16le) 청크 콜백 (오디오 스레드에서 호출됨)
    var onPCM: ((Data) -> Void)?
    /// 입력 레벨(RMS, 0~1) — 인디케이터 레벨미터용 (메인 스레드로 전달)
    var onLevel: (@Sendable (Float) -> Void)?

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

    func start(deviceID: AudioDeviceID?) throws {
        guard !isRunning else { return }
        if let dev = deviceID {
            try setInputDevice(dev)
        }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw CaptureError.micDenied }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStart(error)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
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
        guard let converter = converter, let onPCM = onPCM else { return }
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
        onPCM(data)

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
