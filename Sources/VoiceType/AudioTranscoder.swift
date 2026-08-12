import Foundation
@preconcurrency import AVFoundation

/// 녹음 종료 후 CAF(LPCM) → 16kHz mono AAC(m4a) 변환.
///
/// 녹음 중에는 크래시 내성 때문에 CAF를 쓰고, 정상 종료 시에만 용량을 줄인다.
/// 시간당 약 115MB → 약 14MB.
enum AudioTranscoder {
    enum TranscodeError: LocalizedError {
        case exportSessionUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .exportSessionUnavailable: return "오디오 변환 세션을 만들지 못했습니다."
            case .failed(let m):            return "오디오 변환 실패: \(m)"
            }
        }
    }

    static func toM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscodeError.exportSessionUnavailable
        }
        try? FileManager.default.removeItem(at: destination)
        export.outputURL = destination
        export.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }

        if export.status != .completed {
            throw TranscodeError.failed(export.error?.localizedDescription ?? "알 수 없는 오류")
        }
    }
}
