import AVFoundation
import Combine

/// 히스토리 탭에서 녹음을 앱 안에서 바로 듣는 플레이어. 한 번에 하나만 재생한다.
/// (예전엔 Finder를 열어 직접 파일을 찾아 재생해야 했다)
@MainActor
final class AudioPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPreviewPlayer()

    @Published private(set) var playingURL: URL?
    @Published private(set) var errorMessage: String?
    private var player: AVAudioPlayer?

    func isPlaying(_ url: URL?) -> Bool {
        guard let url else { return false }
        return playingURL == url
    }

    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            guard p.play() else { throw NSError(domain: "AudioPreviewPlayer", code: -1) }
            player = p
            playingURL = url
            errorMessage = nil
        } catch {
            errorMessage = LocalizationManager.shared.text("history.play.failed")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // 플레이어 객체 대신 식별자만 넘긴다 (AVAudioPlayer는 Sendable이 아님)
        let finishedURL = player.url
        Task { @MainActor in
            if self.playingURL == finishedURL { self.stop() }
        }
    }
}
