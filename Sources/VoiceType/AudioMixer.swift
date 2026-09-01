import Foundation
@preconcurrency import AVFoundation

/// 마이크 트랙 + 시스템 오디오 트랙을 한 파일로 합친다.
///
/// AVMutableComposition에 두 오디오 트랙을 겹쳐 넣고 AVAssetExportSession으로 내보내면
/// AVFoundation이 자동으로 믹스한다(별도 AVAudioMix 없이도 겹치는 구간은 합쳐져 나온다).
/// 시스템 트랙은 항상 마이크보다 늦게 시작하므로 `systemOffsetSeconds`만큼 뒤로 밀어 넣는다.
enum AudioMixer {
    enum MixError: LocalizedError {
        case trackUnavailable(String)
        case exportSessionUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .trackUnavailable(let name): return "\(name) 트랙을 읽을 수 없습니다."
            case .exportSessionUnavailable:   return "오디오 병합 세션을 만들지 못했습니다."
            case .failed(let m):              return "오디오 병합 실패: \(m)"
            }
        }
    }

    static func mixDown(micURL: URL, systemURL: URL, systemOffsetSeconds: Double, to destination: URL) async throws {
        let composition = AVMutableComposition()

        let micAsset = AVURLAsset(url: micURL)
        guard let micSource = try await micAsset.loadTracks(withMediaType: .audio).first else {
            throw MixError.trackUnavailable("마이크")
        }
        guard let micTrack = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MixError.trackUnavailable("마이크")
        }
        let micDuration = try await micAsset.load(.duration)
        try micTrack.insertTimeRange(CMTimeRange(start: .zero, duration: micDuration), of: micSource, at: .zero)

        let sysAsset = AVURLAsset(url: systemURL)
        guard let sysSource = try await sysAsset.loadTracks(withMediaType: .audio).first else {
            throw MixError.trackUnavailable("시스템")
        }
        guard let sysTrack = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MixError.trackUnavailable("시스템")
        }
        let sysDuration = try await sysAsset.load(.duration)
        let offset = CMTime(seconds: systemOffsetSeconds, preferredTimescale: 16000)
        try sysTrack.insertTimeRange(CMTimeRange(start: .zero, duration: sysDuration), of: sysSource, at: offset)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MixError.exportSessionUnavailable
        }
        try? FileManager.default.removeItem(at: destination)
        export.outputURL = destination
        export.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }

        if export.status != .completed {
            throw MixError.failed(export.error?.localizedDescription ?? "알 수 없는 오류")
        }
    }
}
