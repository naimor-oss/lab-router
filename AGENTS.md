# Agent Guide

This is the vendor-neutral brief for coding agents working in `lab-router`.

**General conventions, project narrative, and shared decisions live in
the sibling repo [`../dev-commons/`](../dev-commons/).** Read at least
[`../dev-commons/CONTEXT.md`](../dev-commons/CONTEXT.md) and
[`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) before substantive
work here. This file covers what's specific to `lab-router`.

## Project Purpose

`lab-router` builds and configures a simple lab router virtual appliance. It is
focused on basic lab networking:

- WAN DHCP
- lab LAN interfaces
- NAT with nftables
- DHCP and DNS forwarding with dnsmasq
- reservations and DNS delegations
- future simple multi-subnet and VLAN configuration

It should not become a full general-purpose router distribution.

## Boundaries

- Do not add Samba-specific logic except examples.
- Do not depend on `samba-addc-appliance`.
- Avoid large frameworks unless they clearly simplify config rendering.
- Keep the router easy to rebuild and easy to reconfigure.

## Development Rules

- Keep cloud-init templates readable.
- Validate generated dnsmasq/nftables config before runtime apply scripts
  restart services.
- Keep hypervisor-specific VM creation under `hypervisors/<backend>/`.
- Keep private agent folders such as `.claude/`, `.codex/`, `.cursor/`,
  `.continue/`, and `.aider*` untracked.

## Checks

```bash
bash -n scripts/stage-router-artifacts.sh
```
