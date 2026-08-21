import Foundation

/// macOS 로그인 항목 등록 상태를 앱이 사용할 수 있는 형태로 표현합니다.
public enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case unknown

    public var isEnabled: Bool {
        self == .enabled
    }
}
