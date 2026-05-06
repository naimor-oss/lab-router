# scripts/lib-derive.sh — pure-string-producing helpers for
# stage-router-artifacts.sh. Sourced (not executed); contains no
# top-level statements that mutate state. Tested directly by
# tests/unit-helpers.sh.
#
# The companion contract: every function here MUST be a pure
# transform — args in, string out via stdout, no globals mutated,
# no I/O beyond reading the args. If you find yourself wanting to
# `mkdir` or `curl` from one of these, it doesn't belong in this
# file.

# Echo the auto-derived DHCP pool start and end for a given LAN IP,
# as two space-separated values. Picks the .100/.200 hosts of the
# third-octet block (e.g. 10.10.10.1 -> "10.10.10.100 10.10.10.200").
#
# This is the historical default behavior — operators who want a
# different pool pass --dhcp-start / --dhcp-end explicitly. The
# helper does NOT consider LAN_PREFIX: for non-/24 networks, the
# operator is expected to override. The validation that catches
# this lives in the main script's arg parser, not here.
derive_dhcp_pool() {
    local lan_ip="$1"
    local a b c _d
    IFS='.' read -r a b c _d <<< "$lan_ip"
    printf '%s.%s.%s.100 %s.%s.%s.200' "$a" "$b" "$c" "$a" "$b" "$c"
}

# Echo the network/CIDR string for a given LAN IP and prefix. WARNING:
# the implementation assumes a /24 boundary — it zeros only the fourth
# octet. For /16 (or any prefix < 24), the result will name a host on
# the wrong network address (e.g. 10.10.10.1/16 -> "10.10.10.0/16",
# but the actual network is 10.10.0.0/16). This is acceptable today
# because the value is currently only printed for operator info; if a
# downstream template ever consumes @@LAN_SUBNET_CIDR@@, this needs
# prefix-aware computation.
derive_subnet_cidr() {
    local lan_ip="$1" prefix="$2"
    local a b c _d
    IFS='.' read -r a b c _d <<< "$lan_ip"
    printf '%s.%s.%s.0/%s' "$a" "$b" "$c" "$prefix"
}

# Substitute the seed-template placeholders in $1 (a file path) with
# the values of the same-named environment variables. Reads file,
# echoes the substituted result. The set of placeholders is the
# script's contract with the cloud-init templates — adding a new
# template variable means adding a line here AND a corresponding
# uppercase env var in the caller.
#
# Multi-line placeholders (e.g. EXTRA_DNSMASQ_BLOCK) are NOT handled
# here — the main script uses awk for those. This helper is for
# scalar single-line substitutions only.
#
# Implementation note: uses bash parameter expansion ${var//pat/repl}
# rather than sed. The previous sed-based version used `|` as the
# substitution delimiter; an input value containing `|` would break
# sed's parsing AND in BSD sed could trigger the `w filename` flag,
# silently writing files. tests/unit-helpers.sh caught this on
# 2026-05-06 (it created a literal file 'ithpipe|g' as a side effect
# of running). Bash parameter expansion has no metacharacter problem.
substitute_template() {
    local file="$1"
    local content
    # Read whole file. printf '%s' avoids a trailing newline being
    # added/dropped by command substitution; the explicit final
    # newline keeps the caller's contract (sed printed the file
    # contents, including a trailing newline) intact.
    content=$(<"$file")
    content="${content//@@HOSTNAME@@/${HOSTNAME:-}}"
    content="${content//@@FQDN@@/${FQDN:-}}"
    content="${content//@@DOMAIN@@/${DOMAIN:-}}"
    content="${content//@@LAN_IP@@/${LAN_IP:-}}"
    content="${content//@@LAN_PREFIX@@/${LAN_PREFIX:-}}"
    content="${content//@@LAN_SUBNET_CIDR@@/${LAN_SUBNET_CIDR:-}}"
    content="${content//@@DHCP_START@@/${DHCP_START:-}}"
    content="${content//@@DHCP_END@@/${DHCP_END:-}}"
    content="${content//@@USERNAME@@/${USERNAME:-}}"
    content="${content//@@SSH_PUBKEY@@/${PUBKEY_CONTENT:-}}"
    printf '%s\n' "$content"
}

# Resolve --arch to the Debian cloud-image qcow2 URL. Echoes the URL
# on success; returns rc=2 with a stderr message on unsupported arch.
arch_to_debian_url() {
    case "$1" in
        amd64) echo "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2" ;;
        arm64) echo "arm64 staging not implemented yet — see dev-commons/CONTEXT.md for the timeline" >&2; return 2 ;;
        *)     echo "unsupported --arch: $1 (allowed: amd64, arm64)" >&2; return 2 ;;
    esac
}
