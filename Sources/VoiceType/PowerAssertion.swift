import Foundation
import IOKit.pwr_mgt

/// 녹음 중 디스플레이·시스템 절전을 막는다.
/// 이게 없으면 회의 도중 화면이 꺼지면서 시스템 오디오 캡처가 멈춘다.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private var held = false

    func acquire(reason: String) {
        guard !held else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID)
        if result == kIOReturnSuccess {
            id = newID
            held = true
        }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
        id = 0
    }

    deinit { release() }
}
