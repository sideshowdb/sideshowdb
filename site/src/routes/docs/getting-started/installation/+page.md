---
title: Installation
order: 2
---

This page collects every supported way to get the native **`sideshow`**
CLI onto your machine. After install, jump back to
[Getting Started](/docs/getting-started/) for an end‑to‑end example.

Release assets use the naming pattern
`sideshow-<version>-<os>-<arch>.<ext>` and publish a **`SHA256SUMS`**
file you can verify before running anything.

Linux archives are statically linked (**musl**). macOS builds target the
stock platform ABI.

## Repo wrapper scripts (`sideshow`)

Copy the Gradle-style wrappers from the repository root alongside your
project (or vendor them once for your org):

| File | When to use |
| ---- | ----------- |
| `sideshow` | **Linux**, **macOS**, and **Git Bash / MSYS**: Bash launcher that downloads pinned releases into `SIDESHOWDB_HOME`. |
| `sideshow.ps1` + `sideshow.cmd` | Native **Windows** (PowerShell 5.1+ or `pwsh`). `sideshow.cmd` delegates to PowerShell. |

The Unix script is Bash-based (`#!/usr/bin/env bash`). It downloads a
release if needed, verifies **`SHA256SUMS`**, caches the binary, and
**`exec`s** the real CLI so stdout stays clean for piping.

**Pin the CLI version** (first match wins):

1. **`-V` / `--cli-version`** (both wrappers).
2. Environment **`SIDESHOWDB_CLI_VERSION`** (same accepted values).
3. Project pin file next to the script: **`.sideshowdb-version`** or
   **`sideshowdb.version`** (first non-empty line).
4. Otherwise **`latest`** (GitHub `releases/latest` JSON; **Python 3**
   required on Unix to parse it).

Other useful switches: **`--install-only`**, **`--force`** / **`-f`**,
**`--print-path`**, **`--`** before CLI args, **`--verbose`** /
**`-v`**, **`--quiet`** / **`-q`**, **`--trace`** (shell trace /
`Set-PSDebug`). Wrapper diagnostics go to **stderr**; help and
`--print-path` use **stdout**.

```bash
# Examples (Unix wrapper)
chmod +x ./sideshow

./sideshow --help
./sideshow -V 0.1.0 --install-only --verbose

# Pin for everyone committing the wrapper
echo '0.1.0' > .sideshowdb-version

# One-off cache location
SIDESHOWDB_HOME=/srv/cache/sideshowdb ./sideshow --print-path
```

```powershell
# Windows examples
.\sideshow.ps1 --help

$env:SIDESHOWDB_HOME = 'D:\caches\sideshowdb'
.\sideshow.ps1 -V latest --install-only -v
```

> **Windows CLI artifacts:** wrappers expect **`sideshow-<version>-windows-<arch>.zip`** files on GitHub Releases. The **[release workflow](https://github.com/sideshowdb/sideshowdb/blob/main/.github/workflows/release.yml)** currently builds Linux and macOS CLI archives first; add a Windows publish job (or attach matching zips) before relying on **`sideshow.ps1`** in production.

## Cache and install paths (`SIDESHOWDB_HOME`)

Downloaded binaries are stored under **`SIDESHOWDB_HOME`**. Override it
when you want a shared cache or a non-default drive.

Normalized release version (**no leading `v`**) appears as `<version>` in paths.

### Default locations (no override)

| OS / environment | `SIDESHOWDB_HOME` | Example CLI path (`<version>` = `0.4.2`) |
| ---------------- | ---------------- | --------------------------------------- |
| **Linux** | `~/.sideshowdb/wrapper` | `~/.sideshowdb/wrapper/cli/0.4.2/dist/sideshow` |
| **macOS** | `~/.sideshowdb/wrapper` | `/Users/you/.sideshowdb/wrapper/cli/0.4.2/dist/sideshow` |
| **Windows** (native wrapper) | `%USERPROFILE%\.sideshowdb\wrapper` | `%USERPROFILE%\.sideshowdb\wrapper\cli\0.4.2\dist\sideshow.exe` |
| **Git Bash / MSYS** (`sideshow`) | `$HOME/.sideshowdb/wrapper` (often under `C:/Users/…`) | `$SIDESHOWDB_HOME/cli/0.4.2/dist/sideshow.exe` |

### With `SIDESHOWDB_HOME` set

Same path shape; only the prefix changes—for example **`/var/cache/ssdb`** on Linux yields `/var/cache/ssdb/cli/0.4.2/dist/sideshow`, and **`D:\\caches\\ssdb`** on Windows yields `D:\\caches\\ssdb\\cli\\0.4.2\\dist\\sideshow.exe`.

Each version directory also keeps a **`.ready`** marker and a copy of **`SHA256SUMS`**.

### Rare defaults (missing home dir)

If **`HOME`** and **`USERPROFILE`** are both unset, the Bash wrapper uses
**`TMPDIR`** when set, otherwise **`/tmp`**, and appends **`/sideshowdb-wrapper`**
to build the cache root. If **`USERPROFILE`** is empty on Windows, wrappers use a
**`sideshowdb-wrapper`** directory under the temp folder (the usual literal is
**`%TEMP%\sideshowdb-wrapper`** in `cmd.exe`).

## Package / version managers (mise, etc.)

Tagged releases match the **`github`** backend naming convention:

```bash
mise use github:sideshowdb/sideshowdb@latest

# Pin a semver tag from GitHub Releases
mise use github:sideshowdb/sideshowdb@v0.1.0
```

## Manual download from GitHub Releases

Grab the tarball or zip that matches your OS/arch from the [**Releases** page](https://github.com/sideshowdb/sideshowdb/releases):

- Linux/macOS archives are **`.tar.gz`**.
- Windows ships as **`.zip`** when published.

Unpack, verify against **`SHA256SUMS`**, then put **`sideshow`** (or
**`sideshow.exe`**) somewhere on **`PATH`** (or invoke it by full path).

## Build from source

Use this path when hacking on Zig/WASM/site sources.

| Dependency | Version | Why |
| ---------- | ------- | --- |
| [Zig](https://ziglang.org/download/) | 0.16.0 | Builds core, CLI, and WASM targets |
| [Git](https://git-scm.com/) | Any modern clone | Implements [`GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore) |
| [Bun](https://bun.sh/) | 1.x | Docs site workspace + TS packages |

```bash
git clone https://github.com/sideshowdb/sideshowdb.git
cd sideshow
zig build              # zig-out/bin/sideshow
zig build wasm        # zig-out/wasm/sideshowdb.wasm
zig build js:install  # repo-root Bun deps
zig build site:dev    # local docs/playground via SvelteKit
```

## Related

- [Getting Started](/docs/getting-started/) — hands-on CLI walk-through after install.
