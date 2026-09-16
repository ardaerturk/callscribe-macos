import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum CaptureSourceInvalidation: Sendable {
    case routeChanged(String)
    case failed(String)

    var message: String {
        switch self {
        case .routeChanged(let message), .failed(let message): return message
        }
    }
}

struct CaptureSourceCallbacks: @unchecked Sendable {
    let audio: @Sendable (CapturedPCMBlock) -> Void
    let activity: @Sendable () -> Void
    let invalidated: @Sendable (CaptureSourceInvalidation) -> Void
}

protocol AudioCaptureSource: AnyObject, Sendable {
    var track: AudioTrack { get }
    var inputDevice: AudioInputDevice? { get }
    func start(callbacks: CaptureSourceCallbacks) throws
    func stop()
}

final class AVAudioEngineMicrophoneSource: AudioCaptureSource, @unchecked Sendable {
    let track = AudioTrack.microphone
    let inputDevice: AudioInputDevice?

    private let engine = AVAudioEngine()
    private let deviceID: AudioObjectID
    private let clock: any MonotonicNanosecondClock
    private var configurationObserver: NSObjectProtocol?
    private var callbacks: CaptureSourceCallbacks?
    private let stateLock = NSLock()
    private var running = false
    private var starting = false

    init(deviceUID: String?, clock: any MonotonicNanosecondClock) throws {
        let resolved = try CoreAudioDeviceCatalog.resolveInputDevice(uid: deviceUID)
        deviceID = resolved.0
        inputDevice = resolved.1
        self.clock = clock
    }

    func start(callbacks: CaptureSourceCallbacks) throws {
        stateLock.lock()
        guard !running, !starting else {
            stateLock.unlock()
            return
        }
        starting = true
        stateLock.unlock()

        do {
            try startEngine(callbacks: callbacks)
            stateLock.lock()
            running = true
            starting = false
            stateLock.unlock()
        } catch {
            stateLock.lock()
            running = false
            starting = false
            stateLock.unlock()
            throw error
        }
    }

    private func startEngine(callbacks: CaptureSourceCallbacks) throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw CallScribeCoreError.microphonePermissionDenied
        case .authorized, .notDetermined:
            break
        @unknown default:
            throw CallScribeCoreError.microphonePermissionDenied
        }

        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw CallScribeCoreError.invalidAudioFormat("microphone input audio unit is unavailable")
        }
        var selectedID = deviceID
        let selectStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard selectStatus == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Select microphone", status: selectStatus)
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            throw CallScribeCoreError.invalidAudioFormat("microphone reported \(format)")
        }

        self.callbacks = callbacks
        input.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, time in
            guard let self else { return }
            callbacks.activity()
            guard let channels = Self.copyChannels(from: buffer), !channels.isEmpty else { return }
            let timestamp = time.isHostTimeValid
                ? AudioHostClock.nanoseconds(forHostTime: time.hostTime)
                : self.clock.now()
            callbacks.audio(CapturedPCMBlock(
                startNanoseconds: timestamp,
                sampleRate: buffer.format.sampleRate,
                channels: channels
            ))
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.callbacks = nil
            throw error
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            callbacks.invalidated(.routeChanged("Microphone audio route changed"))
        }
    }

    func stop() {
        stateLock.lock()
        guard running || starting || callbacks != nil else {
            stateLock.unlock()
            return
        }
        running = false
        starting = false
        stateLock.unlock()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        callbacks = nil
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running || starting
    }

    static func copyChannels(from buffer: AVAudioPCMBuffer) -> [[Float]]? {
        guard let source = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }
        if buffer.format.isInterleaved {
            let count = Int(buffer.format.channelCount)
            return (0..<count).map { channel in
                (0..<frameCount).map { source[0][$0 * count + channel] }
            }
        }
        return (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: source[channel], count: frameCount))
        }
    }

    deinit { stop() }
}

private struct RawAudioBuffer: Sendable {
    let channelCount: Int
    let data: Data
}

@available(macOS 14.2, *)
final class CoreAudioSystemSource: AudioCaptureSource, @unchecked Sendable {
    let track = AudioTrack.system
    let inputDevice: AudioInputDevice? = nil

    private let clock: any MonotonicNanosecondClock
    private let ioQueue = DispatchQueue(label: "app.callscribe.capture.system.io", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "app.callscribe.capture.system.decode", qos: .userInitiated)
    private let routeQueue = DispatchQueue(label: "app.callscribe.capture.system.route")
    private let stateLock = NSLock()

    private var tapID = kAudioObjectUnknown
    private var aggregateDeviceID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var ioBlock: AudioDeviceIOBlock?
    private var tapFormat = AudioStreamBasicDescription()
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var callbacks: CaptureSourceCallbacks?
    private var running = false
    private var starting = false

    init(clock: any MonotonicNanosecondClock) {
        self.clock = clock
    }

    func start(callbacks: CaptureSourceCallbacks) throws {
        stateLock.lock()
        guard !running, !starting else {
            stateLock.unlock()
            return
        }
        starting = true
        stateLock.unlock()
        self.callbacks = callbacks

        do {
            // A Mac with no input device may not have registered this app as an
            // audio process yet. The app produces no playback, so an empty
            // exclusion list is safe and still permits system-only recording.
            let ownProcess = (try? AudioObjectID.system.translateProcessID(getpid())) ?? kAudioObjectUnknown
            let description = Self.makeTapDescription(excludingProcessID: ownProcess)

            try Self.check(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "Create global system-audio tap"
            )
            guard tapID != kAudioObjectUnknown else {
                throw CallScribeCoreError.coreAudioFailure(
                    operation: "Create global system-audio tap",
                    status: kAudioHardwareUnspecifiedError
                )
            }
            tapFormat = try Self.readTapFormat(tapID)
            try Self.validate(tapFormat)

            let aggregateDescription = Self.makeAggregateDescription(
                tapUID: description.uuid.uuidString,
                aggregateUID: "app.callscribe.capture.\(UUID().uuidString)"
            )
            try Self.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateDeviceID
                ),
                operation: "Create private tap aggregate device"
            )

            let format = tapFormat
            let generation = UUID()
            let block: AudioDeviceIOBlock = { [weak self] _, inputData, inputTime, _, _ in
                guard let self, self.isRunningOrStarting else { return }
                callbacks.activity()
                let rawBuffers = Self.copyBuffers(inputData)
                guard !rawBuffers.isEmpty else { return }
                let hostTime = inputTime.pointee.mFlags.contains(.hostTimeValid)
                    ? inputTime.pointee.mHostTime
                    : 0
                let timestamp = hostTime > 0
                    ? AudioHostClock.nanoseconds(forHostTime: hostTime)
                    : self.clock.now()
                self.decodeQueue.async { [weak self] in
                    guard let self, self.isRunningOrStarting, self.ioGeneration == generation else { return }
                    guard let channels = Self.decode(rawBuffers, format: format), !channels.isEmpty else {
                        callbacks.invalidated(.failed("System tap delivered an unsupported PCM buffer"))
                        return
                    }
                    callbacks.audio(CapturedPCMBlock(
                        startNanoseconds: timestamp,
                        sampleRate: format.mSampleRate,
                        channels: channels
                    ))
                }
            }
            ioGeneration = generation
            var procID: AudioDeviceIOProcID?
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &procID,
                    aggregateDeviceID,
                    ioQueue,
                    block
                ),
                operation: "Create system-audio IO callback"
            )
            guard let procID else {
                throw CallScribeCoreError.coreAudioFailure(
                    operation: "Create system-audio IO callback",
                    status: kAudioHardwareUnspecifiedError
                )
            }
            ioProcID = procID
            ioBlock = block
            stateLock.lock()
            running = true
            starting = false
            stateLock.unlock()
            do {
                try Self.check(
                    AudioDeviceStart(aggregateDeviceID, procID),
                    operation: "Start system-audio aggregate device"
                )
            } catch {
                setActive(running: false, starting: false)
                throw error
            }
            installRouteListener(callbacks: callbacks)
        } catch {
            setActive(running: false, starting: false)
            teardown()
            throw error
        }
    }

    func stop() {
        setActive(running: false, starting: false)
        teardown()
    }

    private var ioGeneration = UUID()

    private var isRunningOrStarting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running || starting
    }

    private func setActive(running: Bool, starting: Bool) {
        stateLock.lock()
        self.running = running
        self.starting = starting
        stateLock.unlock()
    }

    private func installRouteListener(callbacks: CaptureSourceCallbacks) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunningOrStarting else { return }
            callbacks.invalidated(.routeChanged("Default output audio route changed"))
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system,
            &address,
            routeQueue,
            listener
        )
        if status == noErr {
            routeListener = listener
        }
    }

    private func teardown() {
        ioGeneration = UUID()
        if let listener = routeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID.system,
                &address,
                routeQueue,
                listener
            )
            routeListener = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            ioProcID = nil
            ioBlock = nil
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        callbacks = nil
    }

    private static func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: "Read system tap format", status: status)
        }
        return format
    }

    static func makeTapDescription(excludingProcessID processID: AudioObjectID) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processID == kAudioObjectUnknown ? [] : [processID])
        description.name = "CallScribe System Audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    static func makeAggregateDescription(tapUID: String, aggregateUID: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "CallScribe System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]],
            // Starting immediately supplies silence callbacks too, which makes
            // a missing IO stream distinguishable from quiet system output.
            kAudioAggregateDeviceTapAutoStartKey: false
        ]
    }

    private static func validate(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate > 0,
              format.mChannelsPerFrame > 0 else {
            throw CallScribeCoreError.invalidAudioFormat("system tap is not linear PCM")
        }
        let isFloat32 = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
        let isInt16 = (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0
            && format.mBitsPerChannel == 16
        guard isFloat32 || isInt16 else {
            throw CallScribeCoreError.invalidAudioFormat(
                "system tap uses unsupported \(format.mBitsPerChannel)-bit PCM"
            )
        }
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CallScribeCoreError.coreAudioFailure(operation: operation, status: status)
        }
    }

    private static func copyBuffers(_ input: UnsafePointer<AudioBufferList>) -> [RawAudioBuffer] {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        return list.compactMap { buffer in
            guard let pointer = buffer.mData, buffer.mDataByteSize > 0 else { return nil }
            return RawAudioBuffer(
                channelCount: max(1, Int(buffer.mNumberChannels)),
                data: Data(bytes: pointer, count: Int(buffer.mDataByteSize))
            )
        }
    }

    private static func decode(
        _ buffers: [RawAudioBuffer],
        format: AudioStreamBasicDescription
    ) -> [[Float]]? {
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var channels: [[Float]] = []
        for buffer in buffers {
            let channelCount = buffer.channelCount
            if isFloat && format.mBitsPerChannel == 32 {
                let values = buffer.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                guard values.count % channelCount == 0 else { return nil }
                channels.append(contentsOf: deinterleave(values, channelCount: channelCount))
            } else if !isFloat && format.mBitsPerChannel == 16 {
                let values = buffer.data.withUnsafeBytes { raw -> [Float] in
                    raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
                }
                guard values.count % channelCount == 0 else { return nil }
                channels.append(contentsOf: deinterleave(values, channelCount: channelCount))
            } else {
                return nil
            }
        }
        return channels
    }

    private static func deinterleave(_ values: [Float], channelCount: Int) -> [[Float]] {
        guard channelCount > 1 else { return [values] }
        let frames = values.count / channelCount
        var channels = Array(repeating: [Float](), count: channelCount)
        for channel in channels.indices { channels[channel].reserveCapacity(frames) }
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                channels[channel].append(values[frame * channelCount + channel])
            }
        }
        return channels
    }

    deinit { stop() }
}
