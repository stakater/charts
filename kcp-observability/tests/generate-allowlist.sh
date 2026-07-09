#!/usr/bin/env bash
#
# generate-allowlist.sh — regenerate tests/metrics-allowlist.captured.txt from the
# committed fixtures. The allowlist is the set of metric FAMILY names that provably
# exist on the pinned kcp build (captured from us-2 — see tests/fixtures/README.md).
#
# Usage: ./tests/generate-allowlist.sh [-o outfile]
set -euo pipefail
T="$(cd "$(dirname "$0")" && pwd)"
OUT="${T}/metrics-allowlist.captured.txt"
while getopts "o:" opt; do case $opt in o) OUT="$OPTARG";; esac; done

{
  echo "# metrics-allowlist.captured.txt — metric families PROVEN to exist, extracted from"
  echo "# tests/fixtures/*-metrics.txt (real /metrics scrapes; provenance in fixtures/README.md)."
  echo "# Regenerate with ./tests/generate-allowlist.sh — validate.sh fails if out of sync."
  # From every fixture: take series lines (skip comments), strip labels/values -> family name.
  # _bucket/_sum/_count suffixes are kept as-is: the gate matches exact names, and rules
  # reference the _bucket series explicitly.
  cat "${T}/fixtures/"*-metrics.txt \
    | grep -vE '^#|^$' \
    | sed -E 's/\{.*//; s/ .*//' \
    | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*$' \
    | sort -u
} > "$OUT"
echo "wrote $(grep -cvE '^#|^$' "$OUT") metric families to $OUT"
