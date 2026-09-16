@testable import CallScribeCore
import CoreAudio
import XCTest

final class CoreAudioDeviceTests: XCTestCase {
    private func candidate(_ uid: String, _ transport: UInt32, isDefault: Bool = false,
                           hidden: Bool = false) -> InputDeviceCandidate {
        InputDeviceCandidate(objectID: 1,
            device: AudioInputDevice(id: uid, name: uid, isDefault: isDefault),
            transport: transport, hidden: hidden)
    }

    func testAirPodsStaySelectedWhenOnlyAlternativesAreInternalOrVirtual() throws {
        let devices = [
            candidate("CADefaultDeviceAggregate-32803-0", kAudioDeviceTransportTypeAggregate),
            candidate("app.callscribe.capture.test", kAudioDeviceTransportTypeAggregate),
            candidate("virtual", kAudioDeviceTransportTypeVirtual),
            candidate("unknown", 0),
            candidate("private-usb", kAudioDeviceTransportTypeUSB, hidden: true),
            candidate("AirPods", kAudioDeviceTransportTypeBluetooth, isDefault: true)
        ]
        XCTAssertEqual(try CoreAudioDeviceCatalog.selectInput(uid: nil, candidates: devices).device.uid, "AirPods")
    }

    func testAutomaticPrefersRealUSBMicrophoneOverBluetooth() throws {
        let devices = [
            candidate("CADefaultDeviceAggregate-1", kAudioDeviceTransportTypeAggregate),
            candidate("AirPods", kAudioDeviceTransportTypeBluetoothLE, isDefault: true),
            candidate("USB mic", kAudioDeviceTransportTypeUSB)
        ]
        XCTAssertEqual(try CoreAudioDeviceCatalog.selectInput(uid: nil, candidates: devices).device.uid, "USB mic")
        XCTAssertEqual(try CoreAudioDeviceCatalog.selectInput(uid: "AirPods", candidates: devices).device.uid, "AirPods")
    }

    func testInternalDefaultFallsBackToRealInputAndCannotBeExplicitlySelected() throws {
        let devices = [
            candidate("CADefaultDeviceAggregate-1", kAudioDeviceTransportTypeAggregate, isDefault: true),
            candidate("built-in", kAudioDeviceTransportTypeBuiltIn)
        ]
        XCTAssertEqual(try CoreAudioDeviceCatalog.selectInput(uid: nil, candidates: devices).device.uid, "built-in")
        XCTAssertThrowsError(try CoreAudioDeviceCatalog.selectInput(uid: "CADefaultDeviceAggregate-1", candidates: devices))
    }

    func testPublicUserAggregateRemainsAvailableWhenExplicitOrDefault() throws {
        let devices = [candidate("My aggregate", kAudioDeviceTransportTypeAggregate, isDefault: true)]
        XCTAssertEqual(try CoreAudioDeviceCatalog.selectInput(uid: "My aggregate", candidates: devices).device.uid, "My aggregate")
        XCTAssertEqual(try CoreAudioDeviceCatalog.selectInput(uid: nil, candidates: devices).device.uid, "My aggregate")
    }

    func testOnlyInternalInputsMeansNoMicrophoneRatherThanFalseSuccess() {
        let devices = [candidate("app.callscribe.capture.test", kAudioDeviceTransportTypeAggregate)]
        XCTAssertThrowsError(try CoreAudioDeviceCatalog.selectInput(uid: nil, candidates: devices))
    }
}
