---
type: architecture
title: Identity and unknown boundary facts
status: implemented
tags: [identity, inventory, boundaries]
---

# Identity and unknown boundary facts

## Process lifetime

[AudioProcesses.swift](../../Sources/AudioRouter/AudioProcesses.swift) owns `AudioProcess`, `ProcessBirth` and parsed client inventory. `AudioProcess.hasSameIdentity` requires identified snapshots with equal HAL object ID, PID, process birth and bundle ID. Labels/icons/bundle ID alone never merge clients; active output I/O does not prove audibility.

`stillContains` distinguishes confirmed absence/change (`false`), confirmed lifetime match (`true`) and unreadable identity (`nil`). A changed/malformed process-object list is not a complete absence proof. `ProcessMeter.start` rechecks the selected active client using `hasSameIdentity` immediately before capture; there is no separate stored client-ID alias.

Process property reads reuse the typed `AudioDeviceProperties` boundary in [AudioDevices.swift](../../Sources/AudioRouter/AudioDevices.swift). `CoreAudioDeviceProperties` owns HAL object-ID array bounds/exact-length checks and scalar/string size validation for both device and process inventory. `AudioProcesses` owns the selectors, scopes and failure semantics: complete-list failures throw; unreadable activity increments unknown coverage; unreadable PID/bundle/output metadata remains optional. An unknown output list is not an empty list. Process birth still comes from `proc_pidinfo`; tests inject that read separately from HAL properties.

`AudioRoutes` selects an existing route using full identity and separately blocks PID/object-ID conflicts while an earlier owner remains registered. Ownership survives disappearance and ID reuse until cleanup completes. UI row reuse consumes `hasSameIdentity`; it must not invent a weaker match.

Shared-reader ownership, rejected alternatives and reconsideration rule: [ADR-007](../adr/007-shared-typed-hal-reads.md), implementing [ADR-004](../adr/004-parsed-identity.md).

## Devices

[AudioDevices.swift](../../Sources/AudioRouter/AudioDevices.swift) owns `AudioDevice`, role selectors, directional inventory and typed property parsing. Display `Equatable` is for menu caching; `hasSameIdentity` and live boundary validation establish action applicability.

Routing requires a readable UID and known hardware transport. Destination validation distinguishes unavailable, changed, unknown/ambiguous and unsupported facts; matching UID after reconnect does not authorize silently rebinding an old HAL object. `PlaybackSink` also validates device binding, running state and formats.

System writes revalidate device presence, UID, liveness, streams and relevant role eligibility/current-default state. Output/input directional failures remain independent `Result` facts; an unreadable stream list is not an empty device direction.

## Rule

Normalize/interpret at the producing boundary and let consumers use those parsed facts. Preserve unknowns rather than equating them to absence, equality or write authority. Keep ownership proof separate from current eligibility/readiness. See [ADR-004](../adr/004-parsed-identity.md).

## Tests

- [AudioDevicesTests](../../Tests/AudioRouterTests/AudioDevicesTests.swift): destination identity/liveness classifications and read-only inventory.
- [SystemAudioTests](../../Tests/AudioRouterTests/SystemAudioTests.swift): simulated property boundaries and stale/unknown device guards.
- [AudioProcessesTests](../../Tests/AudioRouterTests/AudioProcessesTests.swift): production inventory over simulated typed properties/birth reads; activity coverage, unknown versus empty outputs, lifetime match/change/unknown, list failures versus confirmed absence. These tests deliver malformed-list failures from the typed boundary; they do not simulate malformed raw HAL bytes.
- [AudioRoutesTests](../../Tests/AudioRouterTests/AudioRoutesTests.swift): duplicate/reused/unknown process identity and retained ownership.
- [UIRefreshTests](../../Tests/AudioRouterTests/UIRefreshTests.swift): lifetime-aware native row reuse/replacement.
