---
type: mechanic
title: Interaction-safe UI refresh
status: implemented
tags: [ui, refresh, focus, accessibility]
---

# Interaction-safe UI refresh

System controls stay above scrollable application rows; diagnostics expands without hiding actions on short screens. Output/Input icons/titles sit above their controls; their device dropdowns share the slider/percentage/mute line. Sound Effects is a single icon/title/dropdown row without explanatory text; all three roles use the same trailing device column. See [ADR-013](../adr/013-compact-sound-effects-row.md), which supersedes ADR-012's Sound Effects layout only. Normal Hardware volume/input level labels are omitted; unavailable-control warnings remain on a separate line, with existing accessibility descriptions preserved. See [ADR-012](../adr/012-system-control-alignment.md). There is no separate selected-route control section. The Application section has no normal-operation guidance text. Empty inventory and inventory failures retain actionable hints. The output picker identifies each row's destination; idle and suppression-confirmed rows have no redundant status label. Startup, original-output mirroring, monitoring and unavailable/recovery states remain visible. Technical lifecycle detail, including suppression-property confirmation rather than measured audibility, lives in Diagnostics.

Each app's output dropdown is its routing surface: select hardware to start/switch; **Original output** restores/stops that owner and retries failed cleanup. Retained monitoring/failed owners keep app rows even after inventory loss. Per-row lifecycle status stays visible independently of global notices; an older notice cannot hide another owner's pending restoration/cleanup. Diagnostics describes every owner's technical state. The controller owns complete inventory-derived row tooltips.

Decision constraints: [ADR-010](../adr/010-app-row-route-controls.md) supersedes the selected-route actions/warning policy in [ADR-006](../adr/006-task-focused-route-presentation.md); other task-focused presentation rules remain.

## Refresh rules

- Hide AudioRouter's own active output clients from both application rows and the diagnostics monitor picker, using the current PID or a known current bundle identifier, never display labels or missing-value equality. Other capture-unavailable/unknown clients remain visible; retained route actions remain reachable. Raw process inventory is unchanged; diagnostics counts label the external presented clients. See [ADR-011](../adr/011-hide-own-audio-client.md).
- Refresh runs on panel open, relevant HAL notifications and the manual **Refresh** retry button. Refresh alone never starts capture or reconnects a route.
- Resolve name/icon facts once per client in each inventory refresh; monitor and app rows consume the same refresh-local record carrying the original parsed client. Retained owners are added only to app rows, not the active monitor list. No persistent metadata cache or name-based identity is introduced; see [ADR-008](../adr/008-refresh-local-client-display.md).
- Reuse an app row only after full parsed client-lifetime identity matches. Reordering keeps the native view in its window; lifetime replacement/removal moves focus to a surviving eligible control. Stable refresh retains scroll position. Bind the row selection callback on creation; it consumes the row's refreshed client metadata rather than capturing the initial snapshot.
- Reuse unchanged parsed display snapshots for System/app menus. Display equality is not capture identity or write authority; rejected choices still restore actual selection.
- All dropdowns track native menu lifecycle. Destructive presentation/inventory changes coalesce until menu close, then run on the next main-loop turn **after** the selection action can consume its snapshot.
- Only presentation is deferred. HAL health, client-disappearance handling and restoration continue; errors cancel active menu tracking before presentation.
- Avoid redundant labels/icons/layout rebuilds. App destination expansion is lazy and bounded by clients plus destinations rather than eagerly constructing every combination.
- Key-view loops update on structure/visibility changes. Outer scrolling keeps controls reachable; no custom keyboard shortcuts or app-launch behavior.
- Concurrent errors are queued for asynchronous sheets while open. Closing is blocked while a sheet is attached; hidden-popover errors use a modal fallback, which can delay health servicing.

## Owners and evidence

[AudioRouterApp.refreshInventory/refreshState](../../Sources/AudioRouter/AudioRouterApp.swift) owns deferral/action sequencing and row reuse; [AudioPopover](../../Sources/AudioRouter/AudioPopover.swift) owns native controls/menu tracking/focus/scrolling; [RoutePresentation](../../Sources/AudioRouter/RoutePresentation.swift) owns owner-state interpretation.

[UIRefreshTests](../../Tests/AudioRouterTests/UIRefreshTests.swift) exercises production controls/delegates/actions and off-screen native window focus with simulated inventory/owners. It does not synthesize physical mouse/keyboard input or certify live sheets, actual screens or VoiceOver. See [verification](../architecture/verification.md). See the measured comparisons in [verification](../architecture/verification.md#selected-route-ui-removal); fewer controls do not establish faster refresh or live-audio/token savings.
