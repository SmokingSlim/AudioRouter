---
type: index
title: Architecture decision records
status: current
tags: [navigation, decisions]
---

# ADRs

| Record | Decision | Status |
| --- | --- | --- |
| [001](001-indexed-knowledge.md) | Indexed OKF-style concepts and ADRs; no separate vision tree | accepted |
| [002](002-bounded-route-owners.md) | Bounded registry reuses one existing lifecycle owner per route | accepted |
| [003](003-restoration-before-teardown.md) | Restore original playback before teardown; retain failed ownership | accepted |
| [004](004-parsed-identity.md) | Boundary-owned identity and unknowns; display is not authority | accepted |
| [005](005-rename-identity-continuity.md) | Standalone AudioRouter naming with retained bundle identity | accepted |
| [006](006-task-focused-route-presentation.md) | Task-focused route UI; technical evidence in Diagnostics | accepted |
| [007](007-shared-typed-hal-reads.md) | Shared typed HAL parsing with distinct consumer failure semantics | accepted |
| [008](008-refresh-local-client-display.md) | Refresh-local display facts without persistent identity caches | accepted |
| [009](009-per-route-pcm-level.md) | Per-route replacement PCM gain/mute with render-owned ramps | accepted |
| [010](010-app-row-route-controls.md) | App rows replace selected-route engineering controls; partially supersedes 006 | accepted |
| [011](011-hide-own-audio-client.md) | Hide self output from source presentation; preserve unknown clients and owned actions | accepted |
| [012](012-system-control-alignment.md) | Remove normal hardware labels and align System device/level controls | accepted |
| [013](013-compact-sound-effects-row.md) | Single-line Sound Effects without explanation; partially supersedes 012 | accepted |
