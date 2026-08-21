import AppKit
import Combine
import ServiceManagement
import VoiceTypeCore

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var errorMessage: String?

    private init() {
        status = Self.mapStatus(SMAppService.mainApp.status)
    }

    var isEnabled: Bool {
        status.isEnabled
    }

    func refresh() {
        status = Self.mapStatus(SMAppService.mainApp.status)
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            status = Self.mapStatus(SMAppService.mainApp.status)
            errorMessage = error.localizedDescription
        }
    }

    private static func mapStatus(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}
