---
type: convention
title: Build and development
status: current
tags: [development, build, testing]
---

# Build and development

Requires macOS 15+, Swift 6 and Apple Command Line Tools. Run commands from the AudioRouter repository root. The package is an executable; CLT here lacks XCTest, so tests are a standalone executable, not `swift test`.

## Build and package

```sh
swift build
swift build -c release
bash scripts/build-app.sh NEW-UNIQUE-NAME
plutil -lint build/NEW-UNIQUE-NAME.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 build/NEW-UNIQUE-NAME.app
```

[scripts/build-app.sh](../../scripts/build-app.sh) builds release, copies [Info.plist](../../Info.plist) and ad-hoc signs; it refuses bundle overwrite. Local signing is not notarization. Baseline renamed bundle: `build/AudioRouter-0-10-1.app`, version 0.10.1/build 17. Latest package: `build/AudioRouter-0-10-3.app`, version 0.10.3/build 19 (compact Sound Effects row, System control alignment and prior self-output filtering); plist/signature verified, not launched.

The user requests automatic packaging whenever validated changes are ready for user testing: create a fresh uniquely named bundle, lint its plist and verify its signature without asking again about packaging. Future packages use incremental MAJOR–MINOR–PATCH names (`AudioRouter-0-10-2.app`), not timestamps or descriptive check names. Increment PATCH for fixes/polish, MINOR for backward-compatible features, and MAJOR for breaking changes; choose an unused version and keep `CFBundleShortVersionString` aligned (`0.10.2`), with an incremented `CFBundleVersion`. This applies to future packages; do not rename or overwrite historical bundles. Preserve existing bundles. This standing permission does not authorize launch or host-setting changes. Launch only with user authorization; quit any older copy normally and verify it exited before starting replacement. Failed Quit blocks replacement; never force termination or run overlapping copies.

[Package.swift](../../Package.swift) owns package/product/target names. The retained `app.soundtool.local` bundle and internal identifiers are intentional; see [ADR-005](../adr/005-rename-identity-continuity.md).

## Standalone tests

In Bash:

```bash
sources=()
for file in Sources/AudioRouter/*.swift; do
  [[ "$file" == */main.swift ]] || sources+=("$file")
done
swiftc -warnings-as-errors -swift-version 6 "${sources[@]}" \
  Tests/AudioRouterTests/*.swift -o .build/audiorouter-tests
.build/audiorouter-tests
```

Run `swift build` first so `.build/` exists. Add `-O` for an optimized binary or `-sanitize=thread` for Thread Sanitizer, using distinct output names. Never include app `main.swift`; the test harness supplies its own entry point. Tests read host inventory but do not start HAL capture/playback or write host settings. See [verification](verification.md) for what simulations do and do not establish.

## Local artifacts

Ignored `.build/` is fresh compiler/test output; `.build-before-rename/` preserves old caches and benchmark evidence. SwiftPM precompiled headers embed absolute paths; after moving the project, preserve old cache separately and rebuild rather than attempting to reuse it. Ignored `build/` retains packaged app copies. Root `TODO.md` is a historical local handoff, not the active backlog.

Do not delete evidence/bundles without confirmation or commit these outputs, credentials or unrelated local artifacts.

## Documentation-only changes

Check frontmatter fields/allowed values, every relative file link and index reachability. Confirm each source/test-owner link against the actual file and relevant symbol. Review claims against [verification](verification.md). No runtime rebuild or host mutation is required when only Markdown changes; do not claim new audio verification from documentation checks.
