---
type: mechanic
title: PCM playback and readiness
status: implemented
tags: [pcm, callbacks, buffering, readiness, performance]
---

# PCM playback and readiness

Prototype playback, not a production-fidelity guarantee. [SampleTransport](../../Sources/AudioRouter/SampleTransport.swift) owns format/layout parsing, FIFO/SRC and atomic readiness; [PlaybackSink](../../Sources/AudioRouter/PlaybackSink.swift) owns the destination-pinned AUHAL output.

## Formats and storage

Source: packed native-endian Float32 stereo, interleaved or planar, 32–96 kHz. Destination: stereo hardware at 32–96 kHz; Float32 planar client output at the device's native rate. No hardware sample-rate write. Known hardware destinations only; software/aggregate/unknown outputs and self-capture are excluded.

One serial capture producer and one render consumer per transport. Preallocated 16,384-frame stereo FIFO: 128 KiB per hardware route, at most 512 KiB across four owners; HAL/AU allocation is additional and unmeasured. Render slices are bounded to 8,192 frames. Callback storage outlives callback disposal; no locks, allocation, UI or actor hops in callbacks.

## Timing and discontinuities

Target FIFO occupancy is approximately 40 ms **plus** capture/hardware/Bluetooth latency. Linear-interpolation SRC is not anti-aliased or production-quality; occupancy-based clock drift adjustment is bounded to ±0.5% and remains unmeasured live.

Overflow discards the newest whole packet; excessive backlog is trimmed by the consumer. Underrun silences the remaining output and re-primes. These discontinuities can click; no discontinuity concealment exists. Finite input PCM, including values above 1, is preserved before output gain; nonfinite input samples become silence. There is no limiter.

## Gain and mute

Owned hardware routes expose a 0–100% linear PCM gain slider and separate Mute checkbox. Default is 100%, unmuted; mute retains gain for unmute. Controls are disabled during Stop or pending restoration and unavailable for original-output/monitor-only rows. They affect replacement PCM only, never hardware volume, capture peaks or restored original playback. During startup or lifecycle restoration, original playback remains outside these controls. **Original output** restores/stops the route; there is no manual keep-mirror restoration control.

[PlaybackLevel](../../Sources/AudioRouter/PlaybackLevel.swift) validates finite gain in 0–1. [ProcessMeter](../../Sources/AudioRouter/ProcessMeter.swift) owns the level; [AudioRoutes](../../Sources/AudioRouter/AudioRoutes.swift) resolves the full client lifetime and gates actions. An explicit hardware destination switch preserves the owned level and initializes replacement transport before callbacks start; a new route after Stop returns to unity/unmuted. Failed cleanup retains the owner's level.

The transport publishes one atomic effective target; only the render consumer owns its current gain. Gain is applied after SRC using a 10 ms destination-rate linear ramp, continuing across slices and retargeting from the current value. This avoids abrupt gain steps, not all audible clicks. PCM consumption/progress continues at zero gain. Slider drags read back PCM controls without inventory/menu rebuilds or panel resizing. See [ADR-009](../adr/009-per-route-pcm-level.md).

## Readiness

Suppression requires at least 100 ms of rendered PCM, capture/render timestamps no older than 0.5 seconds, no render fault and at least one second since any underrun. `ProcessMeter.canSuppressOriginal` combines transport facts with lifecycle/capture freshness. Progress is not proof of hardware audibility; zero gain/mute does not count as lack of progress.

## Evidence and next work

[SampleTransportTests](../../Tests/AudioRouterTests/SampleTransportTests.swift) executes production callbacks, malformed PCM, SRC, FIFO pairing, independent levels/transports, destination-rate gain ramps, mid-ramp changes, mute/unmute readiness and concurrent target updates off-main. [AudioRoutesTests](../../Tests/AudioRouterTests/AudioRoutesTests.swift) exercises native controls and level retention/identity/failure guards with simulated owners. These do not measure real device latency, clock drift or audible fidelity. See [verification](../architecture/verification.md#per-app-gainmute) and [current work](../todo.md).
