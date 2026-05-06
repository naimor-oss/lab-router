#!/usr/bin/env bash
# tests/unit-helpers.sh — pure-bash unit tests for scripts/lib-derive.sh.
#
# These helpers produce strings that go into either the cloud-init seed
# ISO (substitute_template) or downstream tooling that reads the
# script's stdout (derive_dhcp_pool, derive_subnet_cidr,
# arch_to_debian_url). Drift in any of them silently changes the lab
# router's behavior — pin them here, before any seed ISO gets built.
#
# Usage:
#   bash tests/unit-helpers.sh         # exit 0 = pass; non-zero on first failure
#   VERBOSE=1 bash tests/unit-helpers.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../scripts/lib-derive.sh"
[[ -f "$LIB" ]] || { echo "FAIL: $LIB not found" >&2; exit 2; }
# shellcheck disable=SC1090
source "$LIB"

PASS=0
FAIL=0
FIRST_FAIL=""

check_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        [[ "${VERBOSE:-0}" == "1" ]] && printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n' "$name"
        printf '  expected: %s\n' "$expected"
        printf '  actual:   %s\n' "$actual"
        [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="$name"
    fi
}

check_rc() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        [[ "${VERBOSE:-0}" == "1" ]] && printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n' "$name"
        printf '  expected rc: %s\n' "$expected"
        printf '  actual rc:   %s\n' "$actual"
        [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="$name"
    fi
}

#-------------------------------------------------------------------------------
# derive_dhcp_pool — picks .100/.200 of the LAN_IP's third-octet block.
#-------------------------------------------------------------------------------
echo "== derive_dhcp_pool =="
check_eq "10.10.10.1 -> 10.10.10.100/200" \
    "10.10.10.100 10.10.10.200" "$(derive_dhcp_pool 10.10.10.1)"
check_eq "10.10.20.1 -> 10.10.20.100/200" \
    "10.10.20.100 10.10.20.200" "$(derive_dhcp_pool 10.10.20.1)"
check_eq "router on .254 still picks .100/.200 (not .254-relative)" \
    "172.29.137.100 172.29.137.200" "$(derive_dhcp_pool 172.29.137.254)"
check_eq "ignores prefix-irrelevant fourth octet" \
    "10.10.10.100 10.10.10.200" "$(derive_dhcp_pool 10.10.10.99)"

#-------------------------------------------------------------------------------
# derive_subnet_cidr — assumes /24 boundary; documented as a known limitation.
#-------------------------------------------------------------------------------
echo "== derive_subnet_cidr =="
check_eq "10.10.10.1 /24 -> 10.10.10.0/24" \
    "10.10.10.0/24" "$(derive_subnet_cidr 10.10.10.1 24)"
check_eq "172.29.137.5 /24 -> 172.29.137.0/24" \
    "172.29.137.0/24" "$(derive_subnet_cidr 172.29.137.5 24)"
# Adversarial: /16 prefix exposes the /24-boundary assumption. The
# helper still returns "<a>.<b>.<c>.0/16" — wrong network address by
# convention, but acceptable today because LAN_SUBNET_CIDR is only
# emitted to operator-facing echo output, not to any template that
# downstream tooling consumes. If a future template starts using
# @@LAN_SUBNET_CIDR@@ for routing decisions, this helper needs
# prefix-aware computation AND this assertion needs to flip to
# expect "10.10.0.0/16".
check_eq "/16 prefix: known-limited (third octet not zeroed)" \
    "10.10.10.0/16" "$(derive_subnet_cidr 10.10.10.1 16)"

#-------------------------------------------------------------------------------
# arch_to_debian_url — maps arch to qcow2 URL or returns rc=2.
#-------------------------------------------------------------------------------
echo "== arch_to_debian_url =="
check_eq "amd64 -> trixie genericcloud amd64 qcow2" \
    "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2" \
    "$(arch_to_debian_url amd64)"

# arm64 returns rc=2 (not implemented today) — pin both the rc and the
# stderr message contents.
arch_to_debian_url arm64 >/dev/null 2>&1
check_rc "arm64 -> rc=2 (not implemented)" 2 $?
err_arm64=$(arch_to_debian_url arm64 2>&1 >/dev/null || true)
check_eq "arm64 stderr mentions the timeline doc" \
    "yes" \
    "$(grep -qF 'dev-commons/CONTEXT.md' <<< "$err_arm64" && echo yes || echo no)"

# Bogus arch returns rc=2 with a different message that lists the allowed values.
arch_to_debian_url ppc64 >/dev/null 2>&1
check_rc "unknown arch -> rc=2" 2 $?
err_bogus=$(arch_to_debian_url ppc64 2>&1 >/dev/null || true)
check_eq "unknown-arch stderr lists allowed values" \
    "yes" \
    "$(grep -qF 'amd64, arm64' <<< "$err_bogus" && echo yes || echo no)"

#-------------------------------------------------------------------------------
# substitute_template — placeholder-by-placeholder coverage. Driven by
# a tiny inline template fixture so the test does not depend on the
# real cloud-init templates (which would couple the helper test to
# unrelated template edits).
#-------------------------------------------------------------------------------
echo "== substitute_template =="

# Set every documented placeholder to a distinctive value.
HOSTNAME=router1
FQDN=router1.lab.test
DOMAIN=lab.test
LAN_IP=10.10.10.1
LAN_PREFIX=24
LAN_SUBNET_CIDR=10.10.10.0/24
DHCP_START=10.10.10.100
DHCP_END=10.10.10.200
USERNAME=hooman
PUBKEY_CONTENT='ssh-ed25519 AAAA...test'

fixture=$(mktemp /tmp/router-tpl-XXXX.tpl)
trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'TPL'
host: @@HOSTNAME@@
fqdn: @@FQDN@@
domain: @@DOMAIN@@
ip: @@LAN_IP@@
prefix: @@LAN_PREFIX@@
cidr: @@LAN_SUBNET_CIDR@@
pool: @@DHCP_START@@ - @@DHCP_END@@
user: @@USERNAME@@
key: @@SSH_PUBKEY@@
TPL

out=$(substitute_template "$fixture")

check_eq "@@HOSTNAME@@ -> router1" \
    "host: router1" "$(grep '^host:' <<< "$out")"
check_eq "@@FQDN@@ -> router1.lab.test" \
    "fqdn: router1.lab.test" "$(grep '^fqdn:' <<< "$out")"
check_eq "@@DOMAIN@@ -> lab.test" \
    "domain: lab.test" "$(grep '^domain:' <<< "$out")"
check_eq "@@LAN_IP@@ -> 10.10.10.1" \
    "ip: 10.10.10.1" "$(grep '^ip:' <<< "$out")"
check_eq "@@LAN_PREFIX@@ -> 24" \
    "prefix: 24" "$(grep '^prefix:' <<< "$out")"
check_eq "@@LAN_SUBNET_CIDR@@ -> 10.10.10.0/24" \
    "cidr: 10.10.10.0/24" "$(grep '^cidr:' <<< "$out")"
check_eq "@@DHCP_START@@ + @@DHCP_END@@" \
    "pool: 10.10.10.100 - 10.10.10.200" "$(grep '^pool:' <<< "$out")"
check_eq "@@USERNAME@@ -> hooman" \
    "user: hooman" "$(grep '^user:' <<< "$out")"
check_eq "@@SSH_PUBKEY@@ -> the pubkey content" \
    "key: ssh-ed25519 AAAA...test" "$(grep '^key:' <<< "$out")"

# Invariant: every placeholder used in real templates has a sed -e
# in substitute_template. If a future template adds @@FOO@@ but the
# helper isn't updated, the placeholder leaks through unsubstituted.
# This is the cheap regression catcher.
real_tpl_dir="${SCRIPT_DIR}/../templates/cloud-init"
if [[ -d "$real_tpl_dir" ]]; then
    placeholders_used=$(grep -hoE '@@[A-Z_]+@@' "$real_tpl_dir"/*.tpl 2>/dev/null \
        | grep -v '^@@EXTRA_DNSMASQ@@$' \
        | sort -u)
    leaked=""
    for p in $placeholders_used; do
        if ! grep -qF -- "$p" "$LIB"; then
            leaked="${leaked}${p} "
        fi
    done
    check_eq "every real-template placeholder has a substitute_template line" \
        "" "$leaked"
fi

# Adversarial: a placeholder value containing characters that would
# have broken the previous sed-based implementation. The current
# bash-parameter-expansion implementation has no metacharacter
# problem — values with '|', '/', '&', '\' all flow through verbatim.
#
# Specifically pin the '|' case: under BSD sed it could trigger the
# `w filename` flag and silently write files (caught 2026-05-06 when
# the test left behind a literal 'ithpipe|g' file). The current
# implementation must NOT have that side effect.
sentinel_dir=$(mktemp -d /tmp/router-test-sentinel-XXXX)
pushd "$sentinel_dir" > /dev/null
PUBKEY_CONTENT='ssh-ed25519 AAAA|withpipe'
out_pipe=$(substitute_template "$fixture")
check_eq "values containing '|' flow through verbatim (no sed delimiter break)" \
    "key: ssh-ed25519 AAAA|withpipe" \
    "$(grep '^key:' <<< "$out_pipe")"

# Hygiene check: substitute_template MUST NOT create files as a side
# effect of weird inputs. Run from a clean temp directory and assert
# no new files appear after the call.
files_after=$(ls -1A "$sentinel_dir" 2>/dev/null | wc -l | tr -d ' ')
check_eq "substitute_template leaves no files in cwd as a side effect" \
    "0" "$files_after"
popd > /dev/null
rmdir "$sentinel_dir"

# Pin the other formerly-dangerous chars too. Slash, ampersand, and
# backslash were all sed metacharacters that would have broken the
# previous implementation; they must flow through verbatim now.
USERNAME='user/with/slashes'
out_slash=$(substitute_template "$fixture")
check_eq "values containing '/' flow through verbatim" \
    "user: user/with/slashes" "$(grep '^user:' <<< "$out_slash")"

USERNAME='user&amp'
out_amp=$(substitute_template "$fixture")
check_eq "values containing '&' flow through verbatim (no sed-backreference)" \
    "user: user&amp" "$(grep '^user:' <<< "$out_amp")"

#-------------------------------------------------------------------------------
echo
echo "summary: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "first failure: $FIRST_FAIL"
    exit 1
fi
exit 0
