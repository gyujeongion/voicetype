import SwiftUI
import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation

/// AVAudioNode의 탭 콜백은 실시간 오디오 큐에서 실행된다.
/// @MainActor 메서드 안에서 콜백을 직접 만들면 Swift 6가 메인 액터 격리를
/// 상속시켜 런타임 실행기 검사로 앱을 종료하므로, 비격리 함수에서 생성한다.
private func installMeterTap(
    on input: AVAudioInputNode,
    format: AVAudioFormat,
    update: @escaping @Sendable (Float, Float) -> Void
) {
    input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for index in 0..<count {
            sum += data[index] * data[index]
        }
        let rms = sqrtf(sum / Float(count))
        let db = 20 * log10f(max(rms, 1e-6))
        let normalized = min(max(rms * 8, 0), 1)
        update(db, normalized)
    }
}

// MARK: - Mic Tester (ObservableObject)

@MainActor
final class MicTester: ObservableObject {
    @Published var samples: [Float] = []     // 0..1 amplitude, 최신 N개
    @Published var peakDB: Float = -80
    @Published var isRunning = false
    @Published var errorMessage: String?

    private var engine: AVAudioEngine?
    private let maxSamples = 160

    func start(deviceID: AudioDeviceID?) {
        stop()
        errorMessage = nil
        let eng = AVAudioEngine()

        if let devID = deviceID, devID != 0 {
            if let au = eng.inputNode.audioUnit {
                var id = devID
                AudioUnitSetProperty(au,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0, &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
            }
        }

        let input = eng.inputNode
        // inputFormat = 실제 하드웨어 포맷 (outputFormat은 그래프 포맷으로 다를 수 있음)
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "No audio input available."
            return
        }

        let maxS = maxSamples
        // self를 오디오 스레드에서 직접 캡처하지 않도록 업데이트 클로저를 별도 분리
        let update: @Sendable (Float, Float) -> Void = { [weak self] db, normalized in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.peakDB = db
                self.samples.append(normalized)
                if self.samples.count > maxS { self.samples.removeFirst() }
            }
        }

        installMeterTap(on: input, format: format, update: update)

        do {
            try eng.start()
            engine = eng
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
    }
}

// MARK: - 설정 화면용 인라인 입력 레벨

struct MicLevelIndicator: View {
    let level: Float
    let peakDB: Float
    let isRunning: Bool
    let errorMessage: String?

    private let localization = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(isRunning ? localization.text("mic.level.running") : localization.text("mic.level.stopped"),
                      systemImage: isRunning ? "waveform" : "waveform.slash")
                    .foregroundStyle(isRunning ? levelColor : .secondary)
                Spacer()
                Text(isRunning ? String(format: "%.1f dB", locale: Locale(identifier: localization.selectedID), peakDB) : "—")
                    .monospacedDigit()
                    .foregroundStyle(isRunning ? levelColor : .secondary)
            }
            .font(.caption)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.16))
                    Capsule()
                        .fill(levelColor)
                        .frame(width: geometry.size.width * CGFloat(isRunning ? level : 0))
                        .animation(.easeOut(duration: 0.06), value: level)
                }
            }
            .frame(height: 10)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.07)))
    }

    private var levelColor: Color {
        if level > 0.8 { return .red }
        if level > 0.5 { return .orange }
        return .green
    }
}
