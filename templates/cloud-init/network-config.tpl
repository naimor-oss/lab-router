version: 2
ethernets:
  # WAN. With --wan-mac / --lan-mac the stager pins each interface to its
  # MAC (match + set-name) so the eth0/eth1 names nftables and dnsmasq use
  # cannot swap; otherwise the kernel's enumeration order decides.
  eth0:
    @@WAN_MATCH@@
    dhcp4: true
    dhcp6: false
  # LAN
  eth1:
    @@LAN_MATCH@@
    dhcp4: false
    dhcp6: false
    addresses:
      - @@LAN_IP@@/@@LAN_PREFIX@@
