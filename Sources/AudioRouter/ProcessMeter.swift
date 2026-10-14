import CoreAudio
import Foundation
import Synchronization

final class CaptureState: @unchecked Sendable {
    let peak = Atomic<Float>(0)
    let lastPacket = Atomic<UInt64>(0)
    let transport: SampleTransport?
    init(transport: SampleTransport?) { self.transport = transport }
}

/// Single owner of tap, aggregate, capture callback, transport and optional
/// pinned playback sink. Capture starts unmuted; a caller-selected exclusive
/// route defers suppression until fresh replacement PCM and property readback.
@MainActor
final class ProcessMeter {
    enum Failure: LocalizedError {
        case coreAudio(OSStatus)
        case unsupportedFormat
        case missingIOProc
        case busy
        case changedClient
        case selfCapture
        case captureStopped
        case playbackNotReady
        case playbackInterrupted
        case startAndCleanup(String, String)

        var errorDescription: String? {
            switch self {
            case .coreAudio(let status): "Core Audio monitor error \(status). Check System Settings → Privacy & Security → Screen & System Audio Recording."
            case .unsupportedFormat: "The process tap returned an unsupported audio format."
            case .missingIOProc: "Core Audio did not return a monitor callback handle."
            case .busy: "Stop the existing monitor before starting another."
            case .changedClient: "The audio client changed. Reopen the menu and try again."
            case .selfCapture: "AudioRouter cannot mirror its own output (feedback risk)."
            case .captureStopped: "The selected output stopped receiving capture callbacks."
            case .playbackNotReady: "Wait for stable replacement playback before suppressing the original output."
            case .playbackInterrupted: "Replacement playback stalled, underrun, or returned invalid output."
            case .startAndCleanup(let start, let cleanup): "Audio operation failed: \(start). Restoration/cleanup also failed: \(cleanup). Resources are retained; retry Stop / restore."
            }
        }
    }

    /// A completed recovery notice, not a restoration/cleanup error. Produced
    /// only after Stop returns successfully; audibility is not inferred.
    struct StoppedOutput {
        let destination: AudioDevice
        let reason: Error
        var message: String {
            "\(reason.localizedDescription) AudioRouter left the tap unmuted and released the route resources. Check playback on the current default output. Restart the route explicitly after reconnecting."
        }
    }

    private var tapID: AudioObjectID?
    private var playbackControl: TapPlaybackControl?
    private var stopRequested = false
    private var retryFailureReported = false
    private var suppressionUnderruns = 0
    private var aggregateID: AudioObjectID?
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var sink: PlaybackSink?
    private var captureState: CaptureState?
    private var healthTimer: Timer?
    private var mirroredClient: AudioProcess?
    private var captureStart: UInt64 = 0
    private var captureFormat: AudioStreamBasicDescription?
    private var healthTick = 0
    private(set) var clientID: AudioObjectID?
    private(set) var peak: Float = 0
    private(set) var exclusiveOutputPending = false
    var onLevel: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onStoppedOutput: ((StoppedOutput) -> Void)?
    var onStateChange: (() -> Void)?
    var suppressionRequested: Bool { playbackControl?.suppressionConfirmed == true }
    var restorationPending: Bool {
        playbackControl?.restorationRequired == true && !suppressionRequested
    }
    var canSuppressOriginal: Bool {
        guard started, sink != nil, !stopRequested,
              playbackControl?.restorationRequired == false,
              let state = captureState, let transport = state.transport else { return false }
        let captured = state.lastPacket.load(ordering: .relaxed)
        let now = DispatchTime.now().uptimeNanoseconds
        return captured != 0 && now &- captured <= 500_000_000 && transport.isPlaybackReady()
    }
    var mirrorDestination: AudioDevice? { sink?.destination }
    var isRunning: Bool { started }
    var isStopping: Bool { stopRequested }
    var transportStatus: String? {
        guard let transport = captureState?.transport else { return nil }
        return "Buffer: \(transport.underruns.load(ordering: .relaxed)) underruns, \(transport.overruns.load(ordering: .relaxed)) dropped packets"
    }

    var hasResources: Bool { tapID != nil || aggregateID != nil || ioProc != nil || sink?.hasResources == true }

    func start(client: AudioProcess, mirroringTo destination: AudioDevice? = nil,
               suppressWhenReady: Bool = false) throws {
        guard !hasResources else { throw Failure.busy }
        // A process object is a transient ID, not a durable identity. Re-check
        // the observed PID and bundle ID immediately before creating a tap.
        let current = try AudioProcesses().snapshot().activeOutputClients.first { $0.id == client.id }
        guard client.pid != nil, client.birth != nil, client.bundleID != nil,
              current?.pid == client.pid, current?.birth == client.birth,
              current?.bundleID == client.bundleID else {
            throw Failure.changedClient
        }
        if let destination {
            guard client.pid != ProcessInfo.processInfo.processIdentifier,
                  client.bundleID != Bundle.main.bundleIdentifier else { throw Failure.selfCapture }
            try AudioDevices().validateMirrorDestination(destination)
        }
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: [client.id])
            description.muteBehavior = .unmuted
            description.isPrivate = true
            var tap = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(description, &tap))
            tapID = tap
            playbackControl = TapPlaybackControl(tap: tap, uuid: description.uuid)
            stopRequested = false
            retryFailureReported = false

            let aggregateDescription: [String: Any] = [
                "uid": "app.soundtool.local.monitor.\(UUID().uuidString)",
                "name": "AudioRouter Private Monitor",
                "private": 1,
                "subdevices": [],
                "taps": [["uid": description.uuid.uuidString]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate))
            aggregateID = aggregate

            let format = try tapFormat(tap)
            guard SampleTransport.supports(format) else { throw Failure.unsupportedFormat }
            captureFormat = format

            if let destination {
                let playback = PlaybackSink(destination: destination)
                sink = playback // retain partially configured resources on failure
                try playback.prepare(sourceFormat: format)
                mirroredClient = client
            }
            let state = CaptureState(transport: sink?.transport)
            captureState = state
            // HAL blocks are constructed outside actor isolation. Capture
            // publishes bounded PCM/atomics only; the main actor polls levels.
            let queue = DispatchQueue(label: "app.soundtool.local.monitor.io", qos: .userInteractive)
            let block = Self.makeCaptureBlock(state: state)
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, block))
            guard let proc else { throw Failure.missingIOProc }
            ioProc = proc
            try check(AudioDeviceStart(aggregate, proc))
            started = true
            clientID = client.id
            peak = 0
            captureStart = DispatchTime.now().uptimeNanoseconds
            healthTick = 0
            exclusiveOutputPending = destination != nil && suppressWhenReady
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                // Installed only on the main run loop. Poll synchronously so
                // safety work is not queued behind an extra actor Task.
                MainActor.assumeIsolated { self?.poll() }
            }
            healthTimer = timer
            RunLoop.main.add(timer, forMode: .common) // includes menu tracking
        } catch let startFailure {
            // Keep failed-cleanup resources owned, so Stop can retry. Never
            // conceal a cleanup error by dropping its IDs.
            do { try stop() } catch let cleanupFailure {
                throw Failure.startAndCleanup(startFailure.localizedDescription, cleanupFailure.localizedDescription)
            }
            throw startFailure
        }
    }

    func suppressOriginalPlayback() throws {
        guard canSuppressOriginal, let control = playbackControl,
              let transport = captureState?.transport else { throw Failure.playbackNotReady }
        // Revalidate the device, client and format immediately, not only on
        // the polling cadence. Startup itself always remains unmuted.
        exclusiveOutputPending = false
        try validatePlayback()
        suppressionUnderruns = transport.underruns.load(ordering: .relaxed)
        do {
            try control.suppress()
            try validatePlayback()
            guard transport.underruns.load(ordering: .relaxed) == suppressionUnderruns,
                  transport.isPlaybackReady() else {
                throw Failure.playbackInterrupted
            }
        } catch let failure {
            do { try restoreOriginalPlayback() }
            catch { throw Failure.startAndCleanup(failure.localizedDescription, error.localizedDescription) }
            throw failure
        }
        onStateChange?()
    }

    func restoreOriginalPlayback() throws {
        // A manual restore or Stop cancels deferred suppression, including
        // when restoration fails. Never re-suppress automatically on retry.
        exclusiveOutputPending = false
        defer { onStateChange?() }
        try playbackControl?.restore()
    }

    func stop() throws {
        stopRequested = true
        // RESTORE FIRST. If read/write/readback fails, do not disable transport,
        // stop the reader/sink, or destroy the tap. Retain replacement playback
        // and the timer so restoration can be retried while resources are owned.
        try restoreOriginalPlayback()
        healthTimer?.invalidate()
        healthTimer = nil
        captureState?.transport?.enabled.store(false, ordering: .releasing)
        if started, let aggregate = aggregateID, let proc = ioProc {
            try check(AudioDeviceStop(aggregate, proc))
            started = false
        }
        // Stop playback after capture is quiescent, before destroying its
        // source resources. Any failure keeps the entire remaining owner.
        if let sink {
            try sink.stop()
            self.sink = nil
        }
        if let aggregate = aggregateID, let proc = ioProc {
            try check(AudioDeviceDestroyIOProcID(aggregate, proc))
            ioProc = nil
        }
        if let aggregate = aggregateID {
            try check(AudioHardwareDestroyAggregateDevice(aggregate))
            aggregateID = nil
        }
        if let tap = tapID {
            try check(AudioHardwareDestroyProcessTap(tap))
            tapID = nil
        }
        playbackControl = nil
        stopRequested = false
        retryFailureReported = false
        clientID = nil
        mirroredClient = nil
        captureState = nil
        captureFormat = nil
        peak = 0
        onStateChange?()
    }

    private func poll() {
        guard started, let state = captureState else { return }
        peak = state.peak.load(ordering: .relaxed)
        onLevel?(peak)
        guard let destination = sink?.destination else { return }
        // A failed restore does not authorize dropping the playback resources.
        // Retry at 10 Hz without repeatedly opening modal error dialogs.
        if stopRequested || restorationPending {
            do {
                if stopRequested { try stop() } else { try restoreOriginalPlayback() }
                retryFailureReported = false
            } catch {
                if !retryFailureReported { retryFailureReported = true; onFailure?(error) }
            }
            return
        }
        healthTick += 1
        do {
            if suppressionRequested, let transport = state.transport {
                let captured = state.lastPacket.load(ordering: .relaxed)
                let now = DispatchTime.now().uptimeNanoseconds
                guard transport.underruns.load(ordering: .relaxed) == suppressionUnderruns,
                      transport.isPlaybackReady(),
                      now &- captured <= 500_000_000 else {
                    throw Failure.playbackInterrupted
                }
            }
            guard healthTick % 5 == 0 else { return }
            try validatePlayback()
            if suppressionRequested { try playbackControl?.validateSuppression() }
            if exclusiveOutputPending && canSuppressOriginal {
                // The single owner consumes this one-shot request. Any failure
                // enters the same restoration-first Stop path as health faults.
                try suppressOriginalPlayback()
            }
        } catch let failure {
            do { try stop() }
            catch {
                retryFailureReported = true
                onFailure?(Failure.startAndCleanup(failure.localizedDescription, error.localizedDescription))
                return
            }
            // This notice is emitted ONLY after restoration and teardown
            // succeeded, never from a retained-resource cleanup failure.
            onStoppedOutput?(StoppedOutput(destination: destination, reason: failure))
        }
    }

    private func validatePlayback() throws {
        try sink?.validate()
        guard let tap = tapID, let original = captureFormat,
              SampleTransport.sameFormat(try tapFormat(tap), original) else { throw Failure.unsupportedFormat }
        if let client = mirroredClient, try AudioProcesses().stillContains(client) != true {
            throw Failure.changedClient
        }
        let last = max(captureStart, captureState?.lastPacket.load(ordering: .relaxed) ?? 0)
        if DispatchTime.now().uptimeNanoseconds &- last > 3_000_000_000 { throw Failure.captureStopped }
    }

    nonisolated static func makeCaptureBlock(state: CaptureState) -> AudioDeviceIOBlock {
        return { _, input, _, _, _ in
            if let transport = state.transport {
                guard transport.push(input) else { return }
                state.peak.store(transport.peak.load(ordering: .relaxed), ordering: .relaxed)
            } else {
                state.peak.store(peakLevel(input), ordering: .relaxed)
            }
            state.lastPacket.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        }
    }

    nonisolated static func peakLevel(_ input: UnsafePointer<AudioBufferList>) -> Float {
        var peak: Float = 0
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize % 4 == 0,
                  buffer.mDataByteSize <= 128 * 1024 else { continue }
            let samples = data.assumingMemoryBound(to: Float32.self)
            for index in 0..<Int(buffer.mDataByteSize / 4) {
                let sample = samples[index]
                if sample.isFinite { peak = max(peak, abs(sample)) }
            }
        }
        return min(1, peak)
    }

    private func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
        guard size == MemoryLayout<AudioStreamBasicDescription>.size else { throw Failure.unsupportedFormat }
        return format
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.coreAudio(status) }
    }
}
