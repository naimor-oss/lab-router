#!/usr/bin/env bash
# tests/stager-cli.sh — CLI smoke tests for scripts/stage-router-artifacts.sh
# that need no qemu-img, network or ISO share.
#
# Usage:
#   bash tests/stager-cli.sh         # exit 0 = pass

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGER="${SCRIPT_DIR}/../scripts/stage-router-artifacts.sh"

PASS=0
FAIL=0

check() {
    local name="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n' "$name"
    fi
}

echo "== --help =="
# --help must work with LAB_ISO_DIR unset (the usage text names it).
out=$(env -u LAB_ISO_DIR bash "$STAGER" --help 2>&1)
rc=$?
check "--help exits 0 (got $rc: ${out##*$'\n'})" test "$rc" -eq 0
check "--help prints the options" grep -q -- '--stage-dir DIR' <<< "$out"
check "--help names LAB_ISO_DIR literally" grep -qF '$LAB_ISO_DIR' <<< "$out"
check "--help stops at the header banner" bash -c '! grep -qE "set -euo|^=+$" <<< "$1"' _ "$out"

echo ""
echo "summary: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
