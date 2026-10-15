---
type: convention
title: Knowledge format and maintenance
status: current
tags: [knowledge, okf, maintenance]
---

# Knowledge format and maintenance

This is **OKF-style**, adopting the reference project's plain-file conventions, not claiming compliance with an external schema or introducing a knowledge engine. See [ADR-001](../adr/001-indexed-knowledge.md).

## Files and metadata

One concept per Markdown file, descriptive kebab-case names, relative Markdown links. All knowledge files start with YAML frontmatter:

```yaml
type: mechanic
title: App routing
status: implemented
tags: [routing, lifecycle]
```

- `type`: `index`, `todo`, `concept`, `convention`, `architecture`, `mechanic`, `verification` or `adr`.
- `status`: indexes/todo/conventions/product use `current`; implementation concepts use `implemented` or `proposed`; verification uses `partial`; ADRs use `proposed`, `accepted` or `superseded`.
- `tags`: a short inline list for discovery; not a second hierarchy.
- An implementation status does **not** certify real-host behavior. Record evidence and limitations separately.

Indexes are tables of contents, not summaries or state stores. Mechanics own observable rules; architecture owns code responsibilities and development practice; ADRs own rationale and tradeoffs. Link between them instead of repeating the same contract.

## Cheap traversal

From the repository root:

```sh
rg -n '^(type|status|tags):' knowledge
rg -l '^tags:.*(identity|cleanup)' knowledge
```

Read only the selected concept, then its named source/test owners. Use stable file paths and symbols, not line numbers that drift. Do not recursively preload linked docs.

## Changes

Update the owning concept when behavior/ownership changes; update `todo.md` only for current scope/status changes. Remove completed handoff narrative from the hot file rather than accumulating a session log. Detailed evidence stays in the relevant verification record or a retained local artifact, with coverage and limitations named.

Every significant change requires a focused ADR in the same change set, completed before starting the next significant change. Draft before implementation when feasible; reconcile with the actual result and verification afterward. Significant changes alter architecture/resource ownership, boundary interpretation, identity/uncertainty, safety/authority, user interaction/information policy or consequential tradeoffs. Routine fixes, dead-field removal and mechanical implementation of an accepted rule do not need separate records; link the governing ADR from the owning concept.

ADRs have stable sequential numbers and Context, Decision, Consequences, and Alternatives sections. Write primarily for LLM agents: explicit constraints/decision rules, rationale, rejected alternatives, source/test owners, verification limits and conditions for reconsideration. Keep prose concise and link mechanics instead of repeating them. Separate independent decisions, not individual files or edits.

Existing-implementation records explicitly say they document the baseline; distinguish user-authorized decisions from agent implementation choices. Records are not new side-effect approvals or retrospective host certification. Supersede a decision through a new linked ADR instead of silently rewriting its historical rationale. See the operational rule in [AGENTS.md](../../AGENTS.md).

Source is the implemented-behavior authority. If docs drift, inspect source/tests and correct the owning document; documentation must never silently override safety policy. Keep paths/metadata/links valid using the [documentation checks](development.md#documentation-only-changes).
