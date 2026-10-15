---
type: architecture
title: Code and resource ownership
status: implemented
tags: [ownership, lifecycle, callbacks]
---

# Code and resource ownership

Single Swift executable package; no new layers or parallel audio engine were introduced by the knowledge structure.

| Owner | Responsibility |
| --- | --- |
| [main.swift](../../Sources/AudioRouter/main.swift) | Launch-only AppKit entry point |
| [AudioRouterApp](../../Sources/AudioRouter/AudioRouterApp.swift) | Status item/popover, typed actions, refresh-local client display records, inventory/selection, completed-Stop notices, error queue and Quit; no HAL resource ownership |
| [AudioPopover](../../Sources/AudioRouter/AudioPopover.swift) | Native controls, display/menu snapshots, focus, scrolling and accessibility |
| [AudioRoutes](../../Sources/AudioRouter/AudioRoutes.swift) | Bounded registry, duplicate/monitor/start policy, independent replacement and all-owner Quit |
| [RoutePresentation](../../Sources/AudioRouter/RoutePresentation.swift) | Interprets one owner's lifecycle/readiness for UI |
| [AudioDevices](../../Sources/AudioRouter/AudioDevices.swift) | Shared typed HAL property parsing, device/role facts, System writes and destination validation |
| [AudioProcesses](../../Sources/AudioRouter/AudioProcesses.swift) | Read-only client inventory and lifetime identity |
| [ProcessMeter](../../Sources/AudioRouter/ProcessMeter.swift) | Sole lifecycle owner per route: tap, private aggregate, capture IOProc, transport/sink, health and restoration-first Stop |
| [TapPlaybackControl](../../Sources/AudioRouter/TapPlaybackControl.swift) | UUID-checked tap description writes/readback and restoration obligation; never a separate tap |
| [PlaybackSink](../../Sources/AudioRouter/PlaybackSink.swift) | Device-pinned AUHAL output; one size-checked Audio Unit reader including running state; callback storage retained until disposal succeeds |
| [SampleTransport](../../Sources/AudioRouter/SampleTransport.swift) | Preallocated SPSC PCM FIFO, layout/format checks, prototype SRC/drift and atomic progress/counters |

Client display ownership and snapshot lifetime: [ADR-008](../adr/008-refresh-local-client-display.md). The controller shares one refresh-local name/icon record between inventory consumers; the row retains the original parsed client and sends its refreshed metadata through its creation-time callback. Display enrichment is not capture identity.

## Control and data paths

AppKit action → controller → registry policy → per-route lifecycle → HAL/tap/output unit. Explicit System actions instead go from controller to `AudioDevices`; routing never writes a macOS default selector.

Lifecycle and UI coordination run on the main actor. Capture/render callbacks run off-main and exchange bounded PCM/progress through preallocated storage and atomics; no callback allocations, locks, UI work or actor hops. `CaptureState` bridges capture progress; `PlaybackSink.renderCallback` receives the retained transport refcon.

Install registry/lifecycle ownership **before** partial setup. Registry callbacks reconcile only after in-flight operations finish; successful cleanup removes an owner, failed cleanup retains it. Other routes never share mutable capture or transport state. See [ADR-002](../adr/002-bounded-route-owners.md) and [restoration](../mechanics/restoration.md).

## Change routing

- Identity or stale choices: [identity](identity.md).
- PCM/SRC/readiness: [playback](../mechanics/playback.md).
- Teardown/suppression: [restoration](../mechanics/restoration.md).
- Dropdown refresh/control reuse: [UI refresh](../mechanics/ui-refresh.md).
- Build/plist/signing: [development](development.md).
