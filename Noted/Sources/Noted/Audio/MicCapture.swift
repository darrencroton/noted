@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

final class MicCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let _audioLevel = AudioLevel()
    private let _error = SyncString()
    private let _muted = AtomicBool()
    private let _writerState = OSAllocatedUnfairLock<WriterState>(uncheckedState: WriterState())
    private let _rawAudioURL = OSAllocatedUnfairLock<URL?>(uncheckedState: nil)

    private struct WriterState {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var writeFailureCount = 0
    }

    var audioLevel: Float { _audioLevel.value }
    var captureError: String? { _error.value }
    var isMuted: Bool {
        get { _muted.value }
        set { _muted.value = newValue; if newValue { _audioLevel.value = 0 } }
    }

    func bufferStream(deviceID: AudioDeviceID? = nil, rawAudioURL: URL? = nil) -> AsyncStream<AVAudioPCMBuffer> {
        let level = _audioLevel
        let errorHolder = _error

        return AsyncStream { continuation in
            errorHolder.value = nil
            let previousRawAudioURL = self._rawAudioURL.withLock { $0 }
            self._rawAudioURL.withLock { $0 = rawAudioURL }
            if previousRawAudioURL != rawAudioURL {
                self._writerState.withLock { $0 = WriterState() }
            }

            diagLog("[MIC-1] bufferStream called, deviceID=\(String(describing: deviceID))")

            // Set input device before accessing inputNode format
            if let id = deviceID, id > 0 {
                let inputNode = self.engine.inputNode
                let audioUnit = inputNode.audioUnit!
                var devID = id
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                diagLog("[MIC-2] setInputDevice \(id) status=\(status) (0=ok)")
                guard status == noErr else {
                    let msg = "Failed to set input device (OSStatus \(status))"
                    diagLog("[MIC-2-FAIL] \(msg)")
                    errorHolder.value = msg
                    continuation.finish()
                    return
                }
            } else {
                diagLog("[MIC-2] no deviceID, using system default")
            }

            let inputNode = self.engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            let outputFormat = inputNode.outputFormat(forBus: 0)
            diagLog("[MIC-3] inputNode inputFormat: sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount); outputFormat: sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount)")

            let sourceFormat = inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
                ? inputFormat
                : outputFormat
            let tapSampleRate = sourceFormat.sampleRate > 0 ? sourceFormat.sampleRate : 44100
            let tapChannels = sourceFormat.channelCount > 0 ? sourceFormat.channelCount : 1
            guard let tapFormat = AVAudioFormat(
                standardFormatWithSampleRate: tapSampleRate,
                channels: tapChannels
            ) else {
                let msg = "Failed to build tap format (sr=\(tapSampleRate) ch=\(tapChannels))"
                diagLog("[MIC-4-FAIL] \(msg)")
                errorHolder.value = msg
                continuation.finish()
                return
            }
            let writerFormat = self._writerState.withLock { $0.file?.processingFormat }
            diagLog("[MIC-4] tapFormat: sr=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount) existingWriterFormat=\(String(describing: writerFormat))")

            let muted = _muted
            var tapCallCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                guard !muted.value else { level.value = 0; return }
                tapCallCount += 1
                let rms = Self.normalizedRMS(from: buffer)
                level.value = min(rms * 25, 1.0)

                if tapCallCount <= 5 || tapCallCount % 100 == 0 {
                    diagLog("[MIC-6] tap #\(tapCallCount): frames=\(buffer.frameLength) rms=\(rms) level=\(level.value)")
                }

                self._writerState.withLock { state in
                    if state.file == nil, let rawAudioURL = self._rawAudioURL.withLock({ $0 }) {
                        state.file = try? AVAudioFile(forWriting: rawAudioURL, settings: buffer.format.settings)
                    }
                    guard let writer = state.file else { return }
                    do {
                        try Self.write(buffer, to: writer, state: &state)
                    } catch {
                        state.writeFailureCount += 1
                        if state.writeFailureCount <= 5 || state.writeFailureCount % 100 == 0 {
                            diagLog("[MIC-WRITE-FAIL] #\(state.writeFailureCount): \(error.localizedDescription)")
                        }
                    }
                }

                continuation.yield(buffer)
            }

            diagLog("[MIC-5] tap installed, preparing engine...")

            do {
                self.engine.prepare()
                diagLog("[MIC-7] engine prepared, starting...")
                try self.engine.start()
                diagLog("[MIC-8] engine started successfully, isRunning=\(self.engine.isRunning)")
            } catch {
                let msg = "Mic failed: \(error.localizedDescription)"
                print("[MIC-8-FAIL] \(msg)")
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
                self.engine.reset()
                self._writerState.withLock { $0 = WriterState() }
                self._rawAudioURL.withLock { $0 = nil }
                errorHolder.value = msg
                continuation.finish()
            }
        }
    }

    func pause() {
        engine.pause()
        _audioLevel.value = 0
    }

    func resume() throws {
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        _writerState.withLock { $0 = WriterState() }
        _rawAudioURL.withLock { $0 = nil }
        _audioLevel.value = 0
    }

    /// Use this before a mid-session device switch. Hardware format changes can leave
    /// AVAudioEngine's input node carrying stale formats, so the next capture gets a fresh engine.
    func stopForSwitch() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
        _audioLevel.value = 0
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(max(buffer.format.channelCount, 1))
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return channelData[0][(frame * stride) + channel]
                }
                return channelData[channel][frame]
            }
        }

        if let channelData = buffer.int16ChannelData {
            let scale: Float = 1 / Float(Int16.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            return rms(
                frameLength: frameLength,
                channelCount: channelCount
            ) { frame, channel in
                if buffer.format.isInterleaved {
                    let stride = channelCount
                    return Float(channelData[0][(frame * stride) + channel]) * scale
                }
                return Float(channelData[channel][frame]) * scale
            }
        }

        return 0
    }

    private static func write(_ buffer: AVAudioPCMBuffer, to writer: AVAudioFile, state: inout WriterState) throws {
        let targetFormat = writer.processingFormat
        guard !formatsMatch(buffer.format, targetFormat) else {
            try writer.write(from: buffer)
            return
        }

        if state.converter == nil || state.converterInputFormat.map({ !formatsMatch($0, buffer.format) }) != false {
            state.converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            state.converterInputFormat = buffer.format
        }

        guard let converter = state.converter else {
            throw MicCaptureError("Failed to create converter from \(buffer.format) to \(targetFormat)")
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(frameCapacity, 1)) else {
            throw MicCaptureError("Failed to allocate converted mic buffer")
        }

        let consumedInput = OSAllocatedUnfairLock<Bool>(uncheckedState: false)
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            let alreadyConsumed = consumedInput.withLock { value in
                if value { return true }
                value = true
                return false
            }
            if alreadyConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if converted.frameLength > 0 {
                try writer.write(from: converted)
            }
        case .error:
            throw MicCaptureError("Mic buffer conversion failed")
        @unknown default:
            throw MicCaptureError("Unexpected mic buffer conversion status")
        }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func rms(
        frameLength: Int,
        channelCount: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> Float {
        var sum: Float = 0

        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let s = sampleAt(frame, channel)
                sum += s * s
            }
        }

        let sampleCount = Float(frameLength * channelCount)
        return sampleCount > 0 ? sqrt(sum / sampleCount) : 0
    }

    // MARK: - List available input devices

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String)] = []

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize)
            guard status == noErr, bufferListSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr)
            guard status == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            guard status == noErr else { continue }

            result.append((id: deviceID, name: (name?.takeRetainedValue() as String?) ?? ""))
        }

        return result
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        return status == noErr ? uid?.takeRetainedValue() as String? : nil
    }

    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        return status == noErr ? name?.takeRetainedValue() as String? : nil
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )
        // 0 == kAudioDeviceUnknown — no default device configured
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }
}

private struct MicCaptureError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

// Thread-safe audio level
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// Thread-safe bool
final class AtomicBool: @unchecked Sendable {
    private var _value: Bool = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// Thread-safe optional string
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
