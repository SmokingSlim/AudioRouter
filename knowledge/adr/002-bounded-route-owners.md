---
type: adr
title: Bounded registry with independent route lifecycle owners
status: accepted
tags: [routing, ownership, concurrency, resources]
---

# ADR-002: Bounded independent route owners

## Context

Baseline decision documented from the existing 0.10.0 implementation, not a new capability approval. Concurrent routing needed independent selected destinations without changing system defaults or duplicating the proven single-route lifecycle.

## Decision

[AudioRoutes](../../Sources/AudioRouter/AudioRoutes.swift) owns the registry and duplicate/capacity/monitor policy. Each route receives a fresh existing `ProcessMeter` lifecycle, including its own capture, transport, sink and restoration obligation. At most four owners, including one monitor; failed partial setup/cleanup stays registered and counts toward capacity.

Install ownership before setup and reconcile only after in-flight operations finish. Switching restores/stops only the selected owner before creating replacement. Shared destinations use independent output units, not shared mutable route state. See [routing mechanics](../mechanics/app-routing.md) and [code ownership](../architecture/code-ownership.md).

## Consequences

Failure/retry is isolated to the affected owner; retained identity prevents duplicate capture after PID/object reuse. Four hardware FIFOs bound PCM storage to 512 KiB, but HAL/AU memory and live four-route cost remain unmeasured. Registry simulations establish policy, not all hardware behavior.

## Alternatives

- Add a parallel multi-route audio engine: duplicates lifecycle interpretation and recovery obligations.
- Share mutable tap/transport state between routes: couples failure and teardown.
- Unbounded starts: no safe resource budget and poor retained-failure accounting.
