import Foundation
import VoiceTypeCore

/// Deepgram 실시간 WebSocket STT 클라이언트.
/// wss://api.deepgram.com/v1/listen?model=nova-3&language=ko&encoding=linear16&sample_rate=16000…
/// 인증: Authorization: Token <key> 헤더. 오디오: linear16(= s16le) binary.
/// 종료: {"type":"CloseStream"}. 응답: channel.alternatives[].transcript + is_final.
///
/// 주의: API 키가 없어 자동 검증은 미수행. 프로토콜은 공식 문서 기준으로 구현.
final class DeepgramClient: NSObject, STTEngine, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var done = false
    private var finishRequested = false

    private var finalSegments: [String] = []
    private var interim = ""

    var onUpdate: ((String, String) -> Void)?
    var onFinished: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    func start(apiKey: String, languageHints: [String], terms: [String], customEndpoint: String?) {
        done = false
        finishRequested = false
        finalSegments = []
        interim = ""

        let lang = languageHints.first ?? "ko"
        var comps = URLComponents(string: customEndpoint?.isEmpty == false
                                  ? customEndpoint! : "wss://api.deepgram.com/v1/listen")!
        var items = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: lang),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
        ]
        // 단어사전 → keyterm (nova-3 키텀 부스팅)
        for t in terms.prefix(100) {
            items.append(URLQueryItem(name: "keyterm", value: t))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            fail(NSError(domain: "Deepgram", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 구성 실패"]))
            return
        }

        var req = URLRequest(url: url)
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        self.session = session
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receiveNext()
    }

    func sendAudio(_ data: Data) {
        guard !done, let task = task else { return }
        task.send(.data(data)) { [weak self] err in
            if let err = err { self?.fail(err) }
        }
    }

    func finish() {
        guard !done, let task = task else { return }
        finishRequested = true
        // CloseStream → 서버가 남은 결과 전송 후 연결 종료
        task.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
    }

    func cancel() {
        done = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
    }

    // MARK: - 내부

    private func receiveNext() {
        guard let task = task else { return }
        task.receive { [weak self] result in
            guard let self = self, !self.done else { return }
            switch result {
            case .failure(let err):
                if self.finishRequested {
                    self.complete()
                } else {
                    self.fail(err)
                }
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: data = nil
                }
                if let data = data { self.handle(data) }
                if !self.done { self.receiveNext() }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // 종료 메타데이터
        if let type = obj["type"] as? String, type == "Metadata" {
            complete()
            return
        }
        guard let channel = obj["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let transcript = alts.first?["transcript"] as? String else { return }
        let isFinal = (obj["is_final"] as? Bool) ?? false

        if isFinal {
            if !transcript.isEmpty { finalSegments.append(transcript) }
            interim = ""
        } else {
            interim = transcript
        }
        let finalText = finalSegments.joined(separator: " ")
        let i = interim
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(finalText, i.isEmpty ? "" : " " + i) }
    }

    private func complete() {
        guard !done else { return }
        done = true
        let text = finalSegments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        DispatchQueue.main.async { [weak self] in self?.onFinished?(text) }
    }

    private func fail(_ error: Error) {
        guard !done else { return }
        done = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
