# Router Configuration Model

The router should stay focused: route lab networks, provide DHCP/DNS, NAT to a
WAN, and make common lab reconfiguration fast. It should not grow into a full
general-purpose network appliance.

## Inputs to the Stager

`scripts/stage-router-artifacts.sh` accepts, in resolution order:

1. **CLI flags** (highest priority): `--hostname`, `--lan-ip`, `--lan-prefix`,
   `--domain`, `--dhcp-start`, `--dhcp-end`, `--user`, `--pubkey`,
   `--stage-dir`, `--wan-ip`, `--wan-gateway`, `--wan-dns`, `--wan-mac`,
   `--lan-mac`.
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
    mode: dhcp                 # or static (needs address + gateway)
    # address: 192.168.250.2/24   # static only
    # gateway: 192.168.250.1      # static only
    dns: [1.1.1.1, 8.8.8.8]    # optional; upstream resolvers (the default)
    mac: 00:15:5D:0A:0A:01     # optional; pins eth0 to this MAC
    switch: External    # read by Hyper-V helper, not stager
  lans:
    - name: lab
      switch: Lab-NAT          # read by Hyper-V helper, not stager
      interface: eth1          # informational
      mac: 00:15:5D:0A:0A:02   # optional; pins eth1 to this MAC
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
`router.user`, `router.wan.mode`, `router.wan.address`,
`router.wan.gateway`, `router.wan.dns`, `router.wan.mac`, `router.lans[0].mac`,
`router.lans[0].address`, `router.lans[0].dhcp.range`,
`router.lans[0].dhcp.reservations`, `router.lans[0].dns.delegations`.
Other fields (`wan.switch`, `lans[*].switch`, `lans[*].interface`) are
reserved for the Hyper-V helper script and for future multi-LAN support.

### Static WAN

By default the WAN takes its address, gateway and resolvers from DHCP.
`wan.mode: static` (or `--wan-ip` / `--wan-gateway`) sets them instead. This
is for an uplink without DHCP. The usual case is a Windows 11 host where the
Hyper-V Default Switch hands out no leases, because its DHCP comes from
Internet Connection Sharing and policy disables ICS. There,
`New-LabRouter.ps1 -CreateWanNat` builds a private uplink: an Internal
switch (`Lab-WAN`), a host vNIC on it at `-WanNatGateway`
(default `192.168.250.1/24`), and a WinNAT for that subnet. Stage to match:

```bash
scripts/stage-router-artifacts.sh --wan-ip 192.168.250.2/24 --wan-gateway 192.168.250.1
```

`wan.dns` / `--wan-dns` are the resolvers dnsmasq forwards to, in either
mode (default `1.1.1.1,8.8.8.8`). With a static WAN they are also the
router's own resolvers during first boot, when it installs its packages.
Where outbound DNS to the internet is blocked, point them at a resolver
the host can reach.

### Interface pinning

Without MACs, the router trusts the kernel's order: the first adapter is
`eth0` (WAN), the second `eth1` (LAN), and nftables and dnsmasq refer to
those names. With `wan.mac` / `lans[0].mac` (or `--wan-mac` / `--lan-mac`),
network-config matches each interface by MAC and renames it to
`eth0` / `eth1`, so the order cannot swap them. Give the VM the same MACs
(`New-LabRouter.ps1 -WanMacAddress / -LanMacAddress`; the stager's closing
hint prints them). An interface whose MAC no adapter has stays
unconfigured.

Independently, `New-LabRouter.ps1` turns on DhcpGuard and RouterGuard for
the WAN adapter, so the switch drops any DHCP offer or router
advertisement the VM sends upstream.

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
