---
type: mechanic
title: Explicit System audio controls
status: implemented
tags: [system, defaults, hardware, authority]
---

# Explicit System audio controls

The **System · macOS defaults** section is separate from [per-app routing](app-routing.md). These explicit actions can change host audio settings; routing actions cannot.

[SystemAudioRole in AudioDevices.swift](../../Sources/AudioRouter/AudioDevices.swift) owns role → selector mapping:

| Role | macOS property | Meaning |
| --- | --- | --- |
| Output | `kAudioHardwarePropertyDefaultOutputDevice` | Normal playback default |
| Input | `kAudioHardwarePropertyDefaultInputDevice` | Input default; selection does not record audio |
| Sound Effects | `kAudioHardwarePropertyDefaultSystemOutputDevice` | Alert/system-sound destination, not an effects chain |

Output/input level and mute appear only when a writable main hardware control exists. Sound Effects has no level/mute slider: substituting a shared device's hardware volume would affect normal playback too. No independent alert-volume implementation exists.

Typed actions carry role and device snapshot. Selection revalidates identity/liveness/streams, role eligibility and selector writability, then reads back the default. Level/mute validate that this device remains the role's current default before writing. The controller reads actual levels after actions instead of assuming success. Unknown or stale facts block writes; existing app routes never follow a changed default automatically.

## Owners and tests

- [AudioDevices](../../Sources/AudioRouter/AudioDevices.swift): typed property boundary, role mapping, validation and writes.
- [SystemAudioRow in AudioPopover.swift](../../Sources/AudioRouter/AudioPopover.swift) and [AudioRouterApp](../../Sources/AudioRouter/AudioRouterApp.swift): native typed actions and readback presentation.
- [SystemAudioTests](../../Tests/AudioRouterTests/SystemAudioTests.swift): simulated writes, readback, eligibility, direction/role separation and controller actions. No live host writes are exercised; see [verification](../architecture/verification.md).
