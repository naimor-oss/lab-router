# Router Configuration Model

The router should stay focused: route lab networks, provide DHCP/DNS, NAT to a
WAN, and make common lab reconfiguration fast. It should not grow into a full
general-purpose network appliance.

## Inputs to the Stager

`scripts/stage-router-artifacts.sh` accepts, in resolution order:

1. **CLI flags** (highest priority): `--hostname`, `--lan-ip`, `--lan-prefix`,
   `--domain`, `--dhcp-start`, `--dhcp-end`, `--user`, `--pubkey`,
   `--stage-dir`.
2. **`--config YAML`** (requires `yq`): single-LAN configs fill in any field
   the CLI didn't set, and render DHCP reservations + DNS delegations as
   dnsmasq lines. Multi-LAN configs are rejected for now.
3. **`--extra-dnsmasq FILE`**: raw dnsmasq snippet, appended to whatever the
   YAML rendered.
4. **Hardcoded defaults** (lowest priority): router1 / 10.10.10.1 / 24 /
   lab.test / current macOS user / ~/.ssh/id_ed25519.pub / /Volumes/ISO.

## YAML Schema

The implemented shape (single-LAN only today):

```yaml
router:
  hostname: router1
  domain: lab.test
  user: labadmin           # optional; defaults to `id -un` on the Mac
  wan:
    mode: dhcp
    switch: "PCI 1G Port 1"    # read by Hyper-V helper, not stager
  lans:
    - name: lab
      switch: Lab-NAT          # read by Hyper-V helper, not stager
      interface: eth1          # informational
      address: 10.10.10.1/24
      dhcp:
        range: 10.10.10.100-10.10.10.200
        reservations:
          - name: WS2025-DC1
            mac: 00:15:5D:0A:0A:0A
            ip: 10.10.10.10
          - name: samba-dc1
            mac: 00:15:5D:0A:0A:14
            ip: 10.10.10.20
      dns:
        delegations:
          - zone: lab.test
            servers: [10.10.10.10, 10.10.10.20]
```

Fields the stager actually reads: `router.hostname`, `router.domain`,
`router.user`, `router.lans[0].address`, `router.lans[0].dhcp.range`,
`router.lans[0].dhcp.reservations`, `router.lans[0].dns.delegations`.
Other fields (`wan.switch`, `lans[*].switch`, `lans[*].interface`) are
reserved for the Hyper-V helper script and for future multi-LAN support.

## Not Yet Implemented

Multi-LAN YAMLs like
[`configs/multi-subnet-example.yaml`](../configs/multi-subnet-example.yaml)
parse but are rejected by the stager. The planned expansion is a separate
`eth<N>` interface per LAN plus matching dhcp-range / nftables rules.

VLANs should be explicit and boring:

```yaml
vlans:
  - parent: eth1
    id: 20
    name: clients
    address: 10.10.20.1/24
    dhcp:
      range: 10.10.20.100-10.10.20.200
```

Hypervisor-specific VLAN trunk/access settings belong in the lab orchestration
tool. Inside the router, a VLAN is just a Linux interface plus dnsmasq and
nftables rules.

## Reconfiguration

Two workflows are useful:

1. Build-time rendering: create a new seed ISO and build/rebuild the router VM.
2. Runtime apply: render config locally, copy it to an existing router, validate
   dnsmasq/nftables, restart services, and print effective state.

Planned command shape:

```bash
scripts/apply-config.sh configs/samba-addc.yaml router1
```

The runtime path should be safe and obvious. It should validate before
restarting services and leave the previous known-good config available for
manual rollback.
