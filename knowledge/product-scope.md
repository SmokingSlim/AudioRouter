---
type: concept
title: Product scope
status: current
tags: [product, authority]
---

# Product scope

AudioRouter is an independent, local macOS menu-bar utility for sending selected applications to selected hardware outputs **without changing the Mac's default output**. It uses public Core Audio/Audio Unit APIs, requires macOS 15+, and has no REA or SoundSource runtime dependency. No SoundSource code, assets, frameworks, identifiers or licensing are reused.

## Authority

- An app-row output choice requests capture, pinned playback and deferred experimental suppression of that client's original playback. Startup stays unmuted until replacement playback is ready.
- App gain/mute changes only owned replacement PCM; it cannot change hardware volume or mute restored original playback. See [playback](mechanics/playback.md#gain-and-mute).
- Explicit **System** controls separately change macOS Output, Input or Sound Effects defaults and supported output/input hardware level/mute. They are not app-routing controls. Input selection does not record the microphone.
- Monitoring captures one client without suppression or a playback sink. Audio is not saved or transmitted over the network.
- Identity, permissions, hardware eligibility and readiness constrain actions. Property confirmation is not proof of audible output.

## Boundaries

Up to four owned routes including at most one monitor. A browser client is routable; individual websites/tabs are not guaranteed independent targets. Unsupported hardware/formats fail rather than falling back to the system default.

No gain boost, effects, persistence, automatic reconnect, independent alert-volume slider or full mixer yet. The existing SRC/buffering is a prototype, not production-quality fidelity or guaranteed seamless fail-open recovery.

A separate vision hierarchy is unnecessary for this utility. Keep intent here; add a new product concept only when an actual requirement needs it, not an experience-design scaffold.

## Related

- [Routing](mechanics/app-routing.md)
- [System controls](mechanics/system-controls.md)
- [Playback limits](mechanics/playback.md)
- [Verification scope](architecture/verification.md)
