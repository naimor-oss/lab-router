#!/usr/bin/env bash
#===============================================================================
# stage-router-artifacts.sh - Mac-side staging for the lab router VM
#
# Produces two files on the ISO share (/Volumes/ISO by default, = D:\ISO\
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
CONFIG_FILE=''
SSH_PUBKEY_FILE=''
STAGE_DIR=''
ARCH='amd64'           # only amd64 implemented today; arm64 expected per dev-commons/CONTEXT.md
DEBIAN_URL=''           # derived from $ARCH after arg parse, see below
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SEED_SRC="$REPO_DIR/templates/cloud-init"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

Options:
  -c, --config FILE        YAML config (see configs/*.yaml and
                           docs/configuration.md). Supplies defaults for
                           the options below; CLI flags still override.
                           Also renders DHCP reservations + DNS delegations
                           from the YAML into the router's dnsmasq config.
                           Requires yq (brew install yq).
  -n, --hostname NAME      router hostname (default: router1)
  -i, --lan-ip IP          router LAN IP (default: 10.10.10.1)
  -p, --lan-prefix N       LAN CIDR prefix length (default: 24)
  -d, --domain NAME        DNS search domain (default: lab.test)
      --dhcp-start IP      DHCP pool start (default: derive .100 of subnet)
      --dhcp-end IP        DHCP pool end   (default: derive .200 of subnet)
  -u, --user NAME          admin username to create on the router
                           (default: current macOS user, $(id -un))
  -k, --pubkey FILE        SSH public key path (default: ~/.ssh/id_ed25519.pub)
  -s, --stage-dir DIR      staging dir (default: /Volumes/ISO)
  -a, --arch ARCH          Debian cloud-image architecture (default: $ARCH).
                           Only 'amd64' is implemented today; 'arm64' is
                           expected within ~6 months per
                           dev-commons/CONTEXT.md.
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
# the interface accepts it now so call-sites don't need to change.
case "$ARCH" in
    amd64) DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2" ;;
    arm64) die "arm64 staging not implemented yet — see dev-commons/CONTEXT.md for the timeline" ;;
    *)     die "unsupported --arch: $ARCH (allowed: amd64, arm64)" ;;
esac

# Values from YAML fill in anything CLI flags didn't set. dnsmasq-relevant
# fields (reservations, delegations) are rendered into YAML_DNSMASQ_BLOCK
# below and merged with --extra-dnsmasq content. Only single-LAN configs
# are supported for now; multi-LAN YAMLs error out cleanly.
YAML_DNSMASQ_BLOCK=''
if [[ -n "$CONFIG_FILE" ]]; then
    command -v yq >/dev/null || die "--config requires yq (brew install yq)"
    [[ -f "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE"

    lan_count=$(yq '.router.lans | length' "$CONFIG_FILE")
    [[ "$lan_count" == "1" ]] \
        || die "--config currently supports single-LAN YAML only (got $lan_count LANs)"

    yq_opt() { yq -r "$1 // \"\"" "$CONFIG_FILE"; }

    [[ -z "$HOSTNAME"   ]] && HOSTNAME=$(yq_opt '.router.hostname')
    [[ -z "$DOMAIN"     ]] && DOMAIN=$(yq_opt   '.router.domain')
    [[ -z "$USERNAME"   ]] && USERNAME=$(yq_opt '.router.user')

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
[[ -z "$STAGE_DIR"       ]] && STAGE_DIR='/Volumes/ISO'

# sanity
command -v qemu-img >/dev/null || die "qemu-img not on PATH (brew install qemu)"
command -v hdiutil  >/dev/null || die "hdiutil missing (should be built-in on macOS)"
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
    IFS='.' read -r a b c _d <<< "$LAN_IP"
    [[ -z "$DHCP_START" ]] && DHCP_START="${a}.${b}.${c}.100"
    [[ -z "$DHCP_END"   ]] && DHCP_END="${a}.${b}.${c}.200"
fi

FQDN="${HOSTNAME}.${DOMAIN}"
PUBKEY_CONTENT="$(tr -d '\n' < "$SSH_PUBKEY_FILE")"

# Derive subnet/cidr string "10.10.10.0/24"
IFS='.' read -r a b c _d <<< "$LAN_IP"
LAN_SUBNET_CIDR="${a}.${b}.${c}.0/${LAN_PREFIX}"

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

substitute() {
    # Streaming sed with all placeholders
    sed \
        -e "s|@@HOSTNAME@@|$HOSTNAME|g" \
        -e "s|@@FQDN@@|$FQDN|g" \
        -e "s|@@DOMAIN@@|$DOMAIN|g" \
        -e "s|@@LAN_IP@@|$LAN_IP|g" \
        -e "s|@@LAN_PREFIX@@|$LAN_PREFIX|g" \
        -e "s|@@LAN_SUBNET_CIDR@@|$LAN_SUBNET_CIDR|g" \
        -e "s|@@DHCP_START@@|$DHCP_START|g" \
        -e "s|@@DHCP_END@@|$DHCP_END|g" \
        -e "s|@@USERNAME@@|$USERNAME|g" \
        -e "s|@@SSH_PUBKEY@@|$PUBKEY_CONTENT|g" \
        "$1"
}

substitute "$SEED_SRC/meta-data.tpl"       > "$SEED_BUILD_DIR/meta-data"
substitute "$SEED_SRC/network-config.tpl"  > "$SEED_BUILD_DIR/network-config"

# user-data.tpl has a multi-line @@EXTRA_DNSMASQ@@ placeholder that sed can't
# easily insert multi-line content for. awk -v can't hold a multi-line value
# (newline-in-string error), so pass via environment and use ENVIRON.
EXTRA_DNSMASQ_BLOCK="$EXTRA_DNSMASQ_BLOCK" \
awk '
    # Only match the PLACEHOLDER LINE (after any leading whitespace), not
    # occurrences in comments like the file header "Placeholders: ... @@EXTRA_DNSMASQ@@".
    /^[[:space:]]*@@EXTRA_DNSMASQ@@[[:space:]]*$/ {
        if (ENVIRON["EXTRA_DNSMASQ_BLOCK"] != "") print ENVIRON["EXTRA_DNSMASQ_BLOCK"]
        next
    }
    { print }
' "$SEED_SRC/user-data.tpl" | substitute /dev/stdin > "$SEED_BUILD_DIR/user-data"

# hdiutil makehybrid refuses to overwrite; remove any prior copy first.
rm -f "$SEED_OUT"
hdiutil makehybrid -iso -joliet \
    -default-volume-name CIDATA \
    -o "$SEED_OUT" "$SEED_BUILD_DIR" >/dev/null

rm -rf "$SEED_BUILD_DIR"
echo "-> wrote $SEED_OUT ($(du -h "$SEED_OUT" | cut -f1))"

echo ""
echo "done. Build the VM with:"
echo "  ssh <host-user>@<hyper-v-host> 'pwsh -File D:\\ISO\\lab-scripts\\New-LabRouter.ps1 \\"
echo "      -VMName $HOSTNAME -SeedIso D:\\ISO\\${HOSTNAME}-seed.iso'"
