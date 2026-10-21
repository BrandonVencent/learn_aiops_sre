# Host preflight check for the AIOps lab.
# Usage:
#   powershell -ExecutionPolicy Bypass -File infra/vm/check-host.ps1
#
# Expected output keys:
#   RAM_GB, FREE_DISK_GB, VMNET8_IP, VMNET8_GATEWAY, VMNET8_PREFIX

#Requires -Version 5.1

$ErrorActionPreference = "Stop"

$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$driveName = (Get-Item $repoRoot).PSDrive.Name
$freeGb = [math]::Round((Get-PSDrive -Name $driveName).Free / 1GB, 1)

$vmnet = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.InterfaceAlias -like "*VMnet8*" -and
        $_.IPAddress -notlike "169.254.*"
    } |
    Select-Object -First 1

Write-Output "RAM_GB=$ramGb"
Write-Output "FREE_DISK_GB=$freeGb"

if ($null -eq $vmnet) {
    Write-Output "VMNET8_IP=NOT_FOUND"
    Write-Output "VMNET8_GATEWAY=NOT_FOUND"
    Write-Warning "VMnet8 not found. Open VMware and verify the NAT network adapter."
} else {
    $octets = $vmnet.IPAddress.Split(".")
    $gateway = "{0}.{1}.{2}.2" -f $octets[0], $octets[1], $octets[2]
    Write-Output "VMNET8_IP=$($vmnet.IPAddress)"
    Write-Output "VMNET8_GATEWAY=$gateway"
    Write-Output "VMNET8_PREFIX=$($vmnet.PrefixLength)"
}

if ($ramGb -lt 15) {
    Write-Warning "Less than 15 GB RAM detected; the 3-VM plan may not fit."
}

if ($freeGb -lt 100) {
    Write-Warning "Less than 100 GB free on drive $driveName; shrink the VM disks."
}
