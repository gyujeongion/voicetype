import Foundation
import VoiceTypeCore

/// Soniox 실시간 WebSocket STT 클라이언트.
/// 흐름: start → sendAudio(여러 번) → finish → onFinished
final class SonioxClient: NSObject, STTEngine, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let assembler = TranscriptAssembler()
    private var done = false
    /// done·task·session은 메인(시작·취소)·오디오 스레드(sendAudio)·URLSession 큐(수신)가 함께 만진다
    private let lock = NSLock()

    /// (finalText, interimText) — 실시간 자막 갱신
    var onUpdate: ((String, String) -> Void)?
    /// 최종 확정 전사문
    var onFinished: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    var currentText: String { assembler.displayText }

    func start(apiKey: String, languageHints: [String], terms: [String], customEndpoint: String?) {
        assembler.reset()
        let session = URLSession(configuration: .default)
        let url = customEndpoint.flatMap { URL(string: $0) } ?? Soniox.endpoint
        let t = session.webSocketTask(with: url)
        lock.withLock {
            done = false
            self.session = session
            task = t
        }
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
        guard let task = liveTask() else { return }
        task.send(.data(data)) { [weak self] err in
            if let err = err { self?.fail(err) }
        }
    }

    /// 녹음 종료 — 강제 finalize 요청
    func finish() {
        guard let task = liveTask() else { return }
        task.send(.string(Soniox.finalizeMessage())) { _ in }
    }

    func cancel() {
        lock.withLock { done = true }
        teardown()
    }

    /// 아직 끝나지 않았으면 현재 소켓을 돌려준다.
    private func liveTask() -> URLSessionWebSocketTask? {
        lock.withLock { done ? nil : task }
    }

    /// 처음 끝내는 쪽만 true. 완료·실패·취소가 겹쳐도 콜백은 한 번만 나간다.
    private func markDone() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }

    /// 소켓을 닫고 세션을 무효화한다. URLSession은 invalidate하지 않으면 해제되지 않아
    /// 받아쓰기마다 세션이 하나씩 쌓인다.
    private func teardown() {
        let (t, s) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            defer { task = nil; session = nil }
            return (task, session)
        }
        t?.cancel(with: .goingAway, reason: nil)
        s?.invalidateAndCancel()
    }

    // MARK: - 내부

    private func receiveNext() {
        guard let task = liveTask() else { return }
        task.receive { [weak self] result in
            guard let self = self, self.liveTask() != nil else { return }
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
        guard markDone() else { return }
        let text = assembler.result()
        teardown()
        DispatchQueue.main.async { [weak self] in self?.onFinished?(text) }
    }

    private func fail(_ error: Error) {
        guard markDone() else { return }
        teardown()
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
