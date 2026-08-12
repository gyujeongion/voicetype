import Foundation
@preconcurrency import AVFoundation
import VoiceTypeCore

/// 16kHz mono 16-bit LPCM을 Core Audio Format(.caf)으로 기록한다.
///
/// 크래시 내성이 이 타입의 존재 이유다. m4a(AAC)는 프레임 인덱스(moov atom)를
/// 파일 끝에 쓰므로 강제 종료 시 파일 전체가 파싱 불가가 된다. CAF LPCM은
/// 헤더 확정이 필요 없어 마지막으로 쓰인 바이트까지 항상 유효하다.
/// 정상 종료 후 AudioTranscoder가 m4a로 줄인다.
/// 내부 상태는 전용 직렬 큐(파일 쓰기)와 NSLock(카운터)으로 보호되므로 @unchecked Sendable.
final class CAFWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var clock: TrackClock
    private var discontinuities: [DiscontinuityRecord] = []
    /// 캡처 콜백을 절대 막지 않기 위한 전용 직렬 큐
    private let queue: DispatchQueue

    /// 적체 카운터는 캡처 스레드(증가)와 쓰기 큐(감소) 양쪽에서 건드리므로 락으로 보호한다.
    private let counterLock = NSLock()
    private var _droppedBufferCount = 0
    private var _pendingCount = 0
    private let maxPending = 200   // 0.1초 청크 기준 약 20초분

    /// 큐 적체로 버린 버퍼 수. manifest 진단용.
    var droppedBufferCount: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return _droppedBufferCount
    }

    init(url: URL, sampleRate: Double = 16000) throws {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: sampleRate,
                                      channels: 1,
                                      interleaved: true) else {
            throw NSError(domain: "CAFWriter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "오디오 포맷 생성 실패"])
        }
        format = fmt
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
        clock = TrackClock(sampleRate: sampleRate)
        queue = DispatchQueue(label: "com.ion.voicetype.cafwriter.\(url.lastPathComponent)",
                              qos: .userInitiated)
    }

    /// 캡처 콜백에서 호출한다. 실제 파일 쓰기는 전용 큐로 넘겨 콜백을 막지 않는다.
    /// - Parameter wallTime: 세션 시작 기준 경과 초
    func write(_ data: Data, frameCount: Int, wallTime: Double) {
        counterLock.lock()
        if _pendingCount >= maxPending {
            _droppedBufferCount += 1
            counterLock.unlock()
            return
        }
        _pendingCount += 1
        counterLock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.counterLock.lock()
                self._pendingCount -= 1
                self.counterLock.unlock()
            }
            self.writeSync(data, frameCount: frameCount, wallTime: wallTime)
        }
    }

    private func writeSync(_ data: Data, frameCount: Int, wallTime: Double) {
        // 공백이 임계값을 넘으면 무음을 먼저 채워 파일 시간축을 벽시계에 맞춘다
        if let gap = clock.silenceNeeded(atWallTime: wallTime) {
            let rec = clock.recordGap(wallTime: wallTime, gapSeconds: gap, reason: "capture_gap")
            // 첫 버퍼 전의 공백은 엔진 기동 지연이라 매번 생긴다.
            // 무음 패딩은 트랙 간 정렬에 필요하므로 넣되, 진단 기록으로는 남기지 않는다.
            if rec.fileTime > 0 { discontinuities.append(rec) }
            writeSilence(seconds: gap)
        }
        guard let buf = makeBuffer(from: data, frameCount: frameCount) else { return }
        try? file.write(from: buf)
        clock.advance(frameCount: frameCount)
    }

    private func makeBuffer(from data: Data, frameCount: Int) -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let ch = buf.int16ChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(frameCount)
        let byteCount = min(data.count, frameCount * MemoryLayout<Int16>.size)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(ch[0], base, byteCount) }
        }
        return buf
    }

    /// 긴 공백은 한 번에 잡으면 메모리를 크게 먹으므로 1초씩 나눠 쓴다.
    private func writeSilence(seconds: Double) {
        var remaining = seconds
        while remaining > 0 {
            let chunk = min(remaining, 1.0)
            let frames = Int(chunk * format.sampleRate)
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(frames)),
                  let ch = buf.int16ChannelData else { return }
            buf.frameLength = AVAudioFrameCount(frames)
            memset(ch[0], 0, frames * MemoryLayout<Int16>.size)
            try? file.write(from: buf)
            remaining -= chunk
        }
    }

    /// 큐를 비우고 최종 길이·불연속 목록을 돌려준다.
    func finish() -> (durationSeconds: Double, discontinuities: [DiscontinuityRecord]) {
        queue.sync { }   // drain
        return (clock.writtenSeconds, discontinuities)
    }
}
