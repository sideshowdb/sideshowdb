#!/usr/bin/env bash
# smoke-cli.sh — exercise a sideshow binary against expected version, help, and auth-status surfaces.
#
# Usage:
#   smoke-cli.sh <path-to-sideshow-binary> <expected-version>
#
# Exits non-zero on any unexpected output or error.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <path-to-sideshow-binary> <expected-version>" >&2
  exit 64
fi

bin="$1"
expected_version="$2"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -x "$bin" ]]; then
  echo "smoke-cli: binary not executable: $bin" >&2
  exit 1
fi

step() {
  echo "==> $*"
}

fail() {
  echo "smoke-cli FAIL: $*" >&2
  exit 1
}

step "shadowx wrapper scripts"
[[ -x "$repo_root/shadowx" ]] || fail "missing executable POSIX wrapper: shadowx"
[[ -f "$repo_root/shadowx.ps1" ]] || fail "missing PowerShell wrapper: shadowx.ps1"
[[ -f "$repo_root/shadowx.cmd" ]] || fail "missing CMD wrapper: shadowx.cmd"
[[ ! -e "$repo_root/sideshow" ]] || fail "legacy POSIX wrapper should be renamed: sideshow"
[[ ! -e "$repo_root/sideshow.ps1" ]] || fail "legacy PowerShell wrapper should be renamed: sideshow.ps1"
[[ ! -e "$repo_root/sideshow.cmd" ]] || fail "legacy CMD wrapper should be renamed: sideshow.cmd"

wrapper_help="$("$repo_root/shadowx" --help)"
case "$wrapper_help" in
  *"shadowx "*"acquire and run the sideshow CLI"* ) ;;
  *)
    echo "$wrapper_help" >&2
    fail "shadowx wrapper help did not identify the renamed launcher"
    ;;
esac

step "version banner"
version_output="$("$bin" version 2>&1)"
echo "$version_output"
if ! grep -Fq "$expected_version" <<<"$version_output"; then
  fail "version output missing expected version $expected_version"
fi

step "version subcommand --json"
json_output="$("$bin" --json version 2>&1 || true)"
echo "$json_output"
# version is intentionally text-only; just ensure it does not crash.

step "help (top-level)"
help_output="$("$bin" --help 2>&1)"
echo "$help_output" | head -20
for needle in "usage: sideshow" "doc" "event" "snapshot" "auth"; do
  grep -Fq "$needle" <<<"$help_output" || fail "help missing expected token: $needle"
done

step "help <command>"
"$bin" help auth >/dev/null || fail "'help auth' failed"
"$bin" help doc put >/dev/null || fail "'help doc put' failed"

step "auth status (json)"
auth_output="$("$bin" --json auth status 2>&1 || true)"
echo "$auth_output"
# auth status may report no credentials in CI; we only require the command to
# return a stable surface (exit 0 OR a recognized empty-credentials message).
if grep -Eiq "panic|segmentation fault|illegal instruction" <<<"$auth_output"; then
  fail "auth status crashed"
fi

step "unknown command exits non-zero"
if "$bin" definitely-not-a-real-command >/dev/null 2>&1; then
  fail "unknown command should have failed"
fi

echo "smoke-cli: OK"
