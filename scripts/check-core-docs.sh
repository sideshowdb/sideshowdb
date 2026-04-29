#!/usr/bin/env bash
# Fail when any `pub` declaration under src/core lacks an immediately-preceding
# `///` doc-comment. Powers the EARS rule that the autodoc reference must
# document every public symbol.
set -euo pipefail

root="${1:-src/core}"

if [ ! -d "$root" ]; then
    echo "check-core-docs: directory '$root' does not exist" >&2
    exit 2
fi

failures=$(mktemp)
trap 'rm -f "$failures"' EXIT

while IFS= read -r -d '' file; do
    awk -v file="$file" -v fails="$failures" '
        BEGIN { prev_doc = 0 }
        {
            if ($0 ~ /^[[:space:]]*\/\/\//) { prev_doc = 1; next }
            if ($0 ~ /^[[:space:]]*pub[[:space:]]/ &&
                $0 !~ /^[[:space:]]*pub[[:space:]]+usingnamespace[[:space:]]/) {
                if (!prev_doc) {
                    line = $0
                    sub(/^[[:space:]]+/, "", line)
                    printf("%s:%d: undocumented pub: %s\n", file, NR, line) >> fails
                }
                prev_doc = 0
                next
            }
            prev_doc = 0
        }
    ' "$file"
done < <(find "$root" -name '*.zig' -not -path '*/ziggit_pkg/*' -print0 | LC_ALL=C sort -z)

if [ -s "$failures" ]; then
    cat "$failures" >&2
    count=$(wc -l < "$failures" | tr -d ' ')
    echo "" >&2
    echo "$count undocumented public declaration(s) under $root" >&2
    exit 1
fi

echo "ok: every public declaration under $root has a /// doc-comment."
