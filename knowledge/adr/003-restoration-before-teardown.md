---
type: adr
title: Restoration before teardown with retained failure ownership
status: accepted
tags: [restoration, cleanup, safety, ownership]
---

# ADR-003: Restore before teardown

## Context

Baseline decision documented from existing tap/lifecycle code. Suppression writes can fail ambiguously, and dropping capture or callback resources before confirmed restoration risks leaving original playback suppressed or invalidating live refcons.

## Decision

[TapPlaybackControl](../../Sources/AudioRouter/TapPlaybackControl.swift) records restoration obligation before the mutating write and clears it only after unmuted readback. `ProcessMeter.stop` restores before disabling/tearing down playback/capture. Failed restoration retains replacement resources; failed teardown retains remaining handles and callback storage. Quit attempts every owner but cancels on any failure.

Do not convert ownership failure into “stopped,” silently release resources or re-suppress on restoration retry. See [restoration mechanics](../mechanics/restoration.md).

## Consequences

Retry remains possible through the same owner and identity; unresolved cleanup consumes a slot and can block Quit. Polling/main-thread stalls can delay recovery, so this policy is not a guaranteed seamless fail-open claim. Real HAL fault coverage remains [partial](../architecture/verification.md).

## Alternatives

- Tear down first and trust macOS to restore: abandons the explicit restoration proof.
- Treat write failure as no effect: ignores ambiguous mutation.
- Drop failed handles or quit anyway: loses resource/identity ownership and retry authority.
