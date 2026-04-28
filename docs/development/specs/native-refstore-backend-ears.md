# Native RefStore Backend EARS

## Purpose

This document captures the required observable behavior for any zero-subprocess
native `RefStore` backend evaluated for sideshowdb.

## EARS

- When a caller reads without an explicit version, the native backend shall
  return the value reachable from the current tip of the configured ref.
- When a caller reads with an explicit version, the native backend shall return
  the value reachable from that Git commit SHA or not-found if the key is not
  present there.
- When a caller writes a value, the native backend shall create a new reachable
  Git commit and return that commit SHA as the `VersionId`.
- When a caller deletes an existing key, the native backend shall produce a new
  reachable Git commit reflecting the removal.
- If the candidate backend cannot satisfy any full-parity `RefStore`
  requirement, then sideshowdb shall record the findings in repo documentation
  before beginning the fallback exercise.
- The host-backed WASM path shall preserve current result-buffer and
  version-buffer behavior while the native backend exercise is in progress.
