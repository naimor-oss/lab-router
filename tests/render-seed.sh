#!/usr/bin/env bash
# tests/render-seed.sh — render the cloud-init seed templates with sample
# values (no qemu-img, network or ISO share), check they parse as YAML,
# and exercise the user-data ready gate against a stub systemctl.
#
# YAML checks need mikefarah yq v4 (as the stager does) or python3 with
# PyYAML; without either they are skipped, not failed. Other tools named
# yq (e.g. the jq wrapper Debian/Ubuntu package as yq) are not used.
#
# Usage:
#   bash tests/render-seed.sh         # exit 0 = pass

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${SCRIPT_DIR}/../templates/cloud-init"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../scripts/lib-derive.sh"

PASS=0
FAIL=0
SKIP=0

check() {
    local name="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n' "$name"
    fi
}

# yaml_get FILE EXPR: print a scalar from FILE. EXPR is a yq path such as
# '.runcmd[-1]'; the python fallback understands the same simple paths.
have_yq=0
yq --version 2>/dev/null | grep -q mikefarah && have_yq=1
yaml_get() {
    if (( have_yq )); then
        yq -r "$2" "$1"
    else
        python3 - "$1" "$2" <<'EOF'
import re, sys, yaml
node = yaml.safe_load(open(sys.argv[1]))
for key, idx in re.findall(r'\.([A-Za-z_][\w-]*)|\[(-?\d+)\]', sys.argv[2]):
    node = node[key] if key else node[int(idx)]
if isinstance(node, bool):
    node = str(node).lower()   # match yq: true/false
print(node if not isinstance(node, (dict, list)) else yaml.safe_dump(node), end='')
EOF
    fi
}
have_yaml=0
if (( have_yq )) || python3 -c 'import yaml' 2>/dev/null; then
    have_yaml=1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/render-seed.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export HOSTNAME=router9 DOMAIN=lab.example LAN_IP=10.9.9.1 LAN_PREFIX=24
export FQDN="$HOSTNAME.$DOMAIN" DHCP_START=10.9.9.100 DHCP_END=10.9.9.200
export USERNAME=labadmin PUBKEY_CONTENT='ssh-ed25519 AAAATEST test@example'
export LAN_SUBNET_CIDR=10.9.9.0/24
export EXTRA_DNSMASQ_BLOCK='      server=/ad.lab.example/10.9.9.10'
WAN_IPV4_BLOCK=$(wan_ipv4_block '' '' 1.1.1.1,8.8.8.8)
UPSTREAM_DNS_BLOCK=$(upstream_dns_block 1.1.1.1,8.8.8.8)
export WAN_IPV4_BLOCK UPSTREAM_DNS_BLOCK

echo "== render =="
substitute_template "$TPL/meta-data.tpl"      > "$WORK/meta-data"
render_template     "$TPL/network-config.tpl" > "$WORK/network-config"
render_template    "$TPL/user-data.tpl"      > "$WORK/user-data"
check "no placeholder left" \
    bash -c '! grep -h "@@[A-Z_]*@@" "$1"/meta-data "$1"/network-config "$1"/user-data | grep -v "^#"' _ "$WORK"
check "extra dnsmasq block inserted" grep -q '^      server=/ad.lab.example/10.9.9.10$' "$WORK/user-data"
check "upstream resolvers inserted" \
    test "$(grep -c '^      server=[0-9]' "$WORK/user-data")" -eq 2

if (( have_yaml == 0 )); then
    echo "  skip YAML checks (no yq or python3 PyYAML)"
    SKIP=$((SKIP + 1))
else
    echo "== YAML =="
    check "user-data hostname"   test "$(yaml_get "$WORK/user-data" .hostname)" = router9
    check "meta-data hostname"   test "$(yaml_get "$WORK/meta-data" .local-hostname)" = router9
    check "network-config LAN"   test "$(yaml_get "$WORK/network-config" '.ethernets.eth1.addresses[0]')" = 10.9.9.1/24
    check "network-config DHCP WAN" test "$(yaml_get "$WORK/network-config" .ethernets.eth0.dhcp4)" = true

    WAN_IPV4_BLOCK=$(wan_ipv4_block 192.168.250.2/24 192.168.250.1 192.0.2.53,192.0.2.54) \
        render_template "$TPL/network-config.tpl" > "$WORK/network-config.static"
    ns="$WORK/network-config.static"
    check "static WAN dhcp4 off"  test "$(yaml_get "$ns" .ethernets.eth0.dhcp4)" = false
    check "static WAN address"    test "$(yaml_get "$ns" '.ethernets.eth0.addresses[0]')" = 192.168.250.2/24
    check "static WAN gateway"    test "$(yaml_get "$ns" '.ethernets.eth0.routes[0].via')" = 192.168.250.1
    check "static WAN default"    test "$(yaml_get "$ns" '.ethernets.eth0.routes[0].to')" = 0.0.0.0/0
    check "static WAN resolver 2" test "$(yaml_get "$ns" '.ethernets.eth0.nameservers.addresses[1]')" = 192.0.2.54
    check "static WAN LAN intact" test "$(yaml_get "$ns" '.ethernets.eth1.addresses[0]')" = 10.9.9.1/24

    check "network-config unpinned: no match" \
        bash -c '! grep -q "match:\|set-name:" "$1"' _ "$WORK/network-config"

    WAN_MATCH_BLOCK=$(mac_match_block 00:15:5d:0a:0a:01 eth0) \
    LAN_MATCH_BLOCK=$(mac_match_block 00:15:5d:0a:0a:02 eth1) \
        render_template "$TPL/network-config.tpl" > "$WORK/network-config.pinned"
    nc="$WORK/network-config.pinned"
    check "pinned WAN mac"      test "$(yaml_get "$nc" .ethernets.eth0.match.macaddress)" = 00:15:5d:0a:0a:01
    check "pinned WAN set-name" test "$(yaml_get "$nc" .ethernets.eth0.set-name)" = eth0
    check "pinned WAN dhcp4"    test "$(yaml_get "$nc" .ethernets.eth0.dhcp4)" = true
    check "pinned LAN mac"      test "$(yaml_get "$nc" .ethernets.eth1.match.macaddress)" = 00:15:5d:0a:0a:02
    check "pinned LAN set-name" test "$(yaml_get "$nc" .ethernets.eth1.set-name)" = eth1
    check "pinned LAN address"  test "$(yaml_get "$nc" '.ethernets.eth1.addresses[0]')" = 10.9.9.1/24

    echo "== ready gate =="
    # The last runcmd entry is the gate. Point its absolute paths into
    # $WORK and give it a systemctl that reports $ACTIVE_UNITS as active.
    yaml_get "$WORK/user-data" '.runcmd[-1]' \
        | sed -e "s|/var/log/|$WORK/log/|g" -e "s|/etc/resolv.conf|$WORK/resolv.conf|g" \
        > "$WORK/gate.sh"
    mkdir -p "$WORK/bin" "$WORK/log"
    cat > "$WORK/bin/systemctl" <<'EOF'
#!/bin/sh
# stub: systemctl is-active --quiet UNIT
case " $ACTIVE_UNITS " in *" $3 "*) exit 0 ;; *) exit 3 ;; esac
EOF
    chmod +x "$WORK/bin/systemctl"

    run_gate() {
        rm -f "$WORK"/log/*
        echo 'nameserver 192.0.2.53' > "$WORK/resolv.conf"
        ACTIVE_UNITS="$1" PATH="$WORK/bin:$PATH" sh "$WORK/gate.sh"
    }

    run_gate 'nftables dnsmasq'; rc=$?
    check "both active: exit 0"              test "$rc" -eq 0
    check "both active: ready marker"        test -f "$WORK/log/router-ready.marker"
    check "both active: no failed marker"    test ! -e "$WORK/log/router-failed.marker"
    check "both active: resolver is dnsmasq" grep -qx 'nameserver 127.0.0.1' "$WORK/resolv.conf"
    check "both active: search domain"       grep -qx 'search lab.example' "$WORK/resolv.conf"

    run_gate 'nftables'; rc=$?
    check "dnsmasq down: exit non-zero"      test "$rc" -ne 0
    check "dnsmasq down: no ready marker"    test ! -e "$WORK/log/router-ready.marker"
    check "dnsmasq down: failed names it"    grep -q 'inactive: dnsmasq$' "$WORK/log/router-failed.marker"
    check "dnsmasq down: resolver untouched" grep -qx 'nameserver 192.0.2.53' "$WORK/resolv.conf"

    run_gate ''; rc=$?
    check "both down: failed names both"     grep -q 'inactive: nftables dnsmasq$' "$WORK/log/router-failed.marker"
fi

echo ""
echo "summary: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
