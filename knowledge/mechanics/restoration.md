---
type: mechanic
title: Original playback restoration and recovery
status: implemented
tags: [suppression, restoration, cleanup, safety]
---

# Original playback restoration and recovery

## Suppression obligation

[TapPlaybackControl](../../Sources/AudioRouter/TapPlaybackControl.swift) verifies the tap UUID and writability, preserves unrelated description fields and records `restorationRequired` **before** writing `mutedWhenTapped`. A failed write may have taken effect. Only confirmed unmuted readback clears the obligation; an uncertain write never proves original playback stayed unmuted.

Startup remains unmuted. [ProcessMeter](../../Sources/AudioRouter/ProcessMeter.swift) consumes the one-shot deferred request after [playback readiness](playback.md) and revalidates device/client/format before and after suppression. Confirmed property state is “suppression requested,” not proof of audible routing. Suppression failure enters restoration-first Stop rather than repeated suppression attempts.

## Controls and teardown

- Each app's **Original output** choice cancels deferred suppression and restores before disabling transport, stopping capture/sink or destroying resources. The same action stops capture-only monitors.
- Manual keep-mirror restoration and re-suppression buttons are removed; explicitly stop and select hardware again to restart exclusive routing. See [ADR-010](../adr/010-app-row-route-controls.md).
- Failed restoration retains replacement resources and, when active, the health timer. Retry **Original output** on the retained app row; partial/failed teardown retains remaining handles/refcons.
- Successful teardown releases capture/playback resources. A completed recovery notice is emitted only after successful restoration and cleanup, never for pending failure.
- Quit attempts every owner and collects errors. Any failure cancels termination; remaining ownership/identity/slots stay available for retry.

## Health and recovery

Hardware owners poll stream/retry state at 10 Hz and device/client/format validity at 2 Hz while the main run loop runs. New underrun, render fault, stale stream progress or failed live validation while suppressed triggers restoration/Stop. No capture callbacks for three seconds also stops hardware mirroring.

The controller stops a disappeared client only on confirmed absence/change; unknown lifetime is not absence. No automatic reconnect or fallback output. Main-thread/modal stalls can delay detection/retries; seamless or guaranteed fail-open recovery is not claimed.

## Owners and tests

- [ProcessMeter.stop/poll](../../Sources/AudioRouter/ProcessMeter.swift): teardown/retry and completed notice production.
- [PlaybackSink.stop](../../Sources/AudioRouter/PlaybackSink.swift): refcon/transport remains retained through successful disposal.
- [AudioRoutes.stopAll](../../Sources/AudioRouter/AudioRoutes.swift): all-owner attempts; [AudioRouterApp.applicationShouldTerminate](../../Sources/AudioRouter/AudioRouterApp.swift): Quit cancellation.
- [TapPlaybackControlTests](../../Tests/AudioRouterTests/TapPlaybackControlTests.swift) and [AudioRoutesTests](../../Tests/AudioRouterTests/AudioRoutesTests.swift): simulated property/lifecycle failure coverage, not full real-HAL teardown.

See [ADR-003](../adr/003-restoration-before-teardown.md) and [verification limits](../architecture/verification.md).
