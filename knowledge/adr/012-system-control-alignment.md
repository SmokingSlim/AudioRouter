---
type: adr
title: Concise aligned System controls
status: accepted
tags: [ui, layout, accessibility]
---

# ADR-012 — Concise aligned System controls

## Context

The user requests removal of the self-explanatory Hardware volume/input level labels and placement of device dropdowns in that space for a neater System section.

## Decision

Keep each role's icon/title above its controls. Place Output/Input device pickers at the trailing edge of the slider/percentage/mute row. Sound Effects uses the same trailing picker column beneath its title. Remove normal hardware guidance; retain unavailable-control warnings on a separate line, hidden when empty. Preserve existing accessibility descriptions, device snapshots, actions and System-vs-app authority.

Owners: [SystemAudioRow](../../Sources/AudioRouter/AudioPopover.swift), [System UI tests](../../Tests/AudioRouterTests/SystemAudioTests.swift), [UI mechanics](../mechanics/ui-refresh.md).

## Consequences

Device choices and levels share a line without redundant normal labels. Warning text cannot crowd the device picker. No audio behavior changes or new host-setting authority.

## Alternatives

- Only clear the labels: rejected because it leaves pickers on the old headline rather than the user-requested control line.
- Remove all hints/accessibility descriptions: rejected because unavailable controls still need explanation and assistive labels are not visual clutter.

## Verification

Debug/release builds and the full standalone read-only suite passed. Production AppKit tests verify all three device pickers share a trailing column, retain 230-point alignment widths, and Output/Input pickers share the slider line without mute overlap. Tests check normal-hint removal, unavailable-warning visibility/recovery and preserved accessibility labels, alongside existing role-scoped actions and short-viewport/menu checks. An off-screen window supplies native layout; it is never activated or shown. These are not physical interaction or VoiceOver certification.

Packaged `build/AudioRouter-0-10-2.app`, version 0.10.2/build 18; plist lint and strict signature verification passed. Not launched. No live capture/playback or host-setting writes performed. No performance improvement claimed or measured. Reconsider layout if actual short-screen or accessibility checks reveal a problem.
