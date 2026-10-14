#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Build the lab's NAT gateway / DHCP / DNS-forwarder VM from a reusable
    Debian generic-cloud VHDX, configured via cloud-init NoCloud seed ISO.

.DESCRIPTION
    The router VM is the lab's link to the outside world. It provides:
      - NAT (nftables) from an internal LAN switch to an external WAN switch
      - DHCP for the lab subnet (dnsmasq)
      - DNS forwarding to public DNS, plus any reservations and delegations
        rendered into the seed

    Prerequisites, staged into the ISO share (-IsoDir) by
    scripts/stage-router-artifacts.sh on the workstation:
      - debian-13-router-base.vhdx   - Debian 13 genericcloud, qcow2 to VHDX
      - <VMName>-seed.iso            - NoCloud seed (CIDATA label) with the
                                       cloud-init user-data/meta-data/network-config

    This script is idempotent: if the VM already exists it skips creation.

.PARAMETER VMName
    Hyper-V VM name. Default: router1.

.PARAMETER IsoDir
    The ISO share as the Hyper-V host sees it. BaseVhdxSource and SeedIso
    default to files in it. Default: D:\ISO.

.PARAMETER BaseVhdxSource
    Path to the shared read-only base VHDX. Default:
    <IsoDir>\debian-13-router-base.vhdx.

.PARAMETER SeedIso
    Path to the NoCloud seed ISO. Default: <IsoDir>\<VMName>-seed.iso.

.PARAMETER LabPath
    Root folder for per-VM files (VHDX copy, seed ISO copy, VM config).
    Default: the Hyper-V host's VirtualMachinePath (Get-VMHost).

.PARAMETER LanSwitchName
    Name of the internal Hyper-V switch this router's LAN attaches to.
    Created if missing. Default: Lab-NAT.

.PARAMETER WanSwitchName
    Name of the Hyper-V switch this router's WAN attaches to. Must already
    exist. Default: the host's only External switch; with no External
    switch, client Hyper-V's 'Default Switch' (its DHCP needs Internet
    Connection Sharing); otherwise the script stops and lists the switches.

.PARAMETER LanHostIP
    Optional static IPv4 address for the host's own vNIC on the LAN switch
    (vEthernet (<LanSwitchName>)), so the host can reach the lab directly.
    No gateway or DNS server is set on it, and it is not registered in DNS,
    so the host's default route and resolver stay as they are. Pick an
    address outside the router's DHCP pool. Default: not set (the host
    vNIC is left unconfigured; the VM is the gateway either way).

.PARAMETER LanHostPrefix
    Prefix length for LanHostIP. Default: 24.

.PARAMETER MemoryMB
    Startup memory, static. Default: 1024.

.PARAMETER VCpu
    Virtual processors. Default: 1.

.PARAMETER LanMacAddress
    Optional static MAC for the LAN adapter, e.g. for a DHCP reservation
    upstream of the lab.

.EXAMPLE
    .\New-LabRouter.ps1

.EXAMPLE
    .\New-LabRouter.ps1 -VMName router2 -IsoDir E:\Lab\ISO -WanSwitchName External -LanHostIP 10.10.20.2
#>
[CmdletBinding()]
param(
    [string]$VMName         = 'router1',
    [string]$IsoDir         = 'D:\ISO',
    [string]$BaseVhdxSource = '',
    [string]$SeedIso        = '',
    [string]$LabPath        = '',
    [string]$LanSwitchName  = 'Lab-NAT',
    [string]$WanSwitchName  = '',
    [string]$LanHostIP      = '',
    [ValidateRange(1, 32)]
    [int]   $LanHostPrefix  = 24,
    [int]   $MemoryMB       = 1024,
    [int]   $VCpu           = 1,
    [string]$LanMacAddress  = ''
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    + $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    ! $m" -ForegroundColor Yellow }

if (-not $BaseVhdxSource) { $BaseVhdxSource = Join-Path $IsoDir 'debian-13-router-base.vhdx' }
if (-not $SeedIso)        { $SeedIso        = Join-Path $IsoDir "$VMName-seed.iso" }
if (-not $LabPath)        { $LabPath        = (Get-VMHost).VirtualMachinePath }

# 1. SANITY CHECKS
Write-Step "Sanity checks"
if (-not (Test-Path $BaseVhdxSource)) {
    throw "Base VHDX not found at $BaseVhdxSource. Stage it with scripts/stage-router-artifacts.sh first."
}
if (-not (Test-Path $SeedIso)) {
    throw "Seed ISO not found at $SeedIso. Stage it with scripts/stage-router-artifacts.sh first."
}
if (-not $WanSwitchName) {
    $external = @(Get-VMSwitch -SwitchType External)
    if ($external.Count -eq 1) {
        $WanSwitchName = $external[0].Name
    } elseif ($external.Count -eq 0 -and (Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue)) {
        # Client Hyper-V's NAT switch. Its DHCP comes from Internet Connection
        # Sharing; where policy disables ICS the WAN never gets a lease.
        $WanSwitchName = 'Default Switch'
        Write-Warn "No External switch; using 'Default Switch' (needs ICS). Pass -WanSwitchName to choose."
    } else {
        throw "Pass -WanSwitchName: found $($external.Count) External switches (" +
              (($external.Name) -join ', ') + "). All switches: " + ((Get-VMSwitch).Name -join ', ')
    }
}
if (-not (Get-VMSwitch -Name $WanSwitchName -ErrorAction SilentlyContinue)) {
    throw "WAN switch '$WanSwitchName' not found. Existing switches: " +
          ((Get-VMSwitch).Name -join ', ')
}
Write-OK "Base VHDX:  $BaseVhdxSource"
Write-OK "Seed ISO:   $SeedIso"
Write-OK "WAN switch: $WanSwitchName"
Write-OK "VM files:   $LabPath"

# 2. LAN SWITCH (+ optional host vNIC address)
Write-Step "LAN switch: $LanSwitchName"
$lanSw = Get-VMSwitch -Name $LanSwitchName -ErrorAction SilentlyContinue
if ($lanSw) {
    Write-OK "Switch exists ($($lanSw.SwitchType))"
} else {
    $lanSw = New-VMSwitch -Name $LanSwitchName -SwitchType Internal
    Write-OK "Created internal switch"
}

if ($LanHostIP) {
    if ($lanSw.SwitchType -ne 'Internal') {
        throw "-LanHostIP needs an Internal switch; '$LanSwitchName' is $($lanSw.SwitchType)."
    }
    $hostIf = "vEthernet ($LanSwitchName)"
    if (Get-NetIPAddress -InterfaceAlias $hostIf -IPAddress $LanHostIP -ErrorAction SilentlyContinue) {
        Write-OK "Host vNIC already has $LanHostIP"
    } else {
        Get-NetIPAddress -InterfaceAlias $hostIf -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false
        # No -DefaultGateway: the host keeps its own default route.
        New-NetIPAddress -InterfaceAlias $hostIf -IPAddress $LanHostIP -PrefixLength $LanHostPrefix | Out-Null
        Write-OK "Host vNIC: $LanHostIP/$LanHostPrefix on $hostIf"
    }
    # Keep the lab address out of whatever DNS the host registers with.
    Set-DnsClient -InterfaceAlias $hostIf -RegisterThisConnectionsAddress $false
} else {
    # Left unconfigured: the VM is the sole gateway and the host needs no
    # address on this switch for the lab to work.
    Write-OK "Host vNIC left unconfigured (pass -LanHostIP to reach the lab from the host)"
}

# 3. SKIP IF VM ALREADY EXISTS
Write-Step "Checking for existing VM: $VMName"
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Warn "VM already exists - skipping creation. To rebuild: Remove-VM $VMName -Force"
    exit 0
}

# 4. PER-VM FOLDERS + VHDX COPY
Write-Step "Preparing per-VM storage"
$vmFolder = Join-Path $LabPath $VMName
$vhdxDest = Join-Path $vmFolder "$VMName.vhdx"
$isoDest  = Join-Path $vmFolder 'seed.iso'
New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null

Copy-Item -Path $BaseVhdxSource -Destination $vhdxDest -Force
Copy-Item -Path $SeedIso        -Destination $isoDest  -Force
Write-OK "VHDX copied to $vhdxDest ($([math]::Round((Get-Item $vhdxDest).Length / 1MB)) MB)"
Write-OK "Seed ISO copied to $isoDest"

# 5. CREATE GEN2 VM
Write-Step "Creating VM: $VMName"
$vm = New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryMB * 1MB) `
    -Generation 2 `
    -SwitchName $WanSwitchName `
    -VHDPath $vhdxDest `
    -Path $LabPath

Set-VMProcessor -VMName $VMName -Count $VCpu
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

# WAN = primary NIC (already attached via New-VM). Rename for clarity.
Rename-VMNetworkAdapter -VMName $VMName -Name 'Network Adapter' -NewName 'WAN' -ErrorAction SilentlyContinue

# LAN NIC
Add-VMNetworkAdapter -VMName $VMName -Name 'LAN' -SwitchName $LanSwitchName
if ($LanMacAddress) {
    Set-VMNetworkAdapter -VMName $VMName -Name 'LAN' -StaticMacAddress $LanMacAddress
}

# Boot order: VHDX first
$drive = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $drive

# SecureBoot OFF - Debian cloud images work with SecureBoot via the MS UEFI CA
# template, but disabling avoids surprises on older Hyper-V hosts.
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Attach cloud-init seed ISO (SCSI DVD drive)
Add-VMScsiController -VMName $VMName -ErrorAction SilentlyContinue | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $isoDest

# Hyper-V Integration Services - enable guest-services / heartbeat / time sync
Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'
Enable-VMIntegrationService -VMName $VMName -Name 'Heartbeat'
Enable-VMIntegrationService -VMName $VMName -Name 'Time Synchronization'
Enable-VMIntegrationService -VMName $VMName -Name 'Key-Value Pair Exchange'

Write-OK "VM created: Gen2, $VCpu vCPU, $MemoryMB MB, SecureBoot off"
Write-OK "NICs: WAN=$WanSwitchName  LAN=$LanSwitchName"

# 6. START + SHOW STATUS
Write-Step "Starting VM"
Start-VM -Name $VMName
Start-Sleep -Seconds 2

Write-OK "Started. Cloud-init will apply config on first boot (~2-3 min)."
Write-Host ""
Write-Host "To monitor first-boot progress:" -ForegroundColor DarkGray
Write-Host "    (Get-VMNetworkAdapter -VMName $VMName -Name LAN).IPAddresses" -ForegroundColor DarkGray
Write-Host "    # wait for IPs to appear, then:" -ForegroundColor DarkGray
Write-Host "    ssh <user>@<router-lan-ip> 'cloud-init status; cat /var/log/router-*.marker'" -ForegroundColor DarkGray
