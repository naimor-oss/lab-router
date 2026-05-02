# Lab Router Appliance

This repository builds a small, focused router VM for appliance test labs. It
is intentionally not a full network appliance. It provides the basic pieces
needed to stand up repeatable labs quickly:

- WAN DHCP on one interface.
- One or more lab LANs on internal hypervisor networks.
- NAT from lab LANs to WAN.
- DHCP and DNS forwarding through dnsmasq.
- Optional DNS reservations and zone delegations for lab services.

The current implementation uses a Debian 13 generic-cloud image, cloud-init,
nftables, and dnsmasq. Hyper-V is the first supported hypervisor target.

## Where do I start?

| If you want to … | Read |
| --- | --- |
| **Build a router VM** for a fresh lab | The "Quick Start" section below |
| Understand the **YAML config schema** the stager consumes | [`docs/configuration.md`](docs/configuration.md) |
| Look up **shared coding/docs conventions** | [`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) |
| Understand the **sibling-repo split** | [`../dev-commons/REPO-SPLIT.md`](../dev-commons/REPO-SPLIT.md) |
| See **which hypervisors are validated** | [`../dev-commons/SUPPORTED-ENVIRONMENTS.md`](../dev-commons/SUPPORTED-ENVIRONMENTS.md) |

## Repository Map

| Path | Purpose |
| --- | --- |
| `scripts/stage-router-artifacts.sh` | Mac-side artifact builder. Downloads/converts Debian cloud image and renders a NoCloud seed ISO. |
| `templates/cloud-init/` | cloud-init templates for the router VM. |
| `hypervisors/hyperv/New-LabRouter.ps1` | Creates a Hyper-V router VM from the staged VHDX and seed ISO. |
| `configs/` | Example YAML configs and dnsmasq snippets for `--config` / `--extra-dnsmasq`. |
| `docs/configuration.md` | YAML schema and planned runtime reconfigure path. |

## Quick Start

Prerequisite: `yq` on the Mac for YAML parsing (`brew install yq`). Not
needed if you stick to CLI flags or `--extra-dnsmasq` raw snippets.

From macOS:

```bash
scripts/stage-router-artifacts.sh --config configs/samba-addc.yaml
```

The YAML config supplies hostname, domain, LAN IP/prefix, DHCP pool, and
renders DHCP reservations plus DNS delegations into the router's dnsmasq
config. CLI flags still override any YAML field; `--extra-dnsmasq` still
works for raw snippets and is merged in if you pass both.

By default the admin user created on the router matches your current
macOS user (`id -un`). Override in YAML (`router.user`) or via
`--user name`.

This writes the reusable base VHDX and seed ISO to `/Volumes/ISO` by default:

- `/Volumes/ISO/debian-13-router-base.vhdx`
- `/Volumes/ISO/router1-seed.iso`

Copy the Hyper-V script to the host share if needed, then build the VM
(replace `<host-user>` and `<hyper-v-host>` with your own):

```bash
cp hypervisors/hyperv/New-LabRouter.ps1 /Volumes/ISO/lab-scripts/
ssh <host-user>@<hyper-v-host> 'pwsh -File D:\ISO\lab-scripts\New-LabRouter.ps1'
```

Verify (replace `<user>` with the admin username you passed to the stager):

```bash
ssh -J <host-user>@<hyper-v-host> <user>@10.10.10.1 \
    'cat /var/log/router-ready.marker; sudo nft list table ip nat'
```

## Current Scope

Single-LAN YAML configs are consumed today (see
[`configs/samba-addc.yaml`](configs/samba-addc.yaml)). Multi-LAN configs
like [`configs/multi-subnet-example.yaml`](configs/multi-subnet-example.yaml)
are documented but not yet rendered - the stager errors out cleanly on
multi-LAN input. VLAN trunking and runtime `apply-config.sh` are also
planned but not implemented.

See [`docs/configuration.md`](docs/configuration.md) for the full schema
and the target runtime-reconfigure workflow.
