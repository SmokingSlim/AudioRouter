import AudioToolbox
import CoreAudio
import Foundation

struct SampleTransportTests {
    static func format(rate: Double = 48_000, planar: Bool = false) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: planar ? 4 : 8, mFramesPerPacket: 1, mBytesPerFrame: planar ? 4 : 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }

    static func push(_ ring: SampleTransport, frames: Int, left: Float = -0.75, right: Float = 0.25) {
        var pcm = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { pcm[i * 2] = left; pcm[i * 2 + 1] = right }
        pcm.withUnsafeMutableBufferPointer { storage in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: storage.baseAddress))
            withUnsafePointer(to: &list) { _ = ring.push($0) }
        }
    }

    static func withOutput(frames: Int, _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void) -> ([Float], [Float]) {
        var left = [Float](repeating: 99, count: frames), right = left
        left.withUnsafeMutableBufferPointer { a in
            right.withUnsafeMutableBufferPointer { b in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { list.unsafeMutablePointer.deallocate() }
                list.unsafeMutablePointer.pointee.mNumberBuffers = 2
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: a.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: b.baseAddress)
                body(list.unsafeMutablePointer)
            }
        }
        return (left, right)
    }

    @MainActor
    static func run() {
        precondition(SampleTransport.supports(format()))
        precondition(SampleTransport.supports(format(planar: true)))
        var invalid = format(); invalid.mSampleRate = .nan
        precondition(!SampleTransport.supports(invalid))
        invalid = format(); invalid.mChannelsPerFrame = 1
        precondition(!SampleTransport.supports(invalid))
        invalid = format(); invalid.mBytesPerFrame = 4
        precondition(!SampleTransport.supports(invalid))
        invalid = format(); invalid.mFormatFlags |= kAudioFormatFlagIsBigEndian
        precondition(!SampleTransport.supports(invalid))
        precondition(SampleTransport.sameFormat(format(), format()))
        precondition(!SampleTransport.sameFormat(format(), format(rate: 44_100)))
        precondition(!SampleTransport.sameFormat(format(), format(planar: true)))

        precondition(PlaybackLevel(gain: .nan, muted: false) == nil)
        precondition(PlaybackLevel(gain: .infinity, muted: false) == nil)
        precondition(PlaybackLevel(gain: -0.1, muted: false) == nil)
        precondition(PlaybackLevel(gain: 1.1, muted: false) == nil)
        for rate in [32_000.0, 48_000.0, 96_000.0] {
            let gain = SampleTransport(format: format(rate: rate), outputRate: rate)
            push(gain, frames: Int(rate * 0.04) + 1024, left: 1, right: -1)
            gain.setLevel(PlaybackLevel(gain: 0.5, muted: false)!)
            let duration = Int(rate * 0.01)
            let first = withOutput(frames: duration / 2) { gain.render($0, frames: duration / 2) }
            let second = withOutput(frames: duration - duration / 2) { gain.render($0, frames: duration - duration / 2) }
            let ramp = first.0 + second.0
            for i in 0..<duration {
                precondition(abs(ramp[i] - (1 - Float(i + 1) / Float(duration) * 0.5)) < 0.00003)
            }
            precondition(first.1 == first.0.map { -$0 } && second.1 == second.0.map { -$0 })
            gain.setLevel(PlaybackLevel(gain: 0.5, muted: true)!)
            push(gain, frames: duration)
            let fade = withOutput(frames: duration) { gain.render($0, frames: duration) }
            precondition(abs(fade.0[0] - (0.5 - 0.5 / Float(duration))) < 0.00003 && fade.0.last == 0)
            // Muted PCM still advances readiness, without starving capture.
            for _ in 0..<24 {
                push(gain, frames: 512, left: 1, right: -1)
                let silent = withOutput(frames: 512) { gain.render($0, frames: 512) }
                precondition(silent.0.allSatisfy { $0 == 0 } && silent.1.allSatisfy { $0 == 0 })
            }
            precondition(gain.isPlaybackReady() && gain.underruns.load(ordering: .relaxed) == 0)
            gain.setLevel(PlaybackLevel(gain: 0.5, muted: false)!)
            push(gain, frames: duration)
            let unmute = withOutput(frames: duration) { gain.render($0, frames: duration) }
            precondition(abs(unmute.0[0] - 0.5 / Float(duration)) < 0.00003 && unmute.0.last == 0.5)
        }
        // Retarget partway through a fade, starting at the current gain.
        let retarget = SampleTransport(format: format(), outputRate: 48_000)
        push(retarget, frames: 4096, left: 1, right: -1)
        retarget.setLevel(PlaybackLevel(gain: 0, muted: false)!)
        let partial = withOutput(frames: 240) { retarget.render($0, frames: 240) }
        let halfway = partial.0.last!
        precondition(abs(halfway - 0.5) < 0.00003)
        retarget.setLevel(.unity)
        let back = withOutput(frames: 480) { retarget.render($0, frames: 480) }
        precondition(abs(back.0[0] - (halfway + (1 - halfway) / 480)) < 0.00003 && back.0.last == 1)
        let initiallyMuted = SampleTransport(format: format(), outputRate: 48_000,
            level: PlaybackLevel(gain: 0.3, muted: true)!)
        push(initiallyMuted, frames: 2048)
        precondition(withOutput(frames: 64) { initiallyMuted.render($0, frames: 64) }.0.allSatisfy { $0 == 0 })

        let ring = SampleTransport(format: format(), outputRate: 48_000)
        precondition(!ring.isPlaybackReady(now: DispatchTime.now().uptimeNanoseconds))
        let empty = withOutput(frames: 64) { precondition(ring.render($0, frames: 64) == noErr) }
        precondition(empty.0.allSatisfy { $0 == 0 } && empty.1.allSatisfy { $0 == 0 })
        push(ring, frames: 2048)
        let pcm = withOutput(frames: 64) { output in
            var time = AudioTimeStamp(), flags: AudioUnitRenderActionFlags = []
            withUnsafePointer(to: &time) { timestamp in
                withUnsafeMutablePointer(to: &flags) { flagPointer in
                    DispatchQueue(label: "app.soundtool.local.test.render").sync {
                        precondition(PlaybackSink.renderCallback(Unmanaged.passUnretained(ring).toOpaque(),
                            flagPointer, timestamp, 0, 64, output) == noErr)
                    }
                }
            }
        }
        precondition(pcm.0.allSatisfy { abs($0 + 0.75) < 0.00001 })
        precondition(pcm.1.allSatisfy { abs($0 - 0.25) < 0.00001 })
        let drained = withOutput(frames: 4096) { ring.render($0, frames: 4096) }
        precondition(drained.0.last == 0 && ring.underruns.load(ordering: .relaxed) == 1)
        precondition(ring.lastUnderrun.load(ordering: .relaxed) != 0)
        precondition(!ring.isPlaybackReady(now: DispatchTime.now().uptimeNanoseconds))
        push(ring, frames: 16)
        let reprime = withOutput(frames: 64) { ring.render($0, frames: 64) }
        precondition(reprime.0.allSatisfy { $0 == 0 })
        ring.enabled.store(false, ordering: .releasing)
        let stopped = withOutput(frames: 64) { ring.render($0, frames: 64) }
        precondition(stopped.0.allSatisfy { $0 == 0 })

        let overflow = SampleTransport(format: format(), outputRate: 48_000)
        push(overflow, frames: SampleTransport.capacity, left: 1.5, right: .nan)
        push(overflow, frames: 1)
        precondition(overflow.overruns.load(ordering: .relaxed) == 1)
        let sanitized = withOutput(frames: 64) { overflow.render($0, frames: 64) }
        precondition(sanitized.0.allSatisfy { $0 == 1.5 }) // no hidden gain/clamp
        precondition(sanitized.1.allSatisfy { $0 == 0 })

        let planar = SampleTransport(format: format(planar: true), outputRate: 44_100)
        var left = [Float](repeating: -0.4, count: 2048), right = [Float](repeating: 0.2, count: 2048)
        left.withUnsafeMutableBufferPointer { a in
            right.withUnsafeMutableBufferPointer { b in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { list.unsafeMutablePointer.deallocate() }
                list.unsafeMutablePointer.pointee.mNumberBuffers = 2
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048 * 4, mData: a.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048 * 4, mData: b.baseAddress)
                let state = CaptureState(transport: planar)
                let capture = ProcessMeter.makeCaptureBlock(state: state)
                var time = AudioTimeStamp()
                withUnsafePointer(to: &time) { timestamp in
                    DispatchQueue(label: "app.soundtool.local.test.capture").sync {
                        capture(timestamp, UnsafePointer(list.unsafeMutablePointer), timestamp, list.unsafeMutablePointer, timestamp)
                    }
                }
                precondition(abs(state.peak.load(ordering: .relaxed) - 0.4) < 0.00001)
            }
        }
        let converted = withOutput(frames: 256) { planar.render($0, frames: 256) }
        precondition(converted.0.allSatisfy { abs($0 + 0.4) < 0.00001 })
        precondition(converted.1.allSatisfy { abs($0 - 0.2) < 0.00001 })

        // Ramp verifies fractional resampling, not just constant passthrough.
        let resample = SampleTransport(format: format(rate: 44_100), outputRate: 48_000)
        var ramp = (0..<4096).map { Float($0 / 2) / 4096 }
        ramp.withUnsafeMutableBufferPointer { storage in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 4096 * 4, mData: storage.baseAddress))
            withUnsafePointer(to: &list) { _ = resample.push($0) }
        }
        let interpolated = withOutput(frames: 128) { resample.render($0, frames: 128) }
        let nominal = Float(44_100.0 / 48_000.0 / 4096.0)
        let delta = interpolated.0[100] - interpolated.0[99]
        precondition(abs(delta - nominal) < nominal * 0.006)
        precondition(interpolated.0 == interpolated.1)

        // Malformed callback data must not be read or count as live capture.
        let malformed = SampleTransport(format: format(), outputRate: 48_000)
        var single: Float = 1
        withUnsafeMutablePointer(to: &single) { data in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 7, mData: data))
            withUnsafePointer(to: &list) { precondition(!malformed.push($0)) }
            list.mBuffers.mDataByteSize = UInt32((SampleTransport.capacity + 1) * 8)
            withUnsafePointer(to: &list) { precondition(!malformed.push($0)) }
        }
        let short = withOutput(frames: 64) { output in
            output.pointee.mBuffers.mDataByteSize = 4
            precondition(malformed.render(output, frames: 64) == kAudio_ParamError)
        }
        precondition(short.0.allSatisfy { $0 == 99 })
        precondition(malformed.renderFault.load(ordering: .relaxed))

        let wrapped = SampleTransport(format: format(), outputRate: 48_000)
        push(wrapped, frames: 2048, left: 0.5, right: -0.5)
        for _ in 0..<2000 {
            push(wrapped, frames: 256, left: 0.5, right: -0.5)
            let pair = withOutput(frames: 256) { wrapped.render($0, frames: 256) }
            precondition(pair.0.allSatisfy { $0 == 0.5 } && pair.1.allSatisfy { $0 == -0.5 })
        }
        precondition(wrapped.overruns.load(ordering: .relaxed) == 0)
        precondition(wrapped.underruns.load(ordering: .relaxed) == 0)
        let now = DispatchTime.now().uptimeNanoseconds
        precondition(wrapped.renderedFrames.load(ordering: .relaxed) == 512_000)
        precondition(wrapped.isPlaybackReady(now: now))
        precondition(!wrapped.isPlaybackReady(now: now + 600_000_000))
        wrapped.enabled.store(false, ordering: .releasing)
        precondition(!wrapped.isPlaybackReady(now: now))

        // Repeated wraparound with truly concurrent producer and consumer.
        // Each frame's channels must remain a pair even across publication.
        let concurrent = SampleTransport(format: format(), outputRate: 48_000)
        let group = DispatchGroup()
        DispatchQueue(label: "app.soundtool.local.test.producer").async(group: group) {
            for packet in 0..<4000 {
                let value = Float(packet % 100) / 100
                push(concurrent, frames: 256, left: value, right: -value)
            }
        }
        DispatchQueue(label: "app.soundtool.local.test.consumer").async(group: group) {
            for _ in 0..<4000 {
                let pair = withOutput(frames: 256) { concurrent.render($0, frames: 256) }
                for i in 0..<256 { precondition(abs(pair.0[i] + pair.1[i]) < 0.00001) }
            }
        }
        DispatchQueue(label: "app.soundtool.local.test.gain").async(group: group) {
            for i in 0..<4000 {
                concurrent.setLevel(PlaybackLevel(gain: Float(i % 101) / 100, muted: i % 3 == 0)!)
            }
        }
        precondition(group.wait(timeout: .now() + 10) == .success)

        // Two independent production capture/render callback paths run at the
        // same time with different channel values. Disabling one transport
        // must not silence or alter the other's PCM or readiness/counters.
        let isolatedA = CaptureState(transport: SampleTransport(format: format(), outputRate: 48_000))
        let isolatedB = CaptureState(transport: SampleTransport(format: format(), outputRate: 48_000,
            level: PlaybackLevel(gain: 0.5, muted: false)!))
        let isolatedGroup = DispatchGroup()
        for (state, value, disable) in [(isolatedA, Float(0.3), true), (isolatedB, Float(0.7), false)] {
            DispatchQueue(label: "app.soundtool.local.test.isolated.\(value)").async(group: isolatedGroup) {
                let transport = state.transport!
                let capture = ProcessMeter.makeCaptureBlock(state: state)
                var samples = [Float](repeating: 0, count: 2048 * 2)
                for index in 0..<2048 { samples[index * 2] = value; samples[index * 2 + 1] = -value }
                samples.withUnsafeMutableBufferPointer { pcm in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                        mDataByteSize: 2048 * 8, mData: pcm.baseAddress))
                    var time = AudioTimeStamp(), unusedOutput = AudioBufferList()
                    withUnsafePointer(to: &time) { timestamp in
                        withUnsafePointer(to: &list) { input in
                            withUnsafeMutablePointer(to: &unusedOutput) { output in
                                capture(timestamp, input, timestamp, output, timestamp)
                            }
                        }
                    }
                    list.mBuffers.mDataByteSize = 256 * 8
                    for iteration in 0..<1000 {
                        if disable && iteration == 500 { transport.enabled.store(false, ordering: .releasing) }
                        withUnsafePointer(to: &time) { timestamp in
                            withUnsafePointer(to: &list) { input in
                                withUnsafeMutablePointer(to: &unusedOutput) { output in
                                    capture(timestamp, input, timestamp, output, timestamp)
                                }
                            }
                        }
                        let pair = withOutput(frames: 256) { output in
                            var flags: AudioUnitRenderActionFlags = []
                            withUnsafeMutablePointer(to: &flags) { flagPointer in
                                withUnsafePointer(to: &time) { timestamp in
                                    precondition(PlaybackSink.renderCallback(Unmanaged.passUnretained(transport).toOpaque(),
                                        flagPointer, timestamp, 0, 256, output) == noErr)
                                }
                            }
                        }
                        let expected: Float = disable ? (iteration >= 500 ? 0 : value) : value * 0.5
                        precondition(pair.0.allSatisfy { abs($0 - expected) < 0.00001 })
                        precondition(pair.1.allSatisfy { abs($0 + expected) < 0.00001 })
                    }
                }
                if !disable {
                    precondition(transport.underruns.load(ordering: .relaxed) == 0)
                    precondition(transport.overruns.load(ordering: .relaxed) == 0)
                    precondition(transport.isPlaybackReady())
                }
            }
        }
        precondition(isolatedGroup.wait(timeout: .now() + 10) == .success)

        // Fail closed before creating output resources for ambiguous/software
        // destinations, without changing system output or starting capture.
        let invalidDevice = AudioDevice(id: 0, name: "Not a hardware device", uid: nil, transport: kAudioDeviceTransportTypeAggregate, direction: .output,
            supportsVolume: false, supportsMute: false, canBeDefault: false, canBeSoundEffects: false)
        precondition(!invalidDevice.isMirrorDestination)
        let sink = PlaybackSink(destination: invalidDevice)
        do { try sink.prepare(sourceFormat: format()); preconditionFailure("Accepted invalid destination") }
        catch { precondition(!sink.hasResources) }
        try! sink.stop()
        print("Stereo transport, SRC, bounded gain/mute ramps, muted readiness, concurrent level updates, silence, bounds, backpressure, wraparound, independent off-main capture/render, destination rejection: passed")
    }
}
