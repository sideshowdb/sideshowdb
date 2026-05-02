# Serde Config Design

## Goal

Unify SideshowDB's Zig configuration model behind one serde-backed module before
migrating wire-format serialization. The first phase standardizes persisted
configuration, local/global precedence, and a git-like `sideshow config` CLI
surface. JSON wire helpers for documents, events, snapshots, WASM, and the
GitHub API move in follow-up work after the configuration layer is stable.

Tracked by beads issue `sideshowdb-bum`.

## Scope

In scope:

- Add `serde.zig` as the standard Zig dependency for configuration
  serialization.
- Add a shared `sideshowdb.config` module, re-exported from the core root.
- Parse and render persisted TOML config through serde.
- Support local config at `.sideshowdb/config.toml`.
- Support global config at the existing SideshowDB config directory convention:
  `SIDESHOWDB_CONFIG_DIR/config.toml`, otherwise the platform config directory
  such as `$XDG_CONFIG_HOME/sideshowdb/config.toml` or
  `$HOME/.config/sideshowdb/config.toml`.
- Add `sideshow config get|set|unset|list` with `--local` and `--global`.
- Move native RefStore resolution out of the CLI-only selector and into the
  shared config module.
- Preserve the existing usage-spec CLI generation flow from the serde
  migration. A small positional-argument extension is allowed if needed for the
  git-like `sideshow config get <key>` shape, but usage files must not adopt
  serde.

Out of scope for this phase:

- Migrating document/event/snapshot transport JSON.
- Migrating WASM bridge JSON.
- Migrating GitHub API request and response JSON.
- Storing literal tokens in persisted config.
- Full `git config` compatibility such as includes, multi-valued keys,
  `--replace-all`, or `--show-origin`.

## Requirements

- When the CLI resolves the native document RefStore, the config system shall
  apply precedence in this order: CLI flags, environment variables, local config,
  global config, built-in defaults.
- When a local config file contains `refstore.kind = "github"`, the CLI shall
  select the GitHub backend unless a higher-precedence source overrides it.
- When a global config file contains `refstore.kind = "github"` and no local,
  environment, or flag override exists, the CLI shall select the GitHub backend.
- When `SIDESHOWDB_REFSTORE` is set, the CLI shall prefer it over local and
  global config.
- When `--refstore` is supplied, the CLI shall prefer it over every config and
  environment source.
- When a config file contains an unknown field or an invalid enum value, the
  config system shall return a typed invalid-config error without mutating
  document state.
- When a caller runs `sideshow config set --local <key> <value>`, the CLI shall
  update `.sideshowdb/config.toml`, creating parent directories as needed.
- When a caller runs `sideshow config set --global <key> <value>`, the CLI shall
  update the user config file, creating parent directories as needed.
- When a caller runs `sideshow config get <key>` without a scope, the CLI shall
  print the resolved value and identify its source in JSON mode.
- When a caller runs `sideshow config list` without a scope, the CLI shall print
  the resolved flattened config view.
- When a caller runs `sideshow config unset --local <key>` for a missing key,
  the CLI shall leave the file unchanged and exit successfully.
- If a caller supplies both `--local` and `--global`, then the CLI shall fail
  with a usage error and not write a config file.
- If a caller attempts to persist a literal credential token, then the CLI shall
  reject the write and explain that persisted config may name credential sources
  but not store secrets.

## Module Architecture

Add `src/core/config.zig` and re-export it from `src/core/root.zig` as
`sideshowdb.config`.

The module owns persisted configuration types:

```zig
pub const Config = struct {
    refstore: RefStoreConfig = .{},
    credentials: CredentialConfig = .{},
};

pub const RefStoreConfig = struct {
    kind: ?RefStoreKind = null,
    repo: ?[]const u8 = null,
    ref_name: ?[]const u8 = null,
    api_base: ?[]const u8 = null,
    credential_helper: ?CredentialHelper = null,
};

pub const RefStoreKind = enum { subprocess, github };
pub const CredentialHelper = enum { auto, env, gh, git };

pub const CredentialConfig = struct {
    helper: ?CredentialHelper = null,
};
```

Fields stay optional in the persisted shape so local and global files can layer
cleanly. A separate `ResolvedConfig` carries final defaults plus source metadata
for CLI JSON output and diagnostics.

The module exposes focused operations:

- `loadFile(gpa, path)`: read TOML into `Config`.
- `saveFile(gpa, path, config)`: render TOML using serde and atomically write
  where the host platform supports it.
- `loadLocal(gpa, repo_path)` and `loadGlobal(gpa, env)`.
- `resolve(gpa, repo_path, env, cli_overrides)`: merge all layers.
- `getPath`, `setPath`, `unsetPath`: operate on supported dotted keys.
- `listFlattened`: return stable key/value/source rows.

Runtime constructor structs such as `GitHubApiRefStore.Options`,
`SubprocessGitRefStore.Options`, and credential-source configs remain near their
implementations. The config module converts resolved persisted config into those
runtime options, keeping storage independent of CLI parsing.

## CLI Surface

Add a `config` command group to the usage spec:

```text
sideshow config get [--local|--global] <key>
sideshow config set [--local|--global] <key> <value>
sideshow config unset [--local|--global] <key>
sideshow config list [--local|--global]
```

Read commands without a scope read the resolved view. Write commands without a
scope default to `--local`, matching SideshowDB's repo-centered workflow.

Plain text output:

- `get`: `<value>\n`.
- `list`: sorted `key=value\n` lines.
- `set`: no stdout on success.
- `unset`: no stdout on success.

JSON output:

- `get`: `{"key":"refstore.kind","value":"github","source":"local"}`.
- `list`: a stable array of objects with `key`, `value`, and `source`.
- `set` and `unset`: a small status object naming the changed key and scope.

Supported initial keys:

- `refstore.kind`
- `refstore.repo`
- `refstore.ref_name`
- `refstore.api_base`
- `refstore.credential_helper`

The CLI may add aliases later, but the persisted schema should keep one
canonical spelling per field.

## Error Handling

Invalid config is loud and typed. TOML parse errors, unknown fields, unsupported
dotted keys, and invalid enum values map to user-facing messages that name the
bad file or key. RefStore resolution failures keep current behavior where
possible, including `unsupported refstore: expected subprocess|github`.

Writes reject secret-shaped fields. The persisted model may reference credential
sources such as `env`, `gh`, or `git`, but it shall not accept a raw OAuth token
field. The existing auth hosts file remains the credential store.

Unset is idempotent. Removing a missing key succeeds because that behavior is
script-friendly and matches the way users often write cleanup commands.

## Testing

Use TDD for implementation:

- Unit-test serde TOML parsing and rendering for empty, local-only, global-only,
  and layered configs.
- Unit-test unknown fields, malformed TOML, invalid enum values, and unsupported
  dotted keys.
- Unit-test `getPath`, `setPath`, `unsetPath`, and `listFlattened`.
- Unit-test precedence: flag, environment, local, global, default.
- CLI tests for `config get`, `config set`, `config unset`, and `config list`.
- CLI regression tests proving existing `--refstore` and `SIDESHOWDB_REFSTORE`
  behavior still wins.
- Acceptance scenarios under `acceptance/typescript/features/` for local/global
  config writes, reads, precedence, invalid values, and JSON output.
- Usage runtime changes are limited to positional command arguments required by
  `sideshow config get <key>`, `set <key> <value>`, and `unset <key>`.

## Follow-Up Work

After this config phase lands, create linked beads for the wire-format migration:

- Move document transport JSON parsing/rendering to serde-backed helpers.
- Move event and snapshot JSON parsing/rendering to serde-backed helpers.
- Move WASM bridge JSON parsing to serde-backed helpers.
- Move GitHub API request/response JSON to typed serde structs.
- Decide whether tests should keep using `std.json.Value` for assertions or
  adopt typed serde fixtures.
