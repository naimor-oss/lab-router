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
    # Bash 5.2+ (Debian 13, current Git for Windows) treats an unquoted
    # `&` in a ${var//pat/rep} replacement as the matched text. Quoting
    # the replacement would leak literal quotes on bash <=4.2 (macOS
    # 3.2), so switch the option off where it exists instead.
    local restore_patsub=""
    if shopt -q patsub_replacement 2>/dev/null; then
        shopt -u patsub_replacement
        restore_patsub=1
    fi
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
    [[ -n "$restore_patsub" ]] && shopt -s patsub_replacement
    printf '%s\n' "$content"
}

# Render a seed template ($1): expand the block placeholders, then
# substitute the scalar ones (substitute_template).
#
# A block placeholder is a line holding only @@NAME@@ where NAME is one
# of EXTRA_DNSMASQ, UPSTREAM_DNS, WAN_MATCH, WAN_IPV4, LAN_MATCH. It is replaced by the
# multi-line value of $NAME_BLOCK, each line prefixed with the
# placeholder's own indentation, or dropped when that value is empty.
# Mentions in comments (e.g. a file header listing placeholders) are
# left alone. awk -v can't hold a multi-line value, so the blocks are
# passed via the environment and read with ENVIRON.
render_template() {
    EXTRA_DNSMASQ_BLOCK="${EXTRA_DNSMASQ_BLOCK:-}" \
    UPSTREAM_DNS_BLOCK="${UPSTREAM_DNS_BLOCK:-}" \
    WAN_MATCH_BLOCK="${WAN_MATCH_BLOCK:-}" \
    WAN_IPV4_BLOCK="${WAN_IPV4_BLOCK:-}" \
    LAN_MATCH_BLOCK="${LAN_MATCH_BLOCK:-}" \
    awk '
        match($0, /^[[:space:]]*@@(EXTRA_DNSMASQ|UPSTREAM_DNS|WAN_MATCH|WAN_IPV4|LAN_MATCH)@@[[:space:]]*$/) {
            indent = $0; sub(/[^[:space:]].*$/, "", indent)
            name = $0; gsub(/[[:space:]@]/, "", name)
            block = ENVIRON[name "_BLOCK"]
            if (block != "") {
                n = split(block, lines, "\n")
                for (i = 1; i <= n; i++) print indent lines[i]
            }
            next
        }
        { print }
    ' "$1" | substitute_template /dev/stdin
}

# Normalise a MAC address ($1) to lowercase colon form. Accepts colons,
# dashes or no separators (Hyper-V prints 00155D0A0A01). Returns rc=2
# with a stderr message when $1 is not 12 hex digits.
normalize_mac() {
    local hex
    hex=$(printf '%s' "$1" | tr -d ':-' | tr 'A-F' 'a-f')
    if [[ ! "$hex" =~ ^[0-9a-f]{12}$ ]]; then
        echo "not a MAC address: $1" >&2
        return 2
    fi
    printf '%s:%s:%s:%s:%s:%s' "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" \
        "${hex:6:2}" "${hex:8:2}" "${hex:10:2}"
}

# Echo the network-config lines that pin an interface to a MAC and keep
# its kernel name: `match: {macaddress}` plus `set-name`. $1 = MAC
# (already normalised), $2 = name. Echoes nothing when $1 is empty.
mac_match_block() {
    [[ -n "$1" ]] || return 0
    printf 'match:\n  macaddress: "%s"\nset-name: %s' "$1" "$2"
}

# Succeed if $1 is a dotted-quad IPv4 address (each octet 0-255).
is_ipv4() {
    local a b c d extra
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d extra <<< "$1"
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

# Succeed if $1 is IPv4/prefix with a prefix of 1-32.
is_ipv4_cidr() {
    local ip="${1%/*}" prefix="${1#*/}"
    [[ "$1" == */* && "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    is_ipv4 "$ip" && (( 10#$prefix >= 1 && 10#$prefix <= 32 ))
}

# Echo the network-config IPv4 lines for the WAN (eth0). The default
# route is spelled 0.0.0.0/0: cloud-init's own parser (networkd and
# other non-netplan renderers) rejects netplan's `to: default`.
#   $1 = address/prefix ('' = DHCP), $2 = gateway, $3 = comma-separated
#   resolvers (static mode only: there is no lease to supply them, and
#   first boot needs DNS to install packages).
# Validation is the caller's job.
wan_ipv4_block() {
    if [[ -z "$1" ]]; then
        printf 'dhcp4: true'
        return 0
    fi
    printf 'dhcp4: false\naddresses:\n  - %s\nroutes:\n  - to: 0.0.0.0/0\n    via: %s\nnameservers:\n  addresses: [%s]' \
        "$1" "$2" "${3//,/, }"
}

# Echo dnsmasq server= lines, one per comma-separated resolver in $1.
upstream_dns_block() {
    local IFS=',' ip out=''
    for ip in $1; do
        out+="${out:+$'\n'}server=$ip"
    done
    printf '%s' "$out"
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
