import AudioToolbox
import CoreAudio

/// Lifecycle is owned exclusively by ProcessMeter on MainActor. The HAL sees
/// only SampleTransport through a stable refcon retained until disposal succeeds.
@MainActor
final class PlaybackSink {
    enum Failure: LocalizedError {
        case audioUnit(OSStatus)
        case unavailable
        case unsupportedOutput
        case unsupportedSource
        case changedDestination
        var errorDescription: String? {
            switch self {
            case .audioUnit(let status): "Playback sink error \(status)."
            case .unavailable: "The hardware output Audio Unit is unavailable."
            case .unsupportedOutput: "This mirror prototype requires a stereo hardware output at 32–96 kHz."
            case .unsupportedSource: "The tap must provide packed Float32 stereo PCM at 32–96 kHz."
            case .changedDestination: "The selected destination disconnected, changed identity/format, or stopped."
            }
        }
    }
    let destination: AudioDevice
    private var unit: AudioUnit?
    private var initialized = false
    private var started = false
    private(set) var transport: SampleTransport?
    private var outputFormat = AudioStreamBasicDescription()
    var hasResources: Bool { unit != nil }

    init(destination: AudioDevice) { self.destination = destination }

    // Install this owner in ProcessMeter BEFORE calling prepare, so any partial
    // Audio Unit remains reachable for cleanup even if configuration fails.
    func prepare(sourceFormat: AudioStreamBasicDescription, level: PlaybackLevel = .unity) throws {
        guard SampleTransport.supports(sourceFormat) else { throw Failure.unsupportedSource }
        try AudioDevices().validateMirrorDestination(destination)
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure.unavailable }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created))
        guard let created else { throw Failure.unavailable }
        unit = created
        var device = destination.id
        try set(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, value: &device)
        var native = AudioStreamBasicDescription()
        try get(kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, value: &native)
        let rate = try AudioDevices().sampleRate(destination.id)
        guard native.mChannelsPerFrame == 2, native.mSampleRate == rate,
              (32_000...96_000).contains(rate) else { throw Failure.unsupportedOutput }
        outputFormat = native
        let transport = SampleTransport(format: sourceFormat, outputRate: rate, level: level)
        self.transport = transport
        var clientFormat = AudioStreamBasicDescription(mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        try set(kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Input, value: &clientFormat)
        var maxFrames: UInt32 = 8192
        try set(kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, value: &maxFrames)
        var callback = AURenderCallbackStruct(inputProc: Self.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(transport).toOpaque())
        try set(kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Input, value: &callback)
        try check(AudioUnitInitialize(created))
        initialized = true
        try validate(requireRunning: false)
        try check(AudioOutputUnitStart(created))
        started = true
        try validate(requireRunning: true)
    }

    func validate(requireRunning: Bool = true) throws {
        try AudioDevices().validateMirrorDestination(destination)
        guard unit != nil, try AudioDevices().sampleRate(destination.id) == outputFormat.mSampleRate else {
            throw Failure.changedDestination
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        try get(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, value: &device)
        var native = AudioStreamBasicDescription()
        try get(kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, value: &native)
        guard device == destination.id, SampleTransport.sameFormat(native, outputFormat) else {
            throw Failure.changedDestination
        }
        if requireRunning {
            var running: UInt32 = 0
            try get(kAudioOutputUnitProperty_IsRunning, scope: kAudioUnitScope_Global, value: &running)
            guard running != 0 else { throw Failure.changedDestination }
        }
    }

    func stop() throws {
        transport?.enabled.store(false, ordering: .releasing)
        guard let unit else { return }
        if started { try check(AudioOutputUnitStop(unit)); started = false }
        if initialized { try check(AudioUnitUninitialize(unit)); initialized = false }
        try check(AudioComponentInstanceDispose(unit))
        self.unit = nil
        // The capture callback also retains transport until its IOProc is
        // destroyed. Disposal failure must never release the render refcon.
        transport = nil
    }

    nonisolated static let renderCallback: AURenderCallback = { refcon, _, _, _, frames, output in
        let transport = Unmanaged<SampleTransport>.fromOpaque(refcon).takeUnretainedValue()
        guard let output else {
            transport.renderFault.store(true, ordering: .relaxed)
            return kAudio_ParamError
        }
        return transport.render(output, frames: Int(frames))
    }

    private func set<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, scope: AudioUnitScope, value: inout T) throws {
        guard let unit else { throw Failure.unavailable }
        try check(AudioUnitSetProperty(unit, property, scope, 0, &value, UInt32(MemoryLayout<T>.size)))
    }
    private func get<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, scope: AudioUnitScope, value: inout T) throws {
        guard let unit else { throw Failure.unavailable }
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioUnitGetProperty(unit, property, scope, 0, &value, &size))
        guard size == MemoryLayout<T>.size else { throw Failure.unavailable }
    }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.audioUnit(status) }
    }
}
