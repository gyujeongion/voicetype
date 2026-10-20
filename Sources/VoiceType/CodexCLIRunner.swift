import Foundation

/// 로컬 `codex` CLI(ChatGPT 구독 로그인)로 한 번 질의한다 — API 키·종량제 과금 없이 구독 쿼터를 쓴다.
///
/// `codex exec`는 에이전트 런타임이라 호출당 약 4~6초·약 1.3만 토큰이 든다(실측 2026-10-04).
/// 그래서 사용자 설정·훅·규칙(--ignore-user-config/--ignore-rules)은 끄고, 읽기 전용 샌드박스·임시 폴더에서
/// 세션 기록 없이(--ephemeral) 돌린다.
enum CodexCLIRunner {
    struct Failure: Error { let message: String }

    /// 앱은 launchd/Finder에서 떠서 PATH가 최소라 알려진 설치 위치를 직접 찾는다.
    static func executablePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(prompt: String, model: String, timeout: TimeInterval = 75) async -> Result<String, Failure> {
        guard let exe = executablePath() else {
            return .failure(Failure(message: "codex CLI를 찾을 수 없습니다. 터미널에서 `brew install --cask codex` 후 `codex login`을 하세요."))
        }
        // 받아쓰기를 Esc로 취소하면 codex 프로세스도 바로 끝낸다 (안 그러면 최대 75초간 구독 쿼터를 쓴다)
        let handle = ProcessHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: runBlocking(exe: exe, prompt: prompt, model: model,
                                                       timeout: timeout, handle: handle))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func runBlocking(exe: String, prompt: String, model: String, timeout: TimeInterval,
                                    handle: ProcessHandle) -> Result<String, Failure> {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("voicetype-codex-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        let outFile = workDir.appendingPathComponent("last.txt")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.currentDirectoryURL = workDir
        p.arguments = ["exec", "--skip-git-repo-check", "-s", "read-only", "--ephemeral",
                       "--ignore-user-config", "--ignore-rules",
                       "-m", model, "-o", outFile.path, prompt]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")   // codex는 node 스크립트
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe

        // 파이프가 가득 차 자식이 멈추는 일이 없도록 stderr는 계속 비운다 (끝부분만 보관)
        let errBox = ErrBox()
        errPipe.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }

        // 어느 경로로 끝나든 핸들러를 떼고 파이프를 닫는다 — 안 그러면 호출마다 fd와 핸들러가 남는다
        defer {
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? errPipe.fileHandleForReading.close()
        }

        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return .failure(Failure(message: "codex 실행 실패: \(error.localizedDescription)"))
        }
        guard handle.attach(p) else {   // 시작 직전에 이미 취소됨
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
            return .failure(Failure(message: "취소됨"))
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
            return .failure(Failure(message: "codex 응답이 \(Int(timeout))초 안에 오지 않았습니다."))
        }
        if handle.isCancelled { return .failure(Failure(message: "취소됨")) }

        let text = (try? String(contentsOf: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus == 0, !text.isEmpty { return .success(text) }
        let tail = errBox.tail
        if tail.localizedCaseInsensitiveContains("login") || tail.localizedCaseInsensitiveContains("auth") {
            return .failure(Failure(message: "codex 로그인이 필요합니다. 터미널에서 `codex login`을 실행하세요."))
        }
        return .failure(Failure(message: "codex 실패(종료 \(p.terminationStatus))\(tail.isEmpty ? "" : ": " + tail)"))
    }
}

/// 실행 중인 codex 프로세스를 취소 핸들러와 공유한다.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// false면 이미 취소된 상태 — 호출자가 프로세스를 끝내야 한다.
    func attach(_ p: Process) -> Bool {
        lock.withLock {
            process = p
            return !cancelled
        }
    }

    func cancel() {
        let p = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        if let p, p.isRunning { p.terminate() }
    }
}

private final class ErrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); if data.count > 4096 { data = data.suffix(4096) }; lock.unlock() }
    var tail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " ")
    }
}
