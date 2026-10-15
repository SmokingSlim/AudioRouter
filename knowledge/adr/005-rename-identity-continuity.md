---
type: adr
title: AudioRouter rename with retained bundle identity
status: accepted
tags: [naming, identity, packaging]
---

# ADR-005: Rename without changing audio identity

## Context

Baseline decision from the user-requested standalone repository/rename. Preserve the working app before subsequent cleanup. Baseline commit `733b548` and rename commit `7f48670` separately record that transition.

## Decision

Rename the directory, Swift package/product/target, source/test directories, controller and user-facing labels to AudioRouter. Keep `app.soundtool.local` in [Info.plist](../../Info.plist) and existing internal aggregate/queue identifier strings for identity continuity. Do not change audio behavior or claim that renaming requires a new permission identity.

Existing SoundTool bundles remain historical local artifacts, not renamed copies. Preserve the path-bound old compiler cache as ignored `.build-before-rename/` and use a fresh `.build/`. See [development](../architecture/development.md).

## Consequences

Some intentional internal `soundtool` strings remain; they are not automatic cleanup targets. The new packaged executable and labels are AudioRouter, while host bundle identity remains stable. Build/signing/test checks passed; rename alone is not a live audio test or a guarantee of OS permission handling.

## Alternatives

- Change bundle and all internal identifiers for cosmetic consistency: unrelated identity churn during a behavior-preserving rename.
- Keep the old package/controller naming: incomplete public rename and less clear source navigation.
- Delete/reuse all old artifacts immediately: loses evidence or encounters absolute-path cache errors.
