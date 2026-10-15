---
type: verification
title: Verification coverage and limits
status: partial
tags: [testing, evidence, performance]
---

# Verification coverage and limits

This is a coverage summary, not certification. Implemented rules, automated simulations and user-reported audible behavior are separate evidence classes.

## Automated coverage map

| Production concern | Tests |
| --- | --- |
| Device validation, volume bounds, read-only inventory and off-main capture callback | [AudioDevicesTests](../../Tests/AudioRouterTests/AudioDevicesTests.swift) |
| System roles, typed property writes/readback and controller target/actions | [SystemAudioTests](../../Tests/AudioRouterTests/SystemAudioTests.swift) |
| Process inventory selectors/scopes, activity and output unknowns, lifetime identity and list failure/absence semantics over typed properties | [AudioProcessesTests](../../Tests/AudioRouterTests/AudioProcessesTests.swift) |
| PCM/layout/malformed inputs, SRC, backpressure, silence, wraparound, concurrent FIFO/channel integrity and independent callbacks | [SampleTransportTests](../../Tests/AudioRouterTests/SampleTransportTests.swift) |
| Tap UUID, suppression/readback, ambiguous writes, failed restoration/retry and readiness | [TapPlaybackControlTests](../../Tests/AudioRouterTests/TapPlaybackControlTests.swift) |
| Lifecycle/readiness/retained-resource presentation and native layout | [RoutePresentationTests](../../Tests/AudioRouterTests/RoutePresentationTests.swift) |
| Registry isolation, capacity/identity, partial starts, retained failures and all-owner Quit; native controller actions | [AudioRoutesTests](../../Tests/AudioRouterTests/AudioRoutesTests.swift) |
| Dropdown delegate/action ordering, native row/menu reuse, off-screen focus/scroll, short-view reachability, refresh-local display facts, fresh action payloads and inventory-failure/retained-lifetime rows | [UIRefreshTests](../../Tests/AudioRouterTests/UIRefreshTests.swift) |

Lifecycle owners, process inventory and typed device/tap properties are simulated where needed. Actual production callbacks/native controls execute, but this does not establish real simultaneous HAL playback, capture permissions, hardware mixing, audible fault isolation, disposal order under real failures, physical input or VoiceOver behavior.

## Established host reports

Historical SoundTool name/version labels are retained as evidence provenance:

- 0.5.2: Spotify capture/peak monitoring worked.
- 0.6.0: Spotify mirrored to hardware B while original playback and system default remained on A.
- 0.7.0: exclusive playback worked; manual restoration returned Spotify to A.
- ADAM D3V disconnect while suppressed restored playback; 0.7.1 recovery/reporting retest worked as expected.
- 0.8.1 dropdown routing and System/Application UI received positive reports; not separate verification of every System setting.
- 0.10.0 concurrent routing: user reported “works exceptionally.” Specific output combinations/fault scenarios were not separately described.
- After 0.10.1 delivery, user reports everything seems to work as expected. Do not downgrade this general success, or inflate it into exhaustive accessibility/fault coverage.

## Build evidence

0.10.1 before rename passed debug/release builds, debug/optimized tests, Thread Sanitizer, plist lint and strict signing checks. Rename passed fresh Swift 6 debug/release builds, warnings-as-errors debug/optimized tests, plist lint and strict signing checks; Thread Sanitizer was not rerun for the rename. Neither automated pass launched an app, started live capture/playback or wrote host settings. The knowledge-only structure change adds no runtime verification.

The post-structure presentation/property-boundary cleanup passed debug/release builds and warnings-as-errors standalone tests in debug, optimized and Thread Sanitizer configurations. Actual read-only host device/client inventory also succeeded during those runs. Process failure/unknown cases use simulated typed properties and birth reads; malformed raw HAL buffers and the changed Audio Unit running-state read were not fault-injected. No app was launched, no live capture/playback started, and no host settings were written. This is structural cleanup, not a measured performance improvement; before/after token, elapsed/CPU and process-family memory comparisons remain unmeasured.

The subsequent controller/display cleanup passed debug/release builds and warnings-as-errors standalone suites in debug, optimized and Thread Sanitizer configurations. `UIRefreshTests.displayFacts` covers production controls with simulated duplicate/unknown display names, same-lifetime metadata updates, creation-time callbacks consuming refreshed payloads, retained/reused lifetimes and failed/empty inventory. No live capture/playback, physical UI or host-setting writes were exercised. No bundles were packaged or launched.

Lifecycle review retained the distinct started/resource-ownership/stop-request/restoration-confirmation facts and ordered partial teardown; collapsing them would erase failure states covered by ADR-003. Only unused start-argument defaults were removed: registry calls already supply both choices explicitly. A source/test identifier-reference sweep left only native AppKit hooks as single-reference methods; this is not whole-program proof of exhaustive dead-code absence.

## Per-app gain/mute

[ADR-009](../adr/009-per-route-pcm-level.md) implementation passed debug/release builds and warnings-as-errors standalone suites in debug, optimized and Thread Sanitizer configurations. Production callback tests cover finite/range validation, 10 ms ramps at 32/48/96 kHz across slices, mid-ramp retargeting, initial mute, mute/unmute with gain retention, zero-gain readiness, concurrent target publication and independent route gains. Native slider/mute target/actions with simulated owners/property inventory cover unity defaults, isolation, level retention during destination switching, new-route reset, unavailable monitor/original controls, identity/restoration guards and zero hardware writes. Gain actions retain menus rather than rebuilding inventory/layout.

Automated validation exercised no live capture/playback, physical slider interaction or host settings. Input peaks remain pre-gain. Automated tests alone do not establish audible ramps, muted exclusive playback, restored-original audibility or live route performance; earlier routing reports predate this feature.

The user subsequently authorized a live check. Packaged `build/AudioRouter-gain-check-1.app` passed plist lint and strict signing verification (retains version 0.10.1/build 17; the unique bundle path identifies this test build). Requested normal Quit of the running `AudioRouter-0-10-1.app`; process inspection confirmed it exited before launching the gain-check bundle and confirmed only that new copy running. This proves packaging/launch, not successful route restoration or audible gain/mute. The agent selected no routes and changed no System controls.

After the proposed gain/mute live-check checklist, the user reported “yep, it works as expected.” This is positive general live feedback for the gain-check build. The user did not separately enumerate tested apps/devices, one-/two-route combinations, ramp audibility, mute leakage, switching or restoration results; do not infer exhaustive scenario coverage. Live performance measurements, fault recovery and accessibility certification remain outstanding.

The user subsequently reported that it works “absolutely beautiful” and that “the gain does not drop when switching between audio routes.” This adds specific positive live feedback for gain retention during route switching; exact apps/devices and switching operations were not enumerated. It does not separately establish physical disconnect isolation, mute retention or restoration outcomes.

### Synthetic PCM cost comparison

Swift 6.2 `swiftc -O`, arm64 macOS 15.7.4. Equivalent unity-gain task: each transport receives 2,048 initial stereo frames, renders 256 frames, runs 1,000 warm-up push/render pairs, then completes 200,000 measured 256-frame push/render pairs per route at 48 kHz. One or two transports run serially in one process; output and zero underrun/overrun counters are checked. The **derived no-gain reference** is the current source with target/ramp/multiplication removed from render, not a pinned historical binary; setup still contains the new level fields. Three alternating reference/current process pairs per task.

| Median of three | 1 route reference | 1 route current | 2 routes reference | 2 routes current |
| --- | ---: | ---: | ---: | ---: |
| Initial push/render, ms | 0.0091 | 0.0092 | 0.0116 | 0.0128 |
| Warm measured pairs, ms | 378.891 | 375.615 | 730.661 | 702.877 |
| Complete process elapsed, s | 0.38 | 0.38 | 0.73 | 0.70 |
| Complete process CPU (user + system), s | 0.37 | 0.37 | 0.73 | 0.70 |
| Peak process-family RSS, MiB | 2.969 | 2.969 | 3.094 | 2.969 |

There are no child processes; family RSS is the benchmark process only, not external macOS services. First push/render is not controlled cold execution: framework/system caches are uncontrolled. One-route reference complete-process elapsed ranged 0.35–3.46 s (first-process startup outlier), current 0.38–0.45 s; two-route reference 0.68–0.76 s, current 0.70–0.75 s. Warm medians differ by −0.9%/−3.8%, but this noisy sample establishes neither a speedup nor live overhead bounds. Retired instructions increased about 7% for unity-gain processing, despite overlapping timings.

Driver, derived reference, binaries and raw results are retained under ignored `.build/gain-benchmark*`. Active-ramp cost, UI drag cost, controlled cold costs, live HAL/AU scheduling/allocations, process-family costs including external services, latency/fidelity, compiler/build costs and agent-token usage are unmeasured. This offline throughput task does not simulate real-time scheduling or simultaneous devices.

## Selected-route UI removal

[ADR-010](../adr/010-app-row-route-controls.md) removes the engineering selector/buttons, controller selection state/handlers, registry manual suppression adapter and action-only presentation fields. Debug/release builds, warnings-as-errors standalone debug/optimized/Thread Sanitizer suites and plist lint passed. Source/test identifier checks found no remaining removed-field references. No live app was relaunched or replaced, capture/playback started or host settings written for this change.

Native controls with simulated owners cover independent stop through each app's Original output, gain retention/isolation, stopping an inventory-lost monitor through its retained app row, and all-owner Quit. Recovery tests retain a failed-restoration row's warning alongside an unrelated older notice, preserve blocked hardware/gain actions, expose the actual Original output retry in Diagnostics and successfully retry through the native dropdown. A stopped-but-owned cleanup failure also retains its row and disabled hardware/gain actions until native Original output retry succeeds. Existing registry/Tap tests retain partial-start, failed cleanup/restoration, identity/capacity and all-owner failure coverage; these do not certify real-HAL fault recovery. Native layout tests assert the old heading/buttons are absent and preserve focus/menu deferral, lazy expansion and short-screen accessibility reachability. The three-row synthetic layout is 615 pt compact/693 pt diagnostics (previous gain-build test: 725/740 pt). A 360 pt viewport replaces the old 560 pt overflow assertion because removal now allows that setup to fit; scrolling is still exercised, not assumed unnecessary.

Physical UI, VoiceOver and live stop/retry behavior for this simplified build remain unverified. Positive gain-build host feedback predates this UI change. The existing gain-check app/bundles were left untouched.

The user subsequently authorized packaging/launch and requested automatic packaging whenever changes are ready for testing. Created `build/AudioRouter-ui-check-1.app`; plist lint and strict signature verification passed. Process inspection found no old copy running before launch and confirmed the new bundle running afterward. No routes or System controls were selected by the agent. This establishes packaging/launch only; simplified-UI user feedback is pending. Standing packaging permission is recorded in [development](development.md), separately from launch authorization.

### Equivalent refresh comparison

Same retained driver as [controller/display cleanup](#controllerdisplay-cleanup-comparison): 64 simulated clients, one initial inventory refresh plus 20 stable repeats, native row reuse, exactly 21 inventory reads and zero writes. Swift 6.2 `swiftc -O`, arm64 macOS 15.7.4; before binary compiled from the gain-enabled sources before this UI change, after binary from the simplified UI. Three alternating before/after process pairs. No owned/live routes in this task; active-route interaction cost is unmeasured.

| Median of three | Before | After |
| --- | ---: | ---: |
| First inventory refresh, ms | 441.337 | 446.120 |
| Warm 20 refreshes, ms | 3515.887 | 3717.926 |
| Complete process elapsed, s | 4.09 | 4.32 |
| Complete process CPU (user + system), s | 4.01 | 4.12 |
| Peak process-family RSS, MiB | 207.578 | 207.703 |

Elapsed ranges overlap: before 4.04–4.12 s, after 4.02–4.37 s. Sampled medians increased about 5.6% elapsed and 5.7% warm-repeat time; this small noisy sample establishes neither a speedup nor unchanged performance. Three-app height reduction is a layout result, not a resource-cost guarantee.

No child processes are created, so family RSS covers the benchmark process only, excluding external services. Each pair starts fresh processes but framework/system caches are uncontrolled; first refresh is not a controlled cold run. Warm repeats are within-process. Agent-token usage, controlled cold cost, active-route/slider work, live HAL/AU time/memory/latency and compiler/build costs remain unmeasured. Before/after binaries and raw results are retained under ignored `.build/route-ui-refresh-*`; driver remains `.build/cleanup-H8bl1d/RefreshBenchmark.swift`.

## Open coverage

Choose separately scoped host checks for distinct/shared outputs, switch/disconnect isolation, browser helpers/permissions, partial setup/restoration/disposal faults, faulted Stop/Quit, repeated USB/Bluetooth failures and format changes. Physical dropdowns, async sheets, keyboard traversal, actual screens, VoiceOver and explicit System writes remain distinct checks. Do not require re-proving successful basic routing before unrelated work.

## Performance evidence

Historical exact task definitions and measurements remain in [README verification history](../../README.md#build-and-tests); source/benchmark snapshots are retained locally under ignored `.build-before-rename/`. They are synthetic first/repeat runs, not controlled cold/warm or live audio certification. The 64-app/20-refresh UI task had an equivalent pre/post comparison; expanded full suites were not equivalent historical comparisons.

### Controller/display cleanup comparison

Equivalent task: instantiate the production controller with 64 simulated active clients/device properties, perform one initial inventory refresh and 20 stable repeats, and verify native row reuse, 21 inventory reads and zero property writes. Swift 6.2, `swiftc -O`, arm64 macOS 15.7.4. Three alternating before/after process pairs; the before binary was compiled before the controller edits. The same benchmark driver was used for both. First-refresh timing excludes controller initialization; complete-process elapsed/CPU/RSS includes it. Related macOS services and compiler/build costs are not included.

| Median of three runs | Before | After |
| --- | ---: | ---: |
| First inventory refresh, ms | 206.688 | 223.862 |
| Warm 20 refreshes, ms | 2012.320 | 2048.758 |
| Complete task elapsed, s | 2.28 | 2.40 |
| Complete task CPU (user + system), s | 2.23 | 2.29 |
| Peak benchmark process RSS, MiB | 118.297 | 118.281 |

Complete-process elapsed ranges: before 2.16–2.78 s; after 2.15–2.50 s. The sampled median elapsed increased about 5.3%, while warm-repeat time increased about 1.8%; ranges overlap and this small noisy sample establishes neither a speedup nor unchanged performance. Lookup consolidation is a structural result, not a measured performance guarantee.

The benchmark creates no child processes; reported RSS covers the single benchmark process, not external macOS services. Each sample starts a fresh process, but system/framework caches are uncontrolled: **first refresh is not a controlled cold run**. Warm figures are within-process repeats. Agent tokens, actual-app metadata lookup workload, live audio/latency/fidelity, controlled cold costs, build costs and a process-family/system-services memory profile remain unmeasured. Driver, before/after binaries and paired raw results are retained under ignored `.build/cleanup-H8bl1d/`; earlier exploratory runs were not included in the table.

Future cost changes should measure equivalent completed tasks: agent tokens, elapsed/CPU time and peak process-family memory, with cache conditions and unmeasured costs explicit. Live audio cost, latency, fidelity/drift and agent-token savings from this knowledge structure remain unmeasured.
