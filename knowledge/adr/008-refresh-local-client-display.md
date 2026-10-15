---
type: adr
title: Refresh-local client display facts without a persistent identity cache
status: accepted
tags: [ui, display, ownership, refresh]
---

# ADR-008: Refresh-local client display facts

## Context

Controller inspection found separate name/icon application lookups, repeated resolution for monitor/app rows and duplicated completed-Stop notice text. The cleanup request authorizes reducing duplication, not changing capture identity or adding persisted UI state.

## Decision

- Resolve one display record per client during inventory refresh: retain the original `AudioProcess` plus display name/icon. Monitor and app rows consume that refresh-local record.
- Use one application-match helper for PID/bundle display enrichment. Names/icons remain display-only under [ADR-004](004-parsed-identity.md); neither lookup success nor display equality establishes lifetime identity.
- Do not retain a cross-refresh application metadata cache. Re-read on the next inventory refresh; retained route rows still require full lifetime matching against active snapshots.
- Bind the stable row selection callback when creating the row, not on every inventory refresh. Its payload remains the row's current parsed client/destination.
- Share completed-Stop notice production for row Original output and selected-route Stop. Do not collapse automatic recovery or failure notices into that success path.

Owners: [AudioRouterApp](../../Sources/AudioRouter/AudioRouterApp.swift), [UI refresh](../mechanics/ui-refresh.md). State-only route labels may resolve current display names independently; they do not claim a refreshed inventory.

## Consequences

Inventory consumers use coherent name/icon facts without additional persistent state or cache invalidation rules. Existing row/menu identity, retained-route actions and menu-close sequencing must remain unchanged.

Implemented; debug/release builds and debug/optimized/Thread Sanitizer standalone suites passed. [UIRefreshTests.displayFacts](../../Tests/AudioRouterTests/UIRefreshTests.swift) exercises duplicate/unknown display names, refreshed callback payloads, reused/retained lifetimes and inventory-failure actions through production controls with simulated inventory/owners. Existing menu/focus/scroll and recovery tests also pass. The equivalent synthetic 64-client initial/20-repeat task showed noisy, broadly similar time/memory, not an established speedup; see [verification](../architecture/verification.md) for exact scope and measurements. Live audio, physical UI/VoiceOver, agent-token cost and controlled cold behavior are unmeasured.

Reconsider only if repeated cross-refresh lookup costs remain material in measured workflows; any persistent cache must define lifetime identity, invalidation and freshness first.

## Alternatives

- Resolve names/icons independently in every consumer: rejected; repeats lookup/matching and can produce inconsistent display facts within a refresh.
- Cache metadata indefinitely by PID/object ID: rejected; adds stale-lifetime risks and invalidation complexity.
- Use names/icons to merge clients: rejected; display is not routing authority.
