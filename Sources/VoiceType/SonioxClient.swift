import Foundation
import VoiceTypeCore

/// Soniox 실시간 WebSocket STT 클라이언트.
/// 흐름: start → sendAudio(여러 번) → finish → onFinished
final class SonioxClient: NSObject, STTEngine, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let assembler = TranscriptAssembler()
    private var done = false

    /// (finalText, interimText) — 실시간 자막 갱신
    var onUpdate: ((String, String) -> Void)?
    /// 최종 확정 전사문
    var onFinished: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    var currentText: String { assembler.displayText }

    func start(apiKey: String, languageHints: [String], terms: [String], customEndpoint: String?) {
        done = false
        assembler.reset()
        let session = URLSession(configuration: .default)
        self.session = session
        let url = customEndpoint.flatMap { URL(string: $0) } ?? Soniox.endpoint
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()

        let ctx = terms.isEmpty ? nil : Soniox.StartConfig.Context(terms: terms)
        let cfg = Soniox.StartConfig(apiKey: apiKey,
                                     languageHints: languageHints,
                                     context: ctx)
        do {
            let data = try cfg.jsonData()
            let str = String(decoding: data, as: UTF8.self)
            t.send(.string(str)) { [weak self] err in
                if let err = err { self?.fail(err) }
            }
        } catch {
            fail(error)
            return
        }
        receiveNext()
    }

    func sendAudio(_ data: Data) {
        guard !done, let task = task else { return }
        task.send(.data(data)) { [weak self] err in
            if let err = err { self?.fail(err) }
        }
    }

    /// 녹음 종료 — 강제 finalize 요청
    func finish() {
        guard !done, let task = task else { return }
        task.send(.string(Soniox.finalizeMessage())) { _ in }
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
                self.fail(err)
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: data = nil
                }
                if let data = data { self.handle(data) }
                if self.assembler.isFinished {
                    self.complete()
                } else {
                    self.receiveNext()
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let resp = try? Soniox.decode(data) else { return }
        if let code = resp.errorCode {
            fail(NSError(domain: "Soniox", code: code,
                         userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Soniox error \(code)"]))
            return
        }
        assembler.ingest(resp)
        let f = assembler.finalText, i = assembler.interimText
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(f, i) }
    }

    private func complete() {
        guard !done else { return }
        done = true
        let text = assembler.result()
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
