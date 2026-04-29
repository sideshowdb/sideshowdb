# Design documentation

This directory is the **canonical home for developer-facing design
material**: architecture narratives that are not product specs, **ADRs**
(architecture decision records), **RFCs** (larger proposals before
implementation), and cross-cutting notes that explain *why* the code looks
the way it does.

## Layout

| Path | Purpose |
| ---- | ------- |
| [`adrs/`](./adrs/) | Accepted (or superseded) ADRs — one decision per file, dated title, immutable history |
| [`rfc/`](./rfc/) | In-flight RFCs and design sketches that may promote to an ADR or be withdrawn |

## Relationship to other docs

- **Normative product requirements** (EARS, user-visible contracts) stay under
  [`docs/development/specs/`](../development/specs/) and map to tests and
  acceptance scenarios.
- **Older ADRs** written before this hub existed may still live under
  [`docs/development/decisions/`](../development/decisions/); new ADRs should
  prefer `docs/design/adrs/` so everything is discoverable from this README.

## How to add an ADR

1. Copy the structure from an existing file in `adrs/` (Context → Options →
   Decision → Consequences).
2. Use a **date-prefixed** filename: `YYYY-MM-DD-short-slug.md`.
3. Link the ADR from the PR that implements or ratifies the decision, and
   from a `bd` issue (`--design`, `--description`, or `--notes`) when the
   change was tracked in beads.
4. If the decision supersedes an earlier note, say so in **Status** and link
   the prior ADR or issue.

## Index

| Document | Status |
| -------- | ------ |
| [Host capabilities and host store API (TypeScript WASM)](./adrs/2026-04-29-host-capabilities-store-api.md) | Accepted (beads: `sideshowdb-ywt`, `bd remember` key `ts-host-capabilities-store`) |
| [GitHub API RefStore as the primary remote-backed store](./adrs/2026-04-29-github-api-refstore.md) | Accepted (supersedes ziggit-based options `sideshowdb-an4`, `sideshowdb-dgz`) |
| [Deprecate and remove ziggit-based RefStore](./adrs/2026-04-29-deprecate-ziggit.md) | Accepted (companion to GitHub API RefStore ADR) |
