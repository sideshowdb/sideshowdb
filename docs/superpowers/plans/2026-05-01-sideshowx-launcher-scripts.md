# Sideshowx Launcher Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename only the checked-in launcher scripts to `sideshowx` while preserving the native `sideshow` CLI binary and release artifact names.

**Architecture:** Treat `sideshowx` as a wrapper script name only. The wrappers identify themselves as `sideshowx`, but all install, archive, and execution logic continues to resolve `dist/sideshow` or `dist/sideshow.exe`. Documentation and smoke checks distinguish wrapper invocation from forwarded `sideshow` CLI arguments.

**Tech Stack:** Bash wrapper, PowerShell wrapper, Windows CMD shim, shell smoke tests, Zig build for native CLI verification.

---

### Task 1: Add Failing Wrapper Smoke Checks

**Files:**
- Modify: `scripts/smoke-cli.sh`
- Test: `scripts/smoke-cli.sh`

- [ ] **Step 1: Write the failing checks**

  In `scripts/smoke-cli.sh`, add checks near the existing binary/version checks:

  ```bash
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"

  test -x "$repo_root/sideshowx"
  test -f "$repo_root/sideshowx.ps1"
  test -f "$repo_root/sideshowx.cmd"
  test ! -e "$repo_root/sideshow"
  test ! -e "$repo_root/sideshow.ps1"
  test ! -e "$repo_root/sideshow.cmd"

  wrapper_help="$("$repo_root/sideshowx" --help)"
  case "$wrapper_help" in
    *"sideshowx "*"acquire and run the sideshow CLI"* ) ;;
    *)
      echo "sideshowx wrapper help did not identify the renamed launcher" >&2
      echo "$wrapper_help" >&2
      exit 1
      ;;
  esac
  ```

- [ ] **Step 2: Run the smoke test to verify it fails**

  Run:

  ```bash
  zig build
  bash scripts/smoke-cli.sh zig-out/bin/sideshow "$(zig-out/bin/sideshow version | awk '{print $2}')"
  ```

  Expected: FAIL because `sideshowx`, `sideshowx.ps1`, and `sideshowx.cmd` do not exist yet.

- [ ] **Step 3: Commit the failing test**

  ```bash
  git add scripts/smoke-cli.sh
  git commit -m "test(wrapper): expect sideshowx launcher scripts"
  ```

### Task 2: Rename Launcher Scripts

**Files:**
- Move: `sideshow` to `sideshowx`
- Move: `sideshow.ps1` to `sideshowx.ps1`
- Move: `sideshow.cmd` to `sideshowx.cmd`
- Modify: `sideshowx`
- Modify: `sideshowx.ps1`
- Modify: `sideshowx.cmd`

- [ ] **Step 1: Move the wrapper files**

  Run:

  ```bash
  mv -f sideshow sideshowx
  mv -f sideshow.ps1 sideshowx.ps1
  mv -f sideshow.cmd sideshowx.cmd
  chmod +x sideshowx
  ```

- [ ] **Step 2: Update the POSIX wrapper text**

  In `sideshowx`, keep release artifact and binary lookup strings as `sideshow`, but update wrapper identity text:

  ```bash
  # sideshowx — download (if needed) and run the sideshow CLI binary, similar to gradlew/mvnw.
  ```

  Ensure `usage()` starts with:

  ```bash
  user_out "sideshowx ${WRAPPER_SCRIPT_VERSION} — acquire and run the sideshow CLI (${GITHUB_REPO})"
  user_out
  user_out "Usage: ${PROG} [wrapper options] [--] [sideshow arguments…]"
  ```

- [ ] **Step 3: Update the PowerShell wrapper text**

  In `sideshowx.ps1`, keep binary and archive lookup strings as `sideshow`, but update wrapper identity text:

  ```powershell
  Acquire (if missing) and run the sideshow CLI, Gradle-style wrapper for Windows hosts.
  ```

  Ensure `Write-Usage` includes:

  ```powershell
  Write-Stdout "$($script:ProgName) $($script:WrapperScriptVersion) — acquire and run the sideshow CLI (${script:GithubRepo})"
  Write-Stdout "Usage: $($script:ProgName) [wrapper options] [--] [sideshow arguments…]"
  ```

- [ ] **Step 4: Update the CMD shim**

  In `sideshowx.cmd`, delegate to `sideshowx.ps1` and update diagnostics:

  ```bat
  @echo off
  setlocal
  set "PS_SCRIPT=%~dp0sideshowx.ps1"
  if not exist "%PS_SCRIPT%" (
    echo sideshowx.cmd: missing "%PS_SCRIPT%" 1>&2
    exit /b 1
  )
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
  exit /b %ERRORLEVEL%
  ```

- [ ] **Step 5: Run the targeted smoke test**

  Run:

  ```bash
  bash scripts/smoke-cli.sh zig-out/bin/sideshow "$(zig-out/bin/sideshow version | awk '{print $2}')"
  ```

  Expected: PASS.

- [ ] **Step 6: Commit the implementation**

  ```bash
  git add sideshowx sideshowx.ps1 sideshowx.cmd scripts/smoke-cli.sh
  git commit -m "feat(wrapper): rename launcher scripts to sideshowx"
  ```

### Task 3: Refresh Wrapper Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README wrapper references**

  Replace wrapper-specific references in `README.md` so they use `sideshowx`, `sideshowx.ps1`, and `sideshowx.cmd`, while preserving native CLI examples that intentionally invoke `sideshow`.

  The wrapper example block should contain:

  ```markdown
  chmod +x ./sideshowx
  SIDESHOWDB_HOME=/srv/cache/ssdb ./sideshowx -V latest --install-only -v
  ./sideshowx doc version           # forwarded to the cached/in-downloaded CLI
  ```

  The OS table should identify the wrapper scripts as `sideshowx` and
  `sideshowx.ps1`/`.cmd`, while the pinned binary paths continue to end in
  `dist/sideshow` and `dist\sideshow.exe`.

- [ ] **Step 2: Run a docs-focused grep**

  Run:

  ```bash
  rg -n "chmod \\+x ./shadowx|shadowx\\.ps1|Wrapper scripts \\(\`shadowx\`\\\)" README.md
  ```

  Expected: no output.

- [ ] **Step 3: Run smoke test again**

  Run:

  ```bash
  bash scripts/smoke-cli.sh zig-out/bin/sideshow "$(zig-out/bin/sideshow version | awk '{print $2}')"
  ```

  Expected: PASS.

- [ ] **Step 4: Commit documentation**

  ```bash
  git add README.md
  git commit -m "docs(wrapper): document sideshowx launcher scripts"
  ```

### Task 4: Verify and Close

**Files:**
- No new files.

- [ ] **Step 1: Run native build and tests**

  Run:

  ```bash
  zig build test
  ```

  Expected: PASS.

- [ ] **Step 2: Run targeted wrapper smoke**

  Run:

  ```bash
  bash scripts/smoke-cli.sh zig-out/bin/sideshow "$(zig-out/bin/sideshow version | awk '{print $2}')"
  ```

  Expected: PASS.

- [ ] **Step 3: Confirm native CLI usage remains sideshow**

  Run:

  ```bash
  zig-out/bin/sideshow --help | head -n 1
  ```

  Expected output contains:

  ```text
  usage: sideshow
  ```

- [ ] **Step 4: Close the bead**

  Run:

  ```bash
  bd close sideshowdb-csk --reason "Renamed launcher scripts to sideshowx while preserving the native sideshow CLI name." --json
  ```

- [ ] **Step 5: Commit bead export if changed**

  Run:

  ```bash
  bd export -o .beads/issues.jsonl
  git add .beads/issues.jsonl
  git commit -m "chore(beads): close sideshowx launcher rename"
  ```
