---
type: adr
title: Single-line Sound Effects selector
status: accepted
tags: [ui, layout]
---

# ADR-013 — Single-line Sound Effects selector

## Context

The user requests removal of the alerts/system-sounds explanation and moving the Sound Effects icon/title onto its dropdown line. This partially supersedes [ADR-012](012-system-control-alignment.md) for Sound Effects only.

## Decision

Sound Effects has one full-width horizontal row: icon, title, flexible space, device picker. Keep the shared trailing picker column and existing accessibility label/actions. Do not add the explanatory hint or empty controls row. Output/Input retain their existing two-line controls and unavailable warnings. This changes presentation only; Sound Effects remains macOS's system-sound destination, not an effects processor.

Owners: [SystemAudioRow](../../Sources/AudioRouter/AudioPopover.swift), [System UI tests](../../Tests/AudioRouterTests/SystemAudioTests.swift), [UI mechanics](../mechanics/ui-refresh.md).

## Consequences

Sound Effects uses less vertical space without changing device authority, routing or warning semantics for other roles.

## Alternatives

- Hide the explanation but retain separate title/picker lines: rejected because it does not satisfy the requested single row.
- Collapse Output/Input too: rejected as outside this request.

## Verification

Debug/release builds and the full standalone read-only suite passed. Production AppKit checks verify Sound Effects has exactly one arranged row, its icon/title/picker alignment rectangles share a vertical center, no explanatory hint is attached, and all device pickers retain the same trailing column/230-point alignment width. Existing Output/Input warning, accessibility, scoped-action and menu/short-viewport checks pass. Native frame insets are accounted for through alignment rectangles rather than assuming visual frames equal Auto Layout rectangles.

Packaged `build/AudioRouter-0-10-3.app`, version 0.10.3/build 19; plist lint and strict signature verification passed. Not launched. No live capture/playback or host-setting writes; simulated property actions and off-screen layout do not certify physical interaction or VoiceOver. No performance improvement claimed or measured. Reconsider only if actual layout/accessibility checks reveal a problem.
