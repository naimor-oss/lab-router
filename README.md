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

> **Workstation (2026-10):** the supported workstation is Windows 11 with
> WSL2 and Hyper-V. Set it up with
> [`../dev-commons/WSL2-LAB-SETUP.md`](../dev-commons/WSL2-LAB-SETUP.md);
> the lab scripts pick the ISO share path, seed-ISO builder and checksum
> tool through `lab-kit/lib/lab-host.sh` (`/mnt/d/ISO` on WSL2). The
> macOS instructions below still describe the legacy Mac workflow.

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

`New-LabRouter.ps1` reads the VHDX and `<VMName>-seed.iso` from `-IsoDir`
(default `D:\ISO`), attaches the WAN to the host's only External switch
(pass `-WanSwitchName` when there are several), and keeps VM files under
Hyper-V's default VM path (`-LabPath` to change it). Add
`-LanHostIP 10.10.10.2` to give the host itself an address on the lab LAN;
it gets no gateway or DNS server, so the host's own networking is
unchanged.

### On the Hyper-V host itself (WSL2)

When WSL2 runs on the Hyper-V host there is no ssh hop: the ISO share is a
local drive (`/mnt/d/ISO` is `D:\ISO`). Stage from WSL2 and copy the script
next to the artifacts:

```bash
scripts/stage-router-artifacts.sh --config configs/samba-addc.yaml
mkdir -p /mnt/d/ISO/lab-scripts
cp hypervisors/hyperv/New-LabRouter.ps1 /mnt/d/ISO/lab-scripts/
```

`New-LabRouter.ps1` needs an elevated session (`#Requires
-RunAsAdministrator`). Windows programs started from WSL2 run with the
WSL2 session's unelevated token, so `powershell.exe -File ...` from the
WSL2 shell stops at that check. Either:

- open PowerShell as administrator and run the line the stager printed, or
- start it from WSL2 through a UAC prompt:

  ```bash
  powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','D:\ISO\lab-scripts\New-LabRouter.ps1','-VMName','router1','-IsoDir','D:\ISO'"
  ```

  The elevated script runs in a new window, and its output does not come
  back to the WSL2 terminal. `-NoExit` keeps that window open so you can
  read the result. For a log you can read from WSL2, call the script from
  a small wrapper that uses `Start-Transcript -Path D:\ISO\logs\...` and
  run the wrapper the same way.

`-ExecutionPolicy Bypass` applies to that one process only. It is needed
where the machine policy blocks unsigned local scripts (Windows PowerShell
defaults to `Restricted` on client editions).

Without an ssh hop, verify against the router's WAN address (nftables
allows ssh there), which an elevated
`(Get-VMNetworkAdapter -VMName router1 -Name WAN).IPAddresses` shows.
Alternatively, pass `-LanHostIP` so the host can reach the router's LAN
address directly.

Verify (replace `<user>` with the admin username you passed to the stager):

```bash
ssh -J <host-user>@<hyper-v-host> <user>@10.10.10.1 \
    'cloud-init status; cat /var/log/router-*.marker; sudo nft list table ip nat'
```

`router-ready.marker` appears only when nftables and dnsmasq are both
running. If first boot could not install them (typically no WAN DHCP
lease), cloud-init writes `router-failed.marker` naming the inactive
units, leaves the image's resolver in place, and `cloud-init status`
reports an error.

## Current Scope

Single-LAN YAML configs are consumed today (see
[`configs/samba-addc.yaml`](configs/samba-addc.yaml)). Multi-LAN configs
like [`configs/multi-subnet-example.yaml`](configs/multi-subnet-example.yaml)
are documented but not yet rendered - the stager errors out cleanly on
multi-LAN input. VLAN trunking and runtime `apply-config.sh` are also
planned but not implemented.

See [`docs/configuration.md`](docs/configuration.md) for the full schema
and the target runtime-reconfigure workflow.
