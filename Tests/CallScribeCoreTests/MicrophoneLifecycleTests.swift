@testable import CallScribeCore
import Foundation
import XCTest

final class MicrophoneLifecycleTests: XCTestCase {
    func testHealthyUnchangedRouteDoesNotRestart() {
        let route = MicrophoneRouteState(deviceID: 42, sampleRate: 48_000, channels: 1)
        for _ in 0..<100 {
            XCTAssertFalse(route.needsRestart(current: route, engineRunning: true))
        }
    }

    func testStoppedEngineOrChangedRouteStillRestarts() {
        let route = MicrophoneRouteState(deviceID: 42, sampleRate: 48_000, channels: 1)
        XCTAssertTrue(route.needsRestart(current: route, engineRunning: false))
        XCTAssertTrue(route.needsRestart(current: nil, engineRunning: true))
        XCTAssertTrue(route.needsRestart(current: .init(deviceID: 43, sampleRate: 48_000, channels: 1), engineRunning: true))
        XCTAssertTrue(route.needsRestart(current: .init(deviceID: 42, sampleRate: 16_000, channels: 1), engineRunning: true))
        XCTAssertTrue(route.needsRestart(current: .init(deviceID: 42, sampleRate: 48_000, channels: 2), engineRunning: true))
    }

    func testEngineLeaseIsExclusiveAndReusableAcrossRestarts() {
        let lease = MicrophoneEngineLease()
        for _ in 0..<100 {
            let current = UUID(), other = UUID()
            XCTAssertTrue(lease.acquire(current))
            XCTAssertFalse(lease.acquire(other))
            lease.release(other)
            XCTAssertFalse(lease.acquire(other), "A stale source must not release the active engine")
            lease.release(current)
            XCTAssertTrue(lease.acquire(other))
            lease.release(other)
        }
    }
}
