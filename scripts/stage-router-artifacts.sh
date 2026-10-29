#!/usr/bin/env bash
#===============================================================================
# stage-router-artifacts.sh - workstation-side staging (WSL2 or macOS) for the lab router VM
#
# Produces two files on the ISO share (/mnt/d/ISO on WSL2, /Volumes/ISO on
# macOS, = D:\ISO\
# on the Hyper-V host):
#
#   debian-13-router-base.vhdx    (~1.2 GB - Debian genericcloud qcow2 converted)
#   <hostname>-seed.iso           (~1 MB - NoCloud seed with substituted config)
#
# The base VHDX is a shared read-only blob - build it once, reuse for all
# router VMs you ever make. The seed ISO is per-VM: one per hostname/IP.
#
# Templates live in templates/cloud-init/*.tpl with @@PLACEHOLDERS@@. A
# concrete build substitutes them from CLI flags + ~/.ssh/id_ed25519.pub.
#
# Usage:
#   scripts/stage-router-artifacts.sh                                # router1 10.10.10.1 lab.test
#   scripts/stage-router-artifacts.sh -n router2 -i 10.10.20.1       # second lab segment
#   scripts/stage-router-artifacts.sh --help
#
# Re-running skips the qcow2 download and VHDX conversion if the output
# already exists, so it's cheap to re-generate just the seed ISO after
# tweaking templates.
#===============================================================================
set -euo pipefail

# Resolution order for each setting (highest priority first):
#   1. CLI flag
#   2. --config YAML file
#   3. hardcoded default applied at the end
#
# Unset values are kept empty until post-parse so we can tell which source
# supplied what.
HOSTNAME=''
LAN_IP=''
LAN_PREFIX=''
DOMAIN=''
DHCP_START=''
DHCP_END=''
USERNAME=''
WAN_MAC=''
LAN_MAC=''
WAN_IP=''
WAN_GATEWAY=''
WAN_DNS=''
CONFIG_FILE=''
SSH_PUBKEY_FILE=''
STAGE_DIR=''
ARCH='amd64'           # only amd64 implemented today; arm64 expected per dev-commons/CONTEXT.md
DEBIAN_URL=''           # derived from $ARCH after arg parse, see below
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Workstation portability (WSL2 on Windows 11, or macOS): ISO share path,
# seed ISO builder, checksums. lab-kit is a sibling checkout.
LAB_KIT_DIR="${LAB_KIT_DIR:-$SCRIPT_DIR/../../lab-kit}"
# shellcheck disable=SC1091
source "$LAB_KIT_DIR/lib/lab-host.sh" 2>/dev/null \
    || { echo "error: lab-kit not found at $LAB_KIT_DIR (clone it next to this repo)" >&2; exit 1; }
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SEED_SRC="$REPO_DIR/templates/cloud-init"

# Pure helpers (substitute_template, derive_dhcp_pool, derive_subnet_cidr,
# arch_to_debian_url) — extracted into a sourceable library so
# tests/unit-helpers.sh can pin their string output.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-derive.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^#====/{/^#====/d;p;}' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

Options:
  -c, --config FILE        YAML config (see configs/*.yaml and
                           docs/configuration.md). Supplies defaults for
                           the options below; CLI flags still override.
                           Also renders DHCP reservations + DNS delegations
                           from the YAML into the router's dnsmasq config.
                           Requires yq (mikefarah yq v4: brew install yq; on WSL2 install the release binary from github.com/mikefarah/yq).
  -n, --hostname NAME      router hostname (default: router1)
  -i, --lan-ip IP          router LAN IP (default: 10.10.10.1)
  -p, --lan-prefix N       LAN CIDR prefix length (default: 24)
  -d, --domain NAME        DNS search domain (default: lab.test)
      --dhcp-start IP      DHCP pool start (default: derive .100 of subnet)
      --dhcp-end IP        DHCP pool end   (default: derive .200 of subnet)
  -u, --user NAME          admin username to create on the router
                           (default: current user, $(id -un))
  -k, --pubkey FILE        SSH public key path (default: ~/.ssh/id_ed25519.pub)
  -s, --stage-dir DIR      staging dir (default: /mnt/d/ISO on WSL2,
                           /Volumes/ISO on macOS, or \$LAB_ISO_DIR)
  -a, --arch ARCH          Debian cloud-image architecture (default: $ARCH).
                           Only 'amd64' is implemented today; 'arm64' is
                           expected within ~6 months per
                           dev-commons/CONTEXT.md.
      --wan-ip ADDR/PREFIX static WAN address (default: WAN uses DHCP). For
                           an uplink without DHCP, e.g. a host vNIC on an
                           internal switch with WinNAT (New-LabRouter.ps1
                           -CreateWanNat). Needs --wan-gateway.
      --wan-gateway IP     WAN default gateway (static WAN only)
      --wan-dns IP[,IP]    upstream resolvers dnsmasq forwards to; with a
                           static WAN also the router's own resolvers during
                           first boot (default: 1.1.1.1,8.8.8.8)
      --wan-mac MAC        pin the WAN (eth0) to this MAC address
      --lan-mac MAC        pin the LAN (eth1) to this MAC address
                           With either set, network-config matches that
                           interface by MAC instead of trusting the
                           kernel's eth0/eth1 order. Pass the same MACs to
                           New-LabRouter.ps1 (-WanMacAddress /
                           -LanMacAddress); the closing hint does.
      --extra-dnsmasq FILE append raw dnsmasq snippet (merged with YAML
                           reservations/delegations if --config is also set)
  -h, --help               show this

Examples:
  scripts/stage-router-artifacts.sh --config configs/samba-addc.yaml
  scripts/stage-router-artifacts.sh --extra-dnsmasq configs/samba-addc.dnsmasq.conf
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)      CONFIG_FILE="$2";     shift 2 ;;
        -n|--hostname)    HOSTNAME="$2";        shift 2 ;;
        -i|--lan-ip)      LAN_IP="$2";          shift 2 ;;
        -p|--lan-prefix)  LAN_PREFIX="$2";      shift 2 ;;
        -d|--domain)      DOMAIN="$2";          shift 2 ;;
        --dhcp-start)     DHCP_START="$2";      shift 2 ;;
        --dhcp-end)       DHCP_END="$2";        shift 2 ;;
        -u|--user)        USERNAME="$2";        shift 2 ;;
        --wan-ip)         WAN_IP="$2";          shift 2 ;;
        --wan-gateway)    WAN_GATEWAY="$2";     shift 2 ;;
        --wan-dns)        WAN_DNS="$2";         shift 2 ;;
        --wan-mac)        WAN_MAC="$2";         shift 2 ;;
        --lan-mac)        LAN_MAC="$2";         shift 2 ;;
        -k|--pubkey)      SSH_PUBKEY_FILE="$2"; shift 2 ;;
        -s|--stage-dir)   STAGE_DIR="$2";       shift 2 ;;
        -a|--arch)        ARCH="$2";            shift 2 ;;
        --extra-dnsmasq)  EXTRA_DNSMASQ_FILE="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown arg: $1" ;;
    esac
done

# Today only amd64 is implemented end-to-end. arm64 will land when the
# first arm64 appliance does (per dev-commons/SUPPORTED-ENVIRONMENTS.md);
# arch_to_debian_url accepts it as the interface but errors out today.
if ! DEBIAN_URL=$(arch_to_debian_url "$ARCH" 2>&1); then
    die "$DEBIAN_URL"
fi

# Values from YAML fill in anything CLI flags didn't set. dnsmasq-relevant
# fields (reservations, delegations) are rendered into YAML_DNSMASQ_BLOCK
# below and merged with --extra-dnsmasq content. Only single-LAN configs
# are supported for now; multi-LAN YAMLs error out cleanly.
YAML_DNSMASQ_BLOCK=''
if [[ -n "$CONFIG_FILE" ]]; then
    command -v yq >/dev/null || die "--config requires yq (mikefarah yq v4: brew install yq; on WSL2 install the release binary from github.com/mikefarah/yq)"
    [[ -f "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE"

    lan_count=$(yq '.router.lans | length' "$CONFIG_FILE")
    [[ "$lan_count" == "1" ]] \
        || die "--config currently supports single-LAN YAML only (got $lan_count LANs)"

    yq_opt() { yq -r "$1 // \"\"" "$CONFIG_FILE"; }

    [[ -z "$HOSTNAME"   ]] && HOSTNAME=$(yq_opt '.router.hostname')
    [[ -z "$DOMAIN"     ]] && DOMAIN=$(yq_opt   '.router.domain')
    [[ -z "$USERNAME"   ]] && USERNAME=$(yq_opt '.router.user')
    [[ -z "$WAN_MAC"    ]] && WAN_MAC=$(yq_opt  '.router.wan.mac')
    wan_mode=$(yq_opt '.router.wan.mode')
    case "${wan_mode:-dhcp}" in
        dhcp)   [[ -z "$(yq_opt '.router.wan.address')" ]] \
                    || die "$CONFIG_FILE: router.wan.address needs router.wan.mode: static" ;;
        static) [[ -z "$WAN_IP"      ]] && WAN_IP=$(yq_opt      '.router.wan.address')
                [[ -z "$WAN_GATEWAY" ]] && WAN_GATEWAY=$(yq_opt '.router.wan.gateway')
                [[ -n "$WAN_IP" ]] || die "$CONFIG_FILE: router.wan.mode: static needs router.wan.address" ;;
        *)      die "$CONFIG_FILE: router.wan.mode must be dhcp or static (got $wan_mode)" ;;
    esac
    [[ -z "$WAN_DNS" ]] && WAN_DNS=$(yq -r '.router.wan.dns // [] | join(",")' "$CONFIG_FILE")
    [[ -z "$LAN_MAC"    ]] && LAN_MAC=$(yq_opt  '.router.lans[0].mac')

    addr=$(yq_opt '.router.lans[0].address')   # "10.10.10.1/24"
    if [[ -n "$addr" ]]; then
        [[ -z "$LAN_IP"     ]] && LAN_IP="${addr%/*}"
        [[ -z "$LAN_PREFIX" ]] && LAN_PREFIX="${addr#*/}"
    fi

    range=$(yq_opt '.router.lans[0].dhcp.range')   # "10.10.10.100-10.10.10.200"
    if [[ -n "$range" ]]; then
        [[ -z "$DHCP_START" ]] && DHCP_START="${range%-*}"
        [[ -z "$DHCP_END"   ]] && DHCP_END="${range#*-}"
    fi

    # Render reservations into dhcp-host= lines.
    reservations=$(yq -r '.router.lans[0].dhcp.reservations // [] | .[] |
        "dhcp-host=" + .mac + "," + .name + "," + .ip + ",infinite"' \
        "$CONFIG_FILE")
    # Render DNS delegations into server=/zone/ip lines, one per server.
    delegations=$(yq -r '.router.lans[0].dns.delegations // [] | .[] |
        .zone as $z | .servers[] |
        "server=/" + $z + "/" + .' "$CONFIG_FILE")

    if [[ -n "$reservations" || -n "$delegations" ]]; then
        YAML_DNSMASQ_BLOCK="# rendered from $CONFIG_FILE"
        [[ -n "$reservations" ]] && YAML_DNSMASQ_BLOCK+=$'\n'"$reservations"
        [[ -n "$delegations"  ]] && YAML_DNSMASQ_BLOCK+=$'\n'"$delegations"
    fi
fi

# Hardcoded fallbacks - only apply to anything still empty after CLI + YAML.
[[ -z "$HOSTNAME"        ]] && HOSTNAME='router1'
[[ -z "$LAN_IP"          ]] && LAN_IP='10.10.10.1'
[[ -z "$LAN_PREFIX"      ]] && LAN_PREFIX='24'
[[ -z "$DOMAIN"          ]] && DOMAIN='lab.test'
[[ -z "$USERNAME"        ]] && USERNAME="$(id -un)"
[[ -z "$SSH_PUBKEY_FILE" ]] && SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"
[[ -z "$STAGE_DIR"       ]] && STAGE_DIR="$(lab_iso_dir)"
[[ -z "$WAN_DNS"         ]] && WAN_DNS='1.1.1.1,8.8.8.8'

# sanity
lab_need_tool qemu-img qemu-utils qemu
command -v curl     >/dev/null || die "curl not on PATH"
[[ -d "$STAGE_DIR" ]] || die "stage dir not mounted: $STAGE_DIR"
[[ -f "$SSH_PUBKEY_FILE" ]] || die "ssh pubkey not found: $SSH_PUBKEY_FILE"
[[ -d "$SEED_SRC" ]] || die "seed templates dir not found: $SEED_SRC"
for tpl in user-data.tpl meta-data.tpl network-config.tpl; do
    [[ -f "$SEED_SRC/$tpl" ]] || die "template missing: $SEED_SRC/$tpl"
done

# Auto-derive DHCP pool endpoints from LAN_IP if not supplied.
# E.g. 10.10.10.1 -> 10.10.10.100 / 10.10.10.200
if [[ -z "$DHCP_START" || -z "$DHCP_END" ]]; then
    read -r derived_start derived_end <<< "$(derive_dhcp_pool "$LAN_IP")"
    [[ -z "$DHCP_START" ]] && DHCP_START="$derived_start"
    [[ -z "$DHCP_END"   ]] && DHCP_END="$derived_end"
fi

# Optional MAC pinning, rendered into network-config.
if [[ -n "$WAN_MAC" ]]; then WAN_MAC=$(normalize_mac "$WAN_MAC" 2>&1) || die "--wan-mac: $WAN_MAC"; fi
if [[ -n "$LAN_MAC" ]]; then LAN_MAC=$(normalize_mac "$LAN_MAC" 2>&1) || die "--lan-mac: $LAN_MAC"; fi
[[ -z "$WAN_MAC" || "$WAN_MAC" != "$LAN_MAC" ]] || die "--wan-mac and --lan-mac are the same address"
# Optional static WAN.
if [[ -n "$WAN_IP" ]]; then
    is_ipv4_cidr "$WAN_IP" || die "--wan-ip must be ADDR/PREFIX, e.g. 192.168.250.2/24 (got $WAN_IP)"
    [[ -n "$WAN_GATEWAY" ]] || die "--wan-ip needs --wan-gateway"
    is_ipv4 "$WAN_GATEWAY" || die "--wan-gateway: not an IPv4 address: $WAN_GATEWAY"
    [[ "${WAN_IP%/*}" != "$LAN_IP" ]] || die "--wan-ip and the LAN IP are the same address"
elif [[ -n "$WAN_GATEWAY" ]]; then
    die "--wan-gateway needs --wan-ip (a DHCP WAN takes its gateway from the lease)"
fi
WAN_DNS="${WAN_DNS// /}"
IFS=',' read -ra dns_list <<< "$WAN_DNS"
(( ${#dns_list[@]} > 0 )) || die "--wan-dns: no resolvers given"
for ip in "${dns_list[@]}"; do
    is_ipv4 "$ip" || die "--wan-dns: not an IPv4 address: $ip"
done
WAN_IPV4_BLOCK=$(wan_ipv4_block "$WAN_IP" "$WAN_GATEWAY" "$WAN_DNS")
UPSTREAM_DNS_BLOCK=$(upstream_dns_block "$WAN_DNS")

WAN_MATCH_BLOCK=$(mac_match_block "$WAN_MAC" eth0)
LAN_MATCH_BLOCK=$(mac_match_block "$LAN_MAC" eth1)

FQDN="${HOSTNAME}.${DOMAIN}"
PUBKEY_CONTENT="$(tr -d '\n' < "$SSH_PUBKEY_FILE")"

# Subnet/CIDR string for operator info + future template use.
LAN_SUBNET_CIDR=$(derive_subnet_cidr "$LAN_IP" "$LAN_PREFIX")

# Merge dnsmasq content from (a) YAML-rendered reservations/delegations and
# (b) --extra-dnsmasq raw snippet. Both get the same 6-space indent so they
# nest under the write_files block.
raw_dnsmasq=''
if [[ -n "$YAML_DNSMASQ_BLOCK" ]]; then
    raw_dnsmasq="$YAML_DNSMASQ_BLOCK"
fi
if [[ -n "${EXTRA_DNSMASQ_FILE:-}" ]]; then
    [[ -f "$EXTRA_DNSMASQ_FILE" ]] || die "extra-dnsmasq file not found: $EXTRA_DNSMASQ_FILE"
    extra="$(cat "$EXTRA_DNSMASQ_FILE")"
    if [[ -n "$raw_dnsmasq" ]]; then
        raw_dnsmasq+=$'\n'"$extra"
    else
        raw_dnsmasq="$extra"
    fi
fi
EXTRA_DNSMASQ_BLOCK=''
if [[ -n "$raw_dnsmasq" ]]; then
    EXTRA_DNSMASQ_BLOCK="$(printf '%s\n' "$raw_dnsmasq" | sed 's/^/      /')"
fi

echo "=== stage-router-artifacts.sh"
echo "  hostname:     $HOSTNAME"
echo "  fqdn:         $FQDN"
echo "  lan:          $LAN_IP/$LAN_PREFIX  (subnet $LAN_SUBNET_CIDR)"
echo "  domain:       $DOMAIN"
echo "  dhcp pool:    $DHCP_START .. $DHCP_END"
echo "  wan:          ${WAN_IP:-dhcp}${WAN_GATEWAY:+ via $WAN_GATEWAY}"
echo "  upstream dns: $WAN_DNS"
echo "  wan mac:      ${WAN_MAC:-<not pinned>}"
echo "  lan mac:      ${LAN_MAC:-<not pinned>}"
echo "  admin user:   $USERNAME"
echo "  pubkey:       $SSH_PUBKEY_FILE"
echo "  stage dir:    $STAGE_DIR"
echo "  config:       ${CONFIG_FILE:-<none>}"
echo "  extra dnsmasq: ${EXTRA_DNSMASQ_FILE:-<none>}"

# 1. base VHDX (shared across all router VMs)
# Cache filename includes the arch so an amd64 cache and an arm64 cache
# can coexist when arm64 lands. The output VHDX name stays
# arch-neutral because Hyper-V picks the matching CPU type from the
# image at runtime; differentiating in the filename would force a
# corresponding rename in New-LabRouter.ps1's default path.
CACHE_QCOW2="$STAGE_DIR/debian-13-genericcloud-${ARCH}.qcow2"
OUT_VHDX="$STAGE_DIR/debian-13-router-base.vhdx"

if [[ ! -f "$OUT_VHDX" ]]; then
    if [[ ! -f "$CACHE_QCOW2" ]]; then
        echo "-> downloading Debian 13 genericcloud qcow2 (~300 MB)"
        curl -fSL -o "$CACHE_QCOW2" "$DEBIAN_URL"
    else
        echo "-> using cached qcow2 at $CACHE_QCOW2"
    fi

    # qemu-img cannot lock across SMB on macOS, so convert via local tmp, then
    # move into place.
    echo "-> converting qcow2 -> vhdx (~60s)"
    tmp_qcow=$(mktemp /tmp/router-XXXX.qcow2)
    tmp_vhdx=$(mktemp /tmp/router-XXXX.vhdx)
    trap "rm -f '$tmp_qcow' '$tmp_vhdx'" EXIT
    cp "$CACHE_QCOW2" "$tmp_qcow"
    qemu-img convert -O vhdx -o subformat=dynamic "$tmp_qcow" "$tmp_vhdx"
    cp "$tmp_vhdx" "$OUT_VHDX"
    rm -f "$tmp_qcow" "$tmp_vhdx"
    trap - EXIT
    echo "-> wrote $OUT_VHDX ($(du -h "$OUT_VHDX" | cut -f1))"
else
    echo "-> base VHDX already present at $OUT_VHDX - skipping convert"
fi

# 2. NoCloud seed ISO (per-router)
SEED_BUILD_DIR=$(mktemp -d /tmp/seed-router-XXXX)
SEED_OUT="$STAGE_DIR/${HOSTNAME}-seed.iso"

echo "-> generating seed ISO for $HOSTNAME"

# substitute_template / render_template come from lib-derive.sh — they read
# the placeholders from same-named env vars (HOSTNAME, FQDN, LAN_IP, ...,
# and the *_BLOCK values for the multi-line ones).
substitute_template "$SEED_SRC/meta-data.tpl"       > "$SEED_BUILD_DIR/meta-data"
render_template     "$SEED_SRC/network-config.tpl"  > "$SEED_BUILD_DIR/network-config"

render_template     "$SEED_SRC/user-data.tpl"       > "$SEED_BUILD_DIR/user-data"

rm -f "$SEED_OUT"
lab_make_seed_iso "$SEED_OUT" "$SEED_BUILD_DIR"

rm -rf "$SEED_BUILD_DIR"
echo "-> wrote $SEED_OUT ($(du -h "$SEED_OUT" | cut -f1))"

# The ISO share as the Hyper-V host sees it: known when WSL2 stages onto a
# local drive of the host itself, a placeholder otherwise.
if [[ "$(lab_host_os)" == wsl && "$STAGE_DIR" == /mnt/[a-z]/* ]] && command -v wslpath >/dev/null; then
    HOST_ISO_DIR="$(wslpath -w "$STAGE_DIR")"
else
    HOST_ISO_DIR='<ISO share path on the host>'
fi

echo ""
echo "done. On the Hyper-V host, from an elevated PowerShell:"
mac_args=''
[[ -n "$WAN_MAC" ]] && mac_args+=" -WanMacAddress '$WAN_MAC'"
[[ -n "$LAN_MAC" ]] && mac_args+=" -LanMacAddress '$LAN_MAC'"
echo "  & '$HOST_ISO_DIR\\lab-scripts\\New-LabRouter.ps1' -VMName $HOSTNAME -IsoDir '$HOST_ISO_DIR'$mac_args"
