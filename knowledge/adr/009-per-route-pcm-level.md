---
type: adr
title: Per-route PCM gain and mute
status: accepted
tags: [pcm, routing, callbacks, interaction]
---

# ADR-009: Per-route PCM gain and mute

## Context

The user authorized the gain/mute backlog item. Implementation choices below do not authorize live capture, playback or host-setting writes.

## Decision

- Each lifecycle owner owns a validated gain (0–1, default unity) and separate mute flag. No boost, limiter, persistence or hardware-volume writes.
- Publish one effective target atomically to the transport. The render consumer alone owns ramp state; use a 10 ms linear ramp at destination sample rate, continuing across callback slices and retargeting from current gain. Apply gain after SRC, not at capture; input peaks remain pre-gain.
- Zero gain/mute still consumes PCM and publishes rendered progress. Existing readiness, suppression and restoration rules stay unchanged. Gain controls affect replacement PCM only: original playback after restoration is outside their authority.
- App rows expose controls only for owned hardware routes, enabled while running and not stopping/restoration-pending. Monitor-only and original-output rows cannot change gain. Keep native control identity and fresh lifetime client payloads.
- Preserve level when explicitly switching an existing hardware route; new routes start at unity/unmuted. Failed cleanup retains level with its owner. Set initial level before starting replacement callbacks.

Owners: [PlaybackLevel](../../Sources/AudioRouter/PlaybackLevel.swift), [SampleTransport](../../Sources/AudioRouter/SampleTransport.swift), [ProcessMeter](../../Sources/AudioRouter/ProcessMeter.swift), [AudioRoutes](../../Sources/AudioRouter/AudioRoutes.swift), [ApplicationAudioRow](../../Sources/AudioRouter/AudioPopover.swift) and [AudioRouterApp](../../Sources/AudioRouter/AudioRouterApp.swift). Tests: [SampleTransportTests](../../Tests/AudioRouterTests/SampleTransportTests.swift), [AudioRoutesTests](../../Tests/AudioRouterTests/AudioRoutesTests.swift).

## Consequences

No callback allocation, locks, UI calls or actor hops; one target load per render slice and bounded arithmetic per rendered frame. A ramp avoids abrupt gain steps, not existing FIFO/SRC discontinuities or all audible clicks. Debug/release builds and warnings-as-errors debug/optimized/Thread Sanitizer suites passed. Native control actions and simulated ownership/property tests establish policy without live capture or host writes; callback tests establish ramps and muted progress. See [verification](../architecture/verification.md#per-app-gainmute) for synthetic cost measurements and unverified live audibility/performance. No separate related cleanup remains identified; existing SRC/FIFO discontinuities are unchanged. Reconsider gain range/curve or shared-output mixing only as separate scope.

## Alternatives

- Hardware volume: affects unrelated apps and violates per-app authority.
- Capture-side gain: delays changes behind queued PCM and conflates input metering with output policy.
- Immediate steps: introduce avoidable discontinuities.
- Independent gain/mute callback atomics: can publish mixed control state; publish the computed target instead.
