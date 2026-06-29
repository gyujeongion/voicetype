import Foundation
import Sparkle

/// Sparkle 자동 업데이트 관리. 자체배포 앱의 원격 업데이트 체크.
/// 피드: GitHub Releases의 appcast.xml (Info.plist SUFeedURL). 서명: EdDSA(SUPublicEDKey).
@MainActor
final class UpdaterManager: NSObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    private override init() {
        // startingUpdater: true → 앱 시작 시 자동 스케줄 체크(SUScheduledCheckInterval)
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        super.init()
    }

    /// 메뉴 "업데이트 확인" — 사용자가 직접 트리거
    @objc func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticChecksEnabled: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
