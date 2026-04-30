# CLI Auth Subcommands EARS

User-facing requirements for the SideshowDB CLI **auth** family. These
commands give users a safe way to provide a GitHub Personal Access Token
(PAT) to the CLI without leaking the token through shell history,
process argv, or world-readable files.

The surface is modelled on the GitHub CLI (`gh auth status`,
`gh auth login`, `gh auth logout`) but is provider-agnostic at the top
level: `auth` covers all configured hosts; provider-scoped commands sit
under `<provider> auth ...` (initially only `gh`).

API symbols (Zig): `cli.app.run`, `storage.credential_sources.HostsFileSource`,
`cli.auth.SecurePrompt`.
**Companion ADR:** `docs/design/adrs/2026-04-29-github-api-refstore.md`.

## Scope

- `sideshowdb auth status` — list known hosts and active credential sources.
- `sideshowdb auth logout [--host <h>]` — remove stored credentials.
- `sideshowdb gh auth login [--with-token]` — obtain a GitHub PAT and persist
  it under `~/.config/sideshowdb/hosts.toml` (mode 0600).
- `sideshowdb gh auth status` / `sideshowdb gh auth logout` — provider-scoped
  variants that act on `github.com` only.
- New CLI flag `--refstore github` plus `--repo owner/name` and `--ref <name>`
  passthrough so authenticated callers can drive `GitHubApiRefStore`.
- A `HostsFileSource` `CredentialProvider` slotted into the native auto walker.

Out of scope (separate tickets): zigzag-based interactive TUI, OAuth Device
Flow, encrypted-at-rest token storage (relies on OS keychain), GitHub Apps,
SSO scope discovery beyond what 401/403 responses already convey.

## Threat model

- Attacker with read access to shell history must not learn the PAT.
- Attacker with read access to `/proc/<pid>/cmdline` (or equivalent process
  listing) must not learn the PAT.
- Attacker with read access to the user's home directory but **not** their
  POSIX user must not learn the PAT (mode 0600, parent dir 0700).
- A compromised process running as the same user already wins; we do not
  attempt to defend against that.

## EARS

### `auth` parent command

- **CLIA-001**
  When `sideshowdb auth` is invoked with no subcommand, the CLI shall
  exit with code 1 and print the usage message to stderr.

- **CLIA-002**
  The CLI shall accept exactly the following `auth` subcommands: `status`,
  `logout`. Any other token after `auth` shall return exit code 1 and a
  usage message.

### `auth status`

- **CLIA-010**
  When `sideshowdb auth status` is invoked and no hosts are configured, the
  CLI shall exit with code 0 and print `No authenticated hosts.\n` to
  stdout.

- **CLIA-011**
  When `sideshowdb auth status` is invoked and at least one host has a
  stored credential, the CLI shall exit with code 0 and print, for each
  host, the host name, the credential source (`hosts-file`, `env`,
  `gh-cli`, or `git-helper`), and a redacted token preview of the form
  `gho_****…last4` (never the full token).

- **CLIA-012**
  When `sideshowdb --json auth status` is invoked, the CLI shall emit a
  JSON object `{"hosts":[{"host":"github.com","source":"hosts-file",
  "token_preview":"gho_****…ab12"}]}` and shall not include the full
  token under any key.

- **CLIA-013**
  If `~/.config/sideshowdb/hosts.toml` exists with mode bits other than
  0600, then `auth status` shall print a `warning: hosts.toml is
  world- or group-readable` notice to stderr but shall still exit 0.

### `auth logout`

- **CLIA-020**
  When `sideshowdb auth logout --host <h>` is invoked and `<h>` has a
  stored credential, the CLI shall remove that host's entry from
  `hosts.toml`, exit 0, and print `Logged out of <h>.\n` to stdout.

- **CLIA-021**
  When `sideshowdb auth logout --host <h>` is invoked and `<h>` has no
  stored credential, the CLI shall exit 1 with stderr message
  `not logged in to <h>\n` and shall not modify `hosts.toml`.

- **CLIA-022**
  When `sideshowdb auth logout` is invoked with no `--host`, the CLI
  shall remove all entries from `hosts.toml` and shall exit 0 only if at
  least one entry was removed; otherwise it shall exit 1 with stderr
  `not logged in to any host\n`.

- **CLIA-023**
  After a successful logout the CLI shall rewrite `hosts.toml` atomically
  (write tmpfile, fsync, rename) preserving mode 0600.

### `gh auth login`

- **CLIA-030**
  When `sideshowdb gh auth login --with-token` is invoked, the CLI shall
  read the token from stdin, trim trailing whitespace, store it under
  `[hosts."github.com"] oauth_token = "..."` in `hosts.toml`, and exit 0.

- **CLIA-031**
  If `--with-token` is supplied and stdin is empty after trimming, then
  the CLI shall exit 1 with stderr `empty token on stdin\n` and shall
  not modify `hosts.toml`.

- **CLIA-032**
  When `sideshowdb gh auth login` is invoked without `--with-token` and
  stdin is a TTY, the CLI shall prompt for the PAT on `/dev/tty` with
  echo disabled, never echo the token to either stdout or stderr, and
  shall not write the token to any log sink.

- **CLIA-033**
  If `sideshowdb gh auth login` is invoked without `--with-token` and
  stdin is **not** a TTY, then the CLI shall exit 1 with stderr
  `interactive login requires a TTY; pass --with-token to read from
  stdin\n`.

- **CLIA-034**
  When the prompt or stdin produces a token, the CLI shall reject any
  value containing whitespace or null bytes by exiting 1 with stderr
  `token must not contain whitespace\n` and shall not modify
  `hosts.toml`.

- **CLIA-035**
  When the CLI persists a token, the parent directory
  `~/.config/sideshowdb/` shall be created with mode 0700 if missing,
  and `hosts.toml` shall be written with mode 0600. Existing files with
  permissive modes shall be tightened on write.

- **CLIA-036**
  When the CLI persists a token, the printed confirmation shall be
  `Logged in to github.com (token: <preview>)\n`, or
  `Logged in to github.com as <user> (token: <preview>)\n` when an
  upstream verification call resolves a username. `<preview>` is the
  redacted form documented in CLIA-011.

- **CLIA-037**
  Where a verify hook is wired and the supplied token fails the
  upstream verification call with 401, the CLI shall exit 1 with stderr
  `token invalid (HTTP 401)\n` and shall not write `hosts.toml`. The
  default native build ships with verification deferred (`--skip-verify`
  is implicit) and is tracked under follow-up issue
  `sideshowdb-idg`.

### `gh auth status` and `gh auth logout`

- **CLIA-040**
  When `sideshowdb gh auth status` is invoked, the CLI shall behave as
  `sideshowdb auth status --host github.com`, exiting 0 with status for
  the github host or printing `Not logged in to github.com.` and
  exiting 1 if absent.

- **CLIA-041**
  When `sideshowdb gh auth logout` is invoked, the CLI shall behave as
  `sideshowdb auth logout --host github.com`.

### `--refstore github`

- **CLIA-050**
  When `sideshowdb --refstore github` is invoked without `--repo
  <owner/name>`, the CLI shall exit 1 with stderr `--refstore github
  requires --repo owner/name\n` and shall not perform any HTTP request.

- **CLIA-051**
  When `sideshowdb --refstore github --repo <owner/name>` is invoked and
  no credential is resolvable from any source, the CLI shall exit 1
  with stderr `no GitHub credentials configured; run sideshowdb gh auth
  login\n` and shall not perform any HTTP request.

- **CLIA-052**
  When `sideshowdb --refstore github` resolves credentials, the CLI
  shall instantiate a `GitHubApiRefStore` and route document commands
  through it. (Deferred: this iteration ships the surface for
  `--refstore github` and the `--repo` / credential-missing error
  paths only; the live wiring of `GitHubApiRefStore` into the document
  command pipeline is tracked separately.)

### `HostsFileSource` credential provider (deferred to `sideshowdb-idg`)

The following requirements specify behaviour for the credential source
that backs `--refstore github`. They land with the live wiring of
`GitHubApiRefStore` into the document command pipeline and are
informational here.


- **CLIA-060**
  When the auto walker probes `HostsFileSource` for `host=github.com`
  and `hosts.toml` contains an `oauth_token` for that host, the source
  shall return a bearer credential equal to the stored token.

- **CLIA-061**
  When `HostsFileSource` is probed and `hosts.toml` does not exist or
  has no entry for the requested host, the source shall return
  `HelperUnavailable` so the walker advances.

- **CLIA-062**
  If `HostsFileSource` reads `hosts.toml` and the file has mode bits
  other than 0600, then the source shall return `AuthInvalid` and shall
  not log the token bytes.

- **CLIA-063**
  In the native auto walker, `HostsFileSource` shall be probed after
  `ExplicitSource` and `EnvSource` and before `GhHelperSource`,
  `GitHelperSource`, and `HostCapabilitySource`.
