# AudioRouter

## Session protocol
1. Start with `knowledge/index.md` and `knowledge/todo.md`. Read nothing else unless relevant to the task.
2. Follow the relevant concept to its source/test owners. Consult `knowledge/adr/index.md` only when a decision matters.
3. Every significant change requires an ADR in the same change set, completed before starting the next significant change. Draft the decision before implementation when feasible; reconcile it with the implemented result and verification afterward. Update the affected concept and active todo if scope/status changed.
4. Keep indexes as navigation only and `knowledge/todo.md` as the short active backlog. Never preload the whole knowledge tree or historical handoff.

## Knowledge format
- OKF-style Markdown: one concept per file, YAML frontmatter (`type`, `title`, `status`, `tags`), relative Markdown links. See `knowledge/architecture/knowledge-format.md` when authoring knowledge.
- Filter metadata before reading: `rg -n '^(type|status|tags):' knowledge`.
- Source defines implemented behavior; concept files explain it; ADRs explain decisions. Tests and user reports establish only their stated verification scope.
- No separate vision tree: `knowledge/product-scope.md` owns purpose and boundaries. Mechanics describe behavior; architecture describes ownership and maintenance.

## Decision records for agents
- A change is significant when it changes architecture/resource ownership, boundary interpretation, identity/uncertainty semantics, safety/authority, user interaction or information policy, or introduces a consequential tradeoff future agents might otherwise undo.
- Create a focused, sequential ADR under `knowledge/adr/` and add it to the ADR index. Separate independent decisions; do not create one record per file or mechanical edit.
- Routine fixes, dead-field removal and mechanical reuse of an already accepted rule do not need a new ADR. Link the governing ADR from the owning concept; if the rule changes, create a new ADR that explicitly supersedes it rather than rewriting historical rationale.
- Write ADRs primarily for LLM agents: concise, explicit constraints and decision rules, source/test owners, rejected alternatives with reasons, consequences, verification limits and conditions for reconsideration. Avoid narrative padding and duplicated mechanics; link the current concept instead.
- Distinguish user-authorized decisions from agent implementation choices and retrospective baseline records. An accepted ADR is not proof of successful live behavior or permission for new side effects.

## Implementation and safety
- Swift source in `Sources/AudioRouter/`; standalone tests in `Tests/AudioRouterTests/`. No REA or SoundSource runtime dependency. Never copy SoundSource code/assets or modify its bundle.
- Keep app routing separate from explicit System-default/hardware-control writes.
- Preserve parsed lifetime identity, explicit unknowns and caller-selected destinations. Names/icons/PIDs alone are not identity proof.
- Reuse the existing route lifecycle; retain failed restoration/cleanup ownership. Restore original playback before teardown; failed Quit stays blocked.
- Audio callbacks must remain bounded and preallocated: no allocation, locks, UI calls or actor hops.
- Use the build/test commands in `knowledge/architecture/development.md`. Automated tests must not start live capture/playback or write host audio settings.
- When relevant checks pass and changes are ready for user testing, automatically create a fresh incrementally versioned app package (`AudioRouter-MAJOR-MINOR-PATCH.app`, no timestamps), align its plist version and increment its build number, and verify its plist/signature; the user explicitly requested this standing packaging workflow. Preserve older bundles. See `knowledge/architecture/development.md`.
- Packaging authorization does not authorize launching, changing host settings or running overlapping app copies. Launch requires user authorization; quit any older copy normally and verify it exited before replacement. Builds/signing are not live verification.
- Never delete files or artifacts without explicit confirmation. Preserve ignored local evidence and old bundles.
- Keep changes scoped. Git commits/pushes require user authorization; never stage build outputs, credentials or local session artifacts.
