---
type: adr
title: Task-focused route presentation with technical diagnostics
status: accepted
tags: [ui, presentation, diagnostics, ownership]
---

# ADR-006: Task-focused route presentation

## Context

Retrospective record of the post-structure presentation cleanup. The user requested an **Application** heading without guidance text and removal of “Exclusive output · suppression requested.” Normal UI repeated the selector's destination and exposed engine/debug language. The controller also independently interpreted lifecycle-warning visibility.

## Decision

- Normal application rows use the output selector to communicate destination. Do not add redundant idle or suppression-confirmed status text.
- Show startup, mirrored original playback, monitoring, unavailable states and actionable restoration/cleanup warnings. Retain empty-inventory and inventory-failure hints; “no description” does not mean hiding failures.
- Put technical confirmation and its audibility limitation in Diagnostics. Confirmed suppression-property state must never be presented as measured audible routing.
- `RoutePresentation` owns lifecycle interpretation, including `needsAttention`. The controller consumes that decision; it must not duplicate lifecycle predicates.
- Preserve route actions, accessibility context, error reporting and failed-resource ownership. This decision does not simplify the audio lifecycle itself.

Current contract and owners: [UI refresh](../mechanics/ui-refresh.md), [RoutePresentation](../../Sources/AudioRouter/RoutePresentation.swift), [AudioPopover](../../Sources/AudioRouter/AudioPopover.swift), [AudioRouterApp](../../Sources/AudioRouter/AudioRouterApp.swift).

## Consequences

Normal operation has less text; technical evidence remains inspectable. Empty status strings intentionally hide native status labels, not route ownership or destination controls. Warning visibility has one interpretation owner.

[RoutePresentationTests](../../Tests/AudioRouterTests/RoutePresentationTests.swift) and [UIRefreshTests](../../Tests/AudioRouterTests/UIRefreshTests.swift) cover hidden normal labels, retained warnings, diagnostics and native layout with simulations. Builds/tests do not establish live audibility, physical interaction or VoiceOver behavior; see [verification](../architecture/verification.md).

Reconsider only if a concrete user task cannot be answered by the selector, visible exceptions or Diagnostics. Add the smallest task-relevant information; do not restore technical status text merely because it exists in the engine.

## Alternatives

- Shorten every engine status: rejected; still duplicates the output selector and exposes implementation vocabulary.
- Hide all status and recovery information: rejected; obscures retained ownership and required user actions.
- Independently decide warning visibility in each UI consumer: rejected; policy can drift from lifecycle presentation.
