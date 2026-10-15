---
type: adr
title: Shared typed HAL reads with consumer-owned failure semantics
status: accepted
tags: [boundaries, parsing, identity, cleanup]
---

# ADR-007: Shared typed HAL reads

## Context

Retrospective record of the post-structure property-boundary cleanup. Agent inspection found three HAL object-ID array parsers and separate scalar/string readers in process inventory. [ADR-004](004-parsed-identity.md) already requires boundary-owned facts and explicit unknowns; duplicated byte parsing made that rule brittle.

## Decision

- Reuse `AudioDeviceProperties` / `CoreAudioDeviceProperties` in [AudioDevices.swift](../../Sources/AudioRouter/AudioDevices.swift) for device and process HAL object-ID, UInt32 and string reads. Despite the existing name, this boundary parses those shared property representations, not process-lifetime policy.
- One raw parser owns array capacity/alignment/exact-length checks and scalar/string size validation. Do not restore process-specific copies or add a parallel generic HAL framework.
- [AudioProcesses](../../Sources/AudioRouter/AudioProcesses.swift) owns property selectors/scopes and read-failure interpretation. Complete-list failures throw; unknown activity contributes to coverage; unreadable PID, bundle and output metadata remains optional. Unknown outputs are not empty outputs, and a failed list cannot prove absence.
- Process birth remains a separate `proc_pidinfo` fact. Inject its read and typed properties for deterministic tests; production defaults stay read-only. Injection does not authorize capture or settings writes.
- Consumers use existing owner-defined rules: `ProcessMeter.start` uses `AudioProcess.hasSameIdentity`; `PlaybackSink` uses its existing size-checked Audio Unit reader for running state. No weaker identity alias or separate property-read path is needed.

Current semantics: [identity architecture](../architecture/identity.md). This implements ADR-004 rather than superseding its authority or uncertainty rules.

## Consequences

Parsing checks have one owner while process/device failure policies remain distinct. Bundle strings now receive the shared reader's exact-size validation instead of an unchecked local read. Malformed running-state reads now fail through the existing Audio Unit reader. No callback, routing, reconnection or cleanup authority is added.

[AudioProcessesTests](../../Tests/AudioRouterTests/AudioProcessesTests.swift) exercise production inventory over simulated typed properties and birth reads. Debug/release builds and debug/optimized/Thread Sanitizer standalone suites passed; real read-only host inventory also succeeded. Raw malformed HAL bytes and Audio Unit running-state faults were not injected. No live audio behavior or performance improvement is established; see [verification](../architecture/verification.md).

Reconsider if a real property representation cannot fit this typed boundary or consumers require independent read/write authority. Demonstrate the mismatch before splitting or renaming the boundary; preserve owner-defined errors and unknowns.

## Alternatives

- Retain local process readers: rejected; repeats representation parsing and permits validation drift.
- Convert every read failure into empty/false: rejected; erases uncertainty and can incorrectly establish absence.
- Introduce a new generic HAL framework or separate process parsing port: rejected; duplicates an existing working boundary without a demonstrated need.
