import Foundation
import VoiceTypeCore

/// API 키 유효성 빠른 검증 (온보딩·설정의 "테스트" 버튼용).
enum KeyTester {
    enum Result: Sendable {
        case ok(String)        // 성공 메시지
        case fail(String)      // 사용자용 실패 메시지
    }

    /// STT 키 테스트 — provider별 짧은 연결/인증 확인.
    static func testSTT(provider: STTProvider, apiKey: String, customEndpoint: String?) async -> Result {
        guard !apiKey.isEmpty else { return .fail("API 키를 입력하세요.") }
        switch provider {
        case .soniox, .custom:
            return await testSonioxLike(apiKey: apiKey, customEndpoint: customEndpoint)
        case .deepgram:
            return await testDeepgram(apiKey: apiKey)
        }
    }

    /// LLM 키 테스트 — chat/completions에 최소 요청.
    static func testLLM(config: LLMConfig, apiKey: String?) async -> Result {
        let needsAPIKey = LLMPresets.requiresAPIKey(endpoint: config.endpoint)
        if needsAPIKey && (apiKey?.isEmpty != false) {
            return .fail("LLM API 키를 입력하세요.")
        }
        guard let url = URL(string: config.endpoint) else { return .fail("엔드포인트 주소가 올바르지 않습니다.") }
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey, !apiKey.isEmpty {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            var body: [String: Any] = [
                "model": config.model,
                PromptBuilder.maxTokensKey(endpoint: config.endpoint, model: config.model): 16,
                "messages": [["role": "user", "content": "hi"]],
            ]
            body.merge(PromptBuilder.providerExtras(endpoint: config.endpoint, model: config.model)) { _, new in new }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .fail("응답을 받지 못했습니다.") }
            if (200..<300).contains(http.statusCode) { return .ok("LLM 연결 성공 (\(config.model))") }
            return .fail(PostProcessRunner.httpFailureMessage(status: http.statusCode, data: data, model: config.model))
        } catch {
            return .fail(networkMessage(error))
        }
    }

    // MARK: - STT 구현

    /// Soniox/호환 — WebSocket 연결 후 config 전송, 인증 에러 여부만 확인.
    private static func testSonioxLike(apiKey: String, customEndpoint: String?) async -> Result {
        let url = customEndpoint.flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? Soniox.endpoint
        return await withCheckedContinuation { cont in
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)
            let finished = LockedFlag()
            let done: @Sendable (Result) -> Void = { r in
                if finished.testAndSet() { return }
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                cont.resume(returning: r)
            }
            task.resume()
            let cfg = Soniox.StartConfig(apiKey: apiKey)
            if let data = try? cfg.jsonData() {
                task.send(.string(String(decoding: data, as: UTF8.self))) { err in
                    if let err = err { done(.fail(networkMessage(err))) }
                }
                // 오디오가 없으면 정상 키여도 서버가 아무 응답을 안 보내 12초 타임아웃으로
                // "실패" 판정이 난다. 0.1초 무음 + finalize를 보내 응답을 받아낸다.
                task.send(.data(Data(count: 3200))) { _ in }
                task.send(.string(Soniox.finalizeMessage())) { _ in }
            }
            // 첫 응답 수신: 에러코드면 키 문제, 정상 토큰 메시지면 성공
            task.receive { result in
                switch result {
                case .failure(let err):
                    done(.fail(networkMessage(err)))
                case .success(let msg):
                    var text = ""
                    if case .string(let s) = msg { text = s }
                    if case .data(let d) = msg { text = String(decoding: d, as: UTF8.self) }
                    if let resp = try? Soniox.decode(Data(text.utf8)), let code = resp.errorCode {
                        if code == 401 || code == 403 {
                            done(.fail("Soniox 키가 유효하지 않습니다. 키를 확인하세요."))
                        } else {
                            done(.fail("Soniox 오류 (\(code)): \(resp.errorMessage ?? "")"))
                        }
                    } else {
                        done(.ok("Soniox 연결 성공"))
                    }
                }
            }
            // 타임아웃 가드
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                done(.fail("연결 시간 초과. 네트워크나 키를 확인하세요."))
            }
        }
    }

    /// Deepgram — WebSocket 연결 시도(헤더 인증). 핸드셰이크 성공=키 OK.
    private static func testDeepgram(apiKey: String) async -> Result {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
        ]
        guard let url = comps.url else { return .fail("URL 구성 실패") }
        var req = URLRequest(url: url)
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        return await withCheckedContinuation { cont in
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: req)
            let finished = LockedFlag()
            let done: @Sendable (Result) -> Void = { r in
                if finished.testAndSet() { return }
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
                cont.resume(returning: r)
            }
            task.resume()
            // 핑 전송으로 연결 확인
            task.sendPing { err in
                if let err = err {
                    // 키가 틀리면 웹소켓 업그레이드가 HTTP 401로 거절되고, 에러 자체는
                    // NSURLErrorBadServerResponse라 코드만 봐선 키 문제인지 알 수 없다.
                    let status = (task.response as? HTTPURLResponse)?.statusCode
                    let ns = err as NSError
                    if status == 401 || status == 403 || ns.code == 401 || ns.code == 403 {
                        done(.fail("Deepgram 키가 유효하지 않습니다."))
                    } else {
                        done(.fail(networkMessage(err)))
                    }
                } else {
                    done(.ok("Deepgram 연결 성공"))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                done(.fail("연결 시간 초과. 네트워크나 키를 확인하세요."))
            }
        }
    }

    static func networkMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "인터넷에 연결되어 있지 않습니다. 연결을 확인하세요."
            case NSURLErrorTimedOut:
                return "연결 시간이 초과되었습니다."
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "서버에 연결할 수 없습니다. 엔드포인트 주소를 확인하세요."
            default: break
            }
        }
        return "연결 실패: \(error.localizedDescription)"
    }
}

/// 콜백 1회 보장용 플래그
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    /// 이미 set이면 true 반환(=중복 호출), 아니면 set하고 false
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return true }
        flag = true
        return false
    }
}
