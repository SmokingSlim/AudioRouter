---
type: adr
title: App rows replace selected-route engineering controls
status: accepted
tags: [ui, routing, recovery, presentation]
---

# ADR-010: App rows replace selected-route engineering controls

## Context

The user explicitly requested complete removal of the Selected app · route controls section as engineering UI without regular-user value. This supersedes ADR-006's requirement to preserve those selected-route actions and its separate selected-owner warning/needsAttention policy; all other task-focused presentation rules remain.

## Decision

- Remove the section, route selection state, selector handlers, manual suppression toggle adapter and action-only presentation fields. Do not relocate the buttons into Diagnostics.
- Application output dropdowns own routing interaction: hardware starts/switches an exclusive route; Original output restores/stops exactly that owner and retries retained cleanup. Monitor owners remain reachable as app rows even after inventory loss; Quit continues attempting every owner and stays blocked on failed cleanup.
- Retain per-row lifecycle warnings independently of global notices. Retained owners keep their Original output action enabled even when destination changes and gain controls are blocked. Diagnostics retains technical lifecycle detail for every owner, not a selected one. Warning instructions must name the remaining dropdown action, not removed buttons.
- Do not change gain policy, callback processing, startup readiness, restoration-first ordering, failure retention, system-default authority or routing capacity.

Owners: [AudioPopover](../../Sources/AudioRouter/AudioPopover.swift), [AudioRouterApp](../../Sources/AudioRouter/AudioRouterApp.swift), [RoutePresentation](../../Sources/AudioRouter/RoutePresentation.swift), [AudioRoutes](../../Sources/AudioRouter/AudioRoutes.swift). Tests: [UIRefreshTests](../../Tests/AudioRouterTests/UIRefreshTests.swift), [RoutePresentationTests](../../Tests/AudioRouterTests/RoutePresentationTests.swift), [AudioRoutesTests](../../Tests/AudioRouterTests/AudioRoutesTests.swift).

## Consequences

Normal UI no longer offers keeping a mirror while manually restoring original playback or manually re-suppressing it. Stop/restart through the dropdown remains available. Capture-only monitoring remains in Diagnostics, stopped through its retained app row or Quit. Removing UI selection cannot remove audio-resource ownership. Builds and simulated native actions do not certify physical UI or live failure recovery.

Debug/release builds, warnings-as-errors debug/optimized/Thread Sanitizer suites and plist lint passed. Native simulated actions cover independent app-row stop, retained monitor stop, warning visibility despite older notices and restoration retry through Original output. The shortened UI required a smaller test viewport to continue exercising actual outer overflow rather than weakening scroll coverage. A source/test sweep found no remaining references to the removed control/action fields. No directly related cleanup remains identified; internal suppression/restoration methods still own startup and safety behavior.

Equivalent before/after refresh costs and verification limits are recorded in [verification](../architecture/verification.md#selected-route-ui-removal); fewer controls are not a performance guarantee. No app was launched/replaced for this change. Reconsider only if a concrete user task cannot be accomplished by app rows, recovery notices and Diagnostics; do not restore an engineering selector by default.

## Alternatives

- Hide the section: leaves superseded selection/action policy and maintenance burden.
- Move engineering buttons into Diagnostics: does not meet complete removal and retains two route-control surfaces.
- Remove warnings/retained rows with the section: loses recovery visibility and retry access.
