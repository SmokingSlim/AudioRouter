---
type: mechanic
title: App routing and monitoring
status: implemented
tags: [routing, concurrency, monitor]
---

# App routing and monitoring

**Applications → output dropdown** targets an identified Core Audio client, not a display name or necessarily a whole browser/tab. Choosing hardware starts that client's owned route; no confirmation dialog or macOS default-output change.

## Rules

- Up to four registered owners, including at most one diagnostics monitor. Partial setup/failed cleanup consumes a slot until cleanup completes.
- Independent routes can choose distinct or shared outputs; no shared mutable capture/transport/lifecycle state. Specific live shared-output behavior is not separately certified.
- Same PID or HAL object cannot acquire a second capture while owned. Full lifetime identity selects the existing route; unknown lifetime blocks starts.
- Startup captures unmuted and pins replacement playback to the selected hardware. It requests original-output suppression only after [readiness](playback.md); duplicate audio is possible while waiting.
- Changing an existing hardware route restores/stops it first, then starts replacement only if cleanup succeeded, preserving its [PCM gain/mute](playback.md#gain-and-mute). Monitor or pending cleanup must be stopped via **Original output** before replacement.
- **Original output** stops only that app's route. A retained owner remains reachable even if its client disappears from active inventory; this is ownership context, not evidence of continued activity.
- There is no separate owned-route picker or engineering-button section. Each retained app row targets its own Original output restoration/cleanup action; unrelated routes remain usable within capacity when one faults. See [ADR-010](../adr/010-app-row-route-controls.md).
- Diagnostics **Monitor app only** uses an unmuted tap, no hardware sink, and one slot. Stop it before routing the same process.
- Inventory refresh never starts/reconnects a route. Device changes never retarget an existing sink to the default output.

## Owners and evidence

[AudioRoutes.select/start/stopAll](../../Sources/AudioRouter/AudioRoutes.swift) owns registry policy; [ProcessMeter.start](../../Sources/AudioRouter/ProcessMeter.swift) owns actual capture/playback lifecycle. [AudioRouterApp](../../Sources/AudioRouter/AudioRouterApp.swift) binds the native actions. [AudioRoutesTests](../../Tests/AudioRouterTests/AudioRoutesTests.swift) covers registry policy/controller actions with simulated owners.

See [ADR-002](../adr/002-bounded-route-owners.md), [identity](../architecture/identity.md), [restoration](restoration.md) and [verification](../architecture/verification.md). Basic concurrency is user-reported working; simulations are not real-HAL failure certification.
