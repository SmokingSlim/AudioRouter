---
type: adr
title: Boundary-owned parsed identity and explicit unknowns
status: accepted
tags: [identity, inventory, boundaries, authority]
---

# ADR-004: Parsed identity, not display authority

## Context

Baseline decision documented from existing process/device boundaries and 0.10.1 row reuse. HAL objects/PIDs can be reused, labels can collide, and display caching must not authorize capture or setting writes.

## Decision

Process lifetime identity belongs to `AudioProcess`/`AudioProcesses`; device/role facts belong to `AudioDevice`/`AudioDevices`. Consumers use those parsed facts and owner-defined identity predicates rather than reconstructing identity from labels or raw HAL data. Revalidate at capture/mutation boundaries. Unknown identity/activity/liveness is not absence, equality or eligibility.

Full client lifetime gates row reuse and existing-route selection. Registry PID/object conflicts independently preserve earlier ownership through cleanup. Device display equality only enables menu reuse; no reconnect/default fallback is inferred from display or a repeated UID. See [identity architecture](../architecture/identity.md).

## Consequences

Some starts/writes are intentionally unavailable until identity can be established. Refresh can preserve native controls without weakening live validation. Partial inventories retain meaningful failures, and malformed snapshots cannot prove disappearance.

## Alternatives

- Name/bundle/PID-only matching: unsafe lifetime merges and stale authority.
- Every UI consumer interpreting raw HAL values: duplicated policy and drift.
- Convert unreadable facts to empty/false: conceals uncertainty and can authorize inappropriate cleanup or writes.
