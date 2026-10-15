---
type: adr
title: Hide AudioRouter's own output client
status: accepted
tags: [ui, identity, feedback]
---

# ADR-011 — Hide AudioRouter's own output client

## Context

The user requests that AudioRouter's capture-unavailable playback client never appear as a source. Its AUHAL playback is observed in the same inventory as other apps. The user asked about Refresh, not for its removal.

## Decision

Filter self clients once in the controller's active presentation projection, before resolving display facts for application rows and the diagnostics picker. Match the current PID or a known current bundle identifier, never display names or equality of missing bundle IDs. Reuse this predicate for UI capture eligibility. Keep raw process inventory and capture-boundary safety checks unchanged. Preserve retained route rows: owned restoration/cleanup actions must remain reachable even after inventory loss.

Other unidentified/unavailable clients remain visible. Diagnostics counts describe presented external active clients; unknown activity remains the raw inventory fact. Keep manual Refresh as a retry alongside automatic open/notification refresh.

## Consequences

Self playback no longer adds an unusable source or monitor choice. This is a presentation policy, not capture authority or ownership proof. No audio lifecycle, host-setting writes or new execution authority changes.

Owners: [controller](../../Sources/AudioRouter/AudioRouterApp.swift), [UI tests](../../Tests/AudioRouterTests/UIRefreshTests.swift), [UI mechanics](../mechanics/ui-refresh.md).

## Alternatives

- Hide every uncapturable client: rejected because missing identity is uncertainty, not evidence of self output.
- Filter the HAL inventory: rejected because observation and client-disappearance semantics belong to that boundary, not UI policy.
- Hide by name: rejected because labels are not identity.

## Verification

Debug/release builds and the full standalone read-only suite passed. The suite ran both as an unbundled executable and inside a test bundle with the app plist, exercising current-PID and known-bundle exclusion, missing bundle IDs, label-only similarity, preserved unknown clients, both source surfaces, external counts and self-only empty state. Existing retained-owner/menu/focus coverage remains. Simulated inventory/owners do not establish live HAL behavior; no capture/playback or host-setting writes were started.

Packaged `build/AudioRouter-hide-self-20261014-200911.app`; plist lint and strict signature verification passed. Not launched. No performance improvement is claimed or measured. Reconsider if AudioRouter gains a safe user-facing self-capture workflow.
