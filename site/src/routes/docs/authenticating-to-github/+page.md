---
title: Authenticating to GitHub
order: 2.5
---

The native `sideshow` CLI talks to GitHub through the
[GitHub API RefStore](/docs/design/github-api-refstore/) when invoked
with `--refstore github`. Every request needs a Personal Access Token
(PAT). The `sideshow auth` and `sideshow gh auth` commands give you
a safe way to provide one without leaking it through shell history,
process listings, or world-readable files.

This page walks through the full flow: creating a PAT, signing in,
inspecting status, and signing out.

## Prerequisites

- The `sideshow` binary on your `PATH`. See
  [Getting Started](/docs/getting-started/) for install instructions.
- A GitHub repository you own or can write to.
- A controlling terminal (`/dev/tty`) when you want to paste the token
  interactively. CI environments use `--with-token` to read the token
  from stdin instead; the headless flow is covered below.

## Create a Personal Access Token

You can use either token family:

| Token type | Required scope | Notes |
| ---- | ---- | ---- |
| Classic PAT | `repo` | Full read/write to the Git Database API. |
| Fine-grained PAT | **Contents: Read and write** on the target repository | Recommended; minimum-privilege fit for the SideshowDB workload. |

Read-only callers (`get`, `list`, `history`) need only the read variant
of the same scope. The CLI surfaces scope hints when an upstream rejects
a request.

Create the token in **GitHub → Settings → Developer settings → Personal
access tokens**. Copy it once; GitHub will not show it again.

## Sign in interactively

Run:

```bash
sideshow gh auth login
```

The CLI prompts you on `/dev/tty` with terminal echo disabled:

```
Paste your GitHub Personal Access Token (will not be echoed):
```

Paste the token and press **Return**. The token never lands in your
shell history (you did not type it as an argument), in
`/proc/<pid>/cmdline` (it never reached argv), or in terminal
scrollback (echo was off for the duration of the prompt).

On success the CLI prints a redacted confirmation:

```
Logged in to github.com (token: ghp_****…ab12)
```

Only the family prefix and the last four characters are surfaced; the
full token is never printed.

## Headless and CI usage

When there is no TTY (CI runners, scripts, devcontainer rebuilds), pass
the token on stdin with `--with-token`:

```bash
echo "$GITHUB_PAT" | sideshow gh auth login --with-token
```

The CLI trims trailing whitespace, rejects tokens that contain embedded
whitespace or null bytes, and exits with a non-zero status if stdin is
empty. It does **not** read `$GITHUB_PAT` directly — your shell expands
the variable before piping it in, which is the conventional CI shape.

If you would rather defer the upstream verification call (for instance
to bring up an air-gapped runner before GitHub is reachable), add
`--skip-verify`:

```bash
echo "$GITHUB_PAT" | sideshow gh auth login --with-token --skip-verify
```

Verification on login is opt-out; pre-validating the token saves a
later 401 round-trip when the actual `doc` command runs.

## Inspect status

Show every authenticated host:

```bash
$ sideshow auth status
github.com  source=hosts-file  token=ghp_****…ab12
```

Filter to GitHub specifically (returns exit code 1 when no GitHub
credential is configured, useful in scripts):

```bash
$ sideshow gh auth status
github.com  source=hosts-file  token=ghp_****…ab12
```

Machine-readable form for shell pipelines:

```bash
$ sideshow --json auth status
{"hosts":[{"host":"github.com","source":"hosts-file","token_preview":"ghp_****…ab12"}]}
```

The redacted preview is the only surface that ever exposes any part of
the token.

## Sign out

Remove a single host:

```bash
sideshow auth logout --host github.com
```

Remove every entry at once:

```bash
sideshow auth logout
```

Sign-out is idempotent at the file level (atomic rewrite, last entry
deletes the file). It exits 1 if the named host is not present, so
scripts can rely on the exit code.

## Where the token lives

The CLI stores credentials in a per-user config file:

| Path | Purpose | Mode |
| ---- | ---- | ---- |
| `$XDG_CONFIG_HOME/sideshowdb/hosts.toml` (or `~/.config/sideshowdb/hosts.toml`) | Per-host PAT and metadata | `0600` |
| `$XDG_CONFIG_HOME/sideshowdb/` | Containing directory | `0700` |

Override the location with `SIDESHOWDB_CONFIG_DIR` for tests or
sandboxes; the CLI honours it ahead of `XDG_CONFIG_HOME`.

The on-disk format is a small, hand-readable TOML subset:

```toml
[hosts."github.com"]
oauth_token = "ghp_..."
user = "octocat"
git_protocol = "https"
```

Writes are **atomic** (temp file plus `rename`) and explicitly
re-`chmod`ed to `0600` on every replace, so a permissive umask cannot
soften the file. The CLI re-checks permissions on read and refuses to
hand a token to the credential walker when the mode bits are
group- or world-readable.

## Use the token from the CLI

Once you are signed in, target a GitHub repository with `--refstore
github`:

```bash
sideshow \
  --refstore github \
  --repo octocat/sideshow-data \
  --ref refs/sideshowdb/documents \
  doc list
```

The flags resolve in this order:

1. `--refstore github` (or `SIDESHOWDB_REFSTORE=github`) selects the
   backend.
2. `--repo owner/name` (or `SIDESHOWDB_REPO`) names the repository.
3. `--ref refname` (or `SIDESHOWDB_REF`, default
   `refs/sideshowdb/documents`) names the ref.
4. The credential auto-walker resolves a token. The native chain is
   `--credentials explicit` &gt; `GITHUB_TOKEN` env var &gt;
   `hosts.toml` (the file written by `gh auth login`) &gt; `gh auth
   token` &gt; `git credential fill`. The first source that produces a
   token wins.

Missing pieces fail loudly **before** any HTTP request:

- `--refstore github` without `--repo` exits 1 with `--refstore github
  requires --repo owner/name`.
- No resolvable credentials exits 1 with
  `no GitHub credentials configured; run 'sideshow gh auth login'`.

## Security model

The auth surface is built to honour these guarantees:

- **Token never echoed.** Interactive prompts run on `/dev/tty` with
  `ECHO` off. Errors print only the redacted preview (`ghp_****…last4`).
- **Token never on argv.** The CLI does not accept a token as a
  command-line argument. Stdin (`--with-token`) and the secure prompt
  are the only inputs.
- **Token never in shell history.** Because it is not a command
  argument, the shell does not record it.
- **File mode 0600.** The hosts file and its parent directory are
  enforced on every write. A permissive umask is overridden.
- **Permissive-mode files are not trusted.** Reading a file with
  group- or world-readable bits returns an `AuthInvalid` so the
  credential walker advances or fails closed.
- **No upstream redirect leaks.** The
  [GitHub API RefStore](/docs/design/github-api-refstore/) sends the
  Authorization header only to its configured `api_base`; redirects to
  other hosts are not followed.

The threat model is documented alongside the
[Auth model](/docs/design/auth-model/) page.

## Troubleshooting

- **`interactive login requires a TTY; pass --with-token to read from
  stdin`** — your shell session has no controlling TTY. Use
  `--with-token` instead.
- **`empty token on stdin`** — your stdin produced only whitespace
  after trimming. Re-check the variable expansion or the source of the
  piped value.
- **`token must not contain whitespace`** — the value contained a
  space, tab, newline, or null byte. PATs are opaque ASCII strings; if
  yours has whitespace it was almost certainly mangled in transit.
- **`token invalid (HTTP 401)`** — the upstream rejected the token at
  verification. Generate a fresh PAT with the right scopes and rerun
  `gh auth login`.
- **`warning: hosts.toml is world- or group-readable`** — something
  else (your editor, a sync tool) loosened the mode bits since the
  last write. Run `sideshow gh auth login` again to re-tighten, or
  `chmod 600 ~/.config/sideshowdb/hosts.toml`.

## See also

- [CLI Reference](/docs/cli/) — the canonical, KDL-generated surface.
- [GitHub API RefStore design](/docs/design/github-api-refstore/) — the
  store these credentials feed.
- [Auth model](/docs/design/auth-model/) — credential resolution
  precedence and required scopes.
