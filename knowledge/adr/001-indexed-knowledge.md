---
type: adr
title: Indexed OKF-style concepts and ADRs
status: accepted
tags: [knowledge, okf, maintenance]
---

# ADR-001: Indexed knowledge

## Context

The standalone utility has a long README and local handoff mixing behavior, code maps, historical measurements and future work. The user requested the Roblox project's OKF-style thinking and ADR/architecture/mechanics structure before cleanup, to make traversal and maintenance cheaper.

## Decision

Use plain Markdown concept files with `type`, `title`, `status`, `tags` frontmatter and relative links. Start sessions with the knowledge index and short todo; load only relevant concepts and their source/test owners. Indexes are navigation only.

Mechanics own observable behavior, architecture owns implementation/maintenance, and ADRs explain durable decisions. Keep purpose/non-goals in one [product scope](../product-scope.md) file instead of a separate vision tree. Source remains implemented-behavior authority; tests/user reports retain explicit scope.

This adopts OKF-style conventions, not an external-format compliance claim. No database, generator or knowledge runtime is needed. [Knowledge format](../architecture/knowledge-format.md) defines authoring and metadata rules.

## Consequences

Knowledge becomes a tracked maintenance surface. Update the owning concept alongside relevant changes, not every doc. `knowledge/todo.md` owns current work; the ignored root handoff and README history are retained until separately scoped cleanup. They are not session-start prerequisites.

This bounds initial reading and provides direct code links, but token/time savings are unmeasured. No performance guarantee or new runtime behavior is implied.

## Alternatives

- Keep a single growing handoff: simpler initially, but mixes authority/history and forces broad reading.
- Copy the game's full vision/assets hierarchy: unnecessary for a utility with no current need for those concepts.
- Introduce a knowledge engine or custom schema tooling now: more maintenance without an observed requirement.
