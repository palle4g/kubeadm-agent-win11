<#
    BkupClusterFiles.ps1
    Backs up the home directory of each cluster VM to a local Windows folder.
#>
param(
    [string]$Dest = "C:\k8s-backups",
    [string[]]$Vms = @("controlplane","node01","node02"),
    [switch]$ExcludeSensitive   # skip .kube, .cache
)

$ErrorActionPreference = "Stop"
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$root  = Join-Path $Dest $stamp
Write-Host ">>> Backing up to $root" -ForegroundColor Cyan

foreach ($vm in $Vms) {
    Write-Host ">>> Backing up $vm..." -ForegroundColor Green
    $vmDir = Join-Path $root $vm
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    # Build tar command, optionally excluding sensitive/bulky dirs
    if ($ExcludeSensitive) {
        $tarCmd = "cd ~ && tar czf /tmp/home-backup.tar.gz --exclude='.kube' --exclude='.cache' . 2>/dev/null; ls -la /tmp/home-backup.tar.gz"
    } else {
        $tarCmd = "cd ~ && tar czf /tmp/home-backup.tar.gz . 2>/dev/null; ls -la /tmp/home-backup.tar.gz"
    }

    try {
        multipass exec $vm -- bash -c "$tarCmd"
        multipass transfer "${vm}:/tmp/home-backup.tar.gz" "$vmDir\home-backup.tar.gz"
        tar -xzf "$vmDir\home-backup.tar.gz" -C "$vmDir"
        multipass exec $vm -- bash -c "rm -f /tmp/home-backup.tar.gz"
        Write-Host "    [OK] $vm backed up to $vmDir" -ForegroundColor Green
    } catch {
        Write-Host "    [FAIL] Could not back up $vm : $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " BACKUP COMPLETE -> $root" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " NOTE: backups may contain kubeconfig/credentials." -ForegroundColor Yellow
Write-Host " Keep this folder private and do NOT commit it to Git." -ForegroundColor Yellow
