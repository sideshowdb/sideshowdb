---
title: Design hub
order: 3.5
---

Long-lived **design notes**, **ADRs** (architecture decision records), and
**RFCs** for Sideshowdb live in the repository under
[`docs/design/`](https://github.com/sideshowdb/sideshowdb/tree/main/docs/design).

Start at the
[design README](https://github.com/sideshowdb/sideshowdb/blob/main/docs/design/README.md)
for the index, folder conventions, and how to add a new ADR.

### Why not only EARS specs?

[`docs/development/specs/`](https://github.com/sideshowdb/sideshowdb/tree/main/docs/development/specs)
holds **normative** user-visible requirements (EARS) that map directly to
tests and acceptance scenarios. The design hub holds **rationale** —
options we rejected, vocabulary we chose, and how we expect the API to
evolve — so contributors can see the thought behind the code without mixing
that narrative into the contract documents.

### Trace example

The browser TypeScript client uses `hostCapabilities.store` instead of a
flat `hostBridge` option; see ADR
[Host capabilities and host store API](https://github.com/sideshowdb/sideshowdb/blob/main/docs/design/adrs/2026-04-29-host-capabilities-store-api.md).
