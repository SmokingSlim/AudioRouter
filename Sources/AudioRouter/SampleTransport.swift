import CoreAudio
import Foundation
import Synchronization

/// One serial capture producer, one HAL render consumer. Storage is allocated
/// before either callback starts. Indices, status and effective gain cross
/// threads atomically; cursors and gain ramps have one owning callback.
/// No locks, Tasks, or allocations in push/render.
final class SampleTransport: @unchecked Sendable {
    static let capacity = 16_384 // stereo frames, 128 KiB
    let peak = Atomic<Float>(0)
    let enabled = Atomic<Bool>(true)
    let overruns = Atomic<Int>(0)
    let underruns = Atomic<Int>(0)
    let lastUnderrun = Atomic<UInt64>(0)
    let lastRender = Atomic<UInt64>(0)
    let renderedFrames = Atomic<UInt64>(0)
    let renderFault = Atomic<Bool>(false)
    private let readinessFrames: UInt64
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let samples: UnsafeMutablePointer<Float>
    private let planar: Bool
    private let ratio: Double
    private let target: Int
    private var phase: Double = 0 // consumer only
    private var primed = false // consumer only
    private let gainTarget: Atomic<Float>
    private let rampFrames: Int
    private var currentGain: Float // consumer only
    private var rampTarget: Float // consumer only
    private var rampRemaining = 0 // consumer only
    private var gainStep: Float = 0 // consumer only

    func setLevel(_ level: PlaybackLevel) {
        gainTarget.store(level.effectiveGain, ordering: .relaxed)
    }

    init(format: AudioStreamBasicDescription, outputRate: Double, level: PlaybackLevel = .unity) {
        gainTarget = Atomic(level.effectiveGain)
        currentGain = level.effectiveGain
        rampTarget = level.effectiveGain
        rampFrames = max(1, Int(outputRate * 0.01))
        readinessFrames = UInt64(outputRate * 0.1)
        planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        ratio = format.mSampleRate / outputRate
        target = Int(format.mSampleRate * 0.04) // ~40 ms plus device/capture latency
        samples = .allocate(capacity: Self.capacity * 2)
        samples.initialize(repeating: 0, count: Self.capacity * 2)
    }

    deinit { samples.deinitialize(count: Self.capacity * 2); samples.deallocate() }

    static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID &&
            a.mFormatFlags == b.mFormatFlags && a.mBytesPerPacket == b.mBytesPerPacket &&
            a.mFramesPerPacket == b.mFramesPerPacket && a.mBytesPerFrame == b.mBytesPerFrame &&
            a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
    }

    static func supports(_ format: AudioStreamBasicDescription) -> Bool {
        let allowed = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        return format.mFormatID == kAudioFormatLinearPCM &&
            format.mFormatFlags & ~allowed == 0 &&
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
            format.mFormatFlags & kAudioFormatFlagIsPacked != 0 &&
            format.mBitsPerChannel == 32 && format.mChannelsPerFrame == 2 &&
            format.mFramesPerPacket == 1 &&
            format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 4 : 8) &&
            format.mBytesPerPacket == format.mBytesPerFrame &&
            format.mSampleRate.isFinite && (32_000...96_000).contains(format.mSampleRate)
    }

    @discardableResult
    func push(_ input: UnsafePointer<AudioBufferList>) -> Bool {
        guard enabled.load(ordering: .relaxed) else { return false }
        guard input.pointee.mNumberBuffers == (planar ? 2 : 1) else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count == (planar ? 2 : 1),
              buffers[0].mNumberChannels == (planar ? 1 : 2),
              let leftData = buffers[0].mData,
              buffers[0].mDataByteSize % (planar ? 4 : 8) == 0 else { return false }
        let frames = Int(buffers[0].mDataByteSize) / (planar ? 4 : 8)
        guard frames > 0, frames <= Self.capacity else { return false }
        let left = leftData.assumingMemoryBound(to: Float.self)
        let right: UnsafeMutablePointer<Float>
        if planar {
            guard buffers[1].mNumberChannels == 1,
                  buffers[1].mDataByteSize == buffers[0].mDataByteSize,
                  let data = buffers[1].mData else { return false }
            right = data.assumingMemoryBound(to: Float.self)
        } else { right = left.advanced(by: 1) }
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        // Drop the entire newest packet on overflow; never overwrite unread
        // storage or move the consumer's cursor from the producer thread.
        guard frames <= Self.capacity - (w &- r) else {
            overruns.wrappingAdd(1, ordering: .relaxed)
            return true // valid capture, but no buffer space
        }
        var level: Float = 0
        let stride = planar ? 1 : 2
        for frame in 0..<frames {
            let l = left[frame * stride], rr = right[frame * stride]
            // Preserve pre-gain PCM (including >1 peaks); invalid PCM
            // becomes silence rather than poisoning the output pipeline.
            let a = l.isFinite ? l : 0, b = rr.isFinite ? rr : 0
            let index = ((w &+ frame) & (Self.capacity - 1)) * 2
            samples[index] = a; samples[index + 1] = b
            level = max(level, max(abs(a), abs(b)))
        }
        peak.store(min(1, level), ordering: .relaxed)
        written.store(w &+ frames, ordering: .releasing)
        return true
    }

    func isPlaybackReady(now requestedNow: UInt64? = nil) -> Bool {
        let rendered = lastRender.load(ordering: .acquiring)
        let underrun = lastUnderrun.load(ordering: .relaxed)
        let count = renderedFrames.load(ordering: .relaxed)
        let active = enabled.load(ordering: .relaxed)
        let fault = renderFault.load(ordering: .relaxed)
        // Read callback timestamps BEFORE taking the comparison clock. A HAL
        // callback can otherwise publish a newer timestamp than the caller's
        // pre-snapshot 'now', causing unsigned elapsed-time underflow.
        let now = requestedNow ?? DispatchTime.now().uptimeNanoseconds
        return active && !fault &&
            count >= readinessFrames && rendered != 0 &&
            now &- rendered <= 500_000_000 && (underrun == 0 || now &- underrun >= 1_000_000_000)
    }

    /// Destination-native Float32 stereo, noninterleaved. Linear interpolation
    /// is deliberately a prototype SRC (not mastering-quality/anti-aliased).
    /// Bounded +/-0.5% rate adjustment follows FIFO occupancy for clock drift.
    /// A large backlog is discarded by the consumer; underruns re-prime and
    /// output silence. Neither callback waits for the other clock.
    @discardableResult
    func render(_ output: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> OSStatus {
        guard frames > 0, frames <= 8192, output.pointee.mNumberBuffers == 2 else {
            renderFault.store(true, ordering: .relaxed)
            return kAudio_ParamError
        }
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard buffers[0].mNumberChannels == 1, buffers[1].mNumberChannels == 1,
              Int(buffers[0].mDataByteSize) >= frames * 4, buffers[0].mDataByteSize <= 8192 * 4,
              Int(buffers[1].mDataByteSize) >= frames * 4, buffers[1].mDataByteSize <= 8192 * 4,
              let a = buffers[0].mData, let b = buffers[1].mData else {
            renderFault.store(true, ordering: .relaxed)
            return kAudio_ParamError
        }
        memset(a, 0, frames * 4)
        memset(b, 0, frames * 4)
        guard enabled.load(ordering: .relaxed) else { return noErr }
        let left = a.assumingMemoryBound(to: Float.self), right = b.assumingMemoryBound(to: Float.self)
        let w = written.load(ordering: .acquiring)
        var r = read.load(ordering: .relaxed)
        var available = w &- r
        if available > target * 3 {
            r = w &- target
            phase = 0
            available = target
        }
        if !primed {
            guard available >= target else { read.store(r, ordering: .releasing); return noErr }
            primed = true
        }
        let correction = min(0.005, max(-0.005, Double(available - target) / Double(target) * 0.001))
        let step = ratio * (1 + correction)
        let requestedGain = gainTarget.load(ordering: .relaxed)
        if requestedGain != rampTarget {
            rampTarget = requestedGain
            rampRemaining = rampFrames
            gainStep = (rampTarget - currentGain) / Float(rampFrames)
        }
        var rendered = 0
        for frame in 0..<frames {
            let advance = Int(phase + step)
            guard available >= max(2, advance) else {
                primed = false
                phase = 0
                underruns.wrappingAdd(1, ordering: .relaxed)
                lastUnderrun.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
                break
            }
            let i = (r & (Self.capacity - 1)) * 2
            let j = ((r &+ 1) & (Self.capacity - 1)) * 2
            let fraction = Float(phase)
            if rampRemaining > 0 {
                rampRemaining -= 1
                currentGain = rampRemaining == 0 ? rampTarget : currentGain + gainStep
            }
            left[frame] = (samples[i] * (1 - fraction) + samples[j] * fraction) * currentGain
            right[frame] = (samples[i + 1] * (1 - fraction) + samples[j + 1] * fraction) * currentGain
            phase += step
            let consumed = Int(phase)
            phase -= Double(consumed)
            r = r &+ consumed
            available -= consumed
            rendered += 1
        }
        read.store(r, ordering: .releasing)
        if rendered > 0 {
            renderedFrames.wrappingAdd(UInt64(rendered), ordering: .relaxed)
            lastRender.store(DispatchTime.now().uptimeNanoseconds, ordering: .releasing)
        }
        return noErr
    }
}
