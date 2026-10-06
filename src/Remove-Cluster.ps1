<#
    Remove-Cluster.ps1
    Deletes the Multipass VMs created by the cluster agent and frees resources.
#>

param(
    [switch]$Force,          # skip confirmation
    [switch]$All             # also remove ANY node## VMs, not just the default set
)

$ErrorActionPreference = "Stop"
$controlPlaneName = "controlplane"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " CLUSTER TEARDOWN" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Verify Multipass is present
try { $null = multipass version }
catch {
    Write-Host "!!! Multipass not found. Nothing to remove." -ForegroundColor Red
    exit 1
}

# Determine which VMs to remove
$names = (multipass list --format csv | ConvertFrom-Csv) | Select-Object -ExpandProperty Name
$targets = @()
if ($names -contains $controlPlaneName) { $targets += $controlPlaneName }

if ($All) {
    $targets += ($names | Where-Object { $_ -match '^node\d+$' })
} else {
    # default managed set: node01, node02, node03
    $targets += ($names | Where-Object { $_ -in @("node01","node02","node03") })
}

$targets = $targets | Sort-Object -Unique

if ($targets.Count -eq 0) {
    Write-Host ">>> No matching cluster VMs found. Nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host ">>> The following VMs will be DELETED and PURGED:" -ForegroundColor Yellow
$targets | ForEach-Object { Write-Host "     - $_" -ForegroundColor Yellow }
Write-Host ""

# Confirmation unless -Force
if (-not $Force) {
    $answer = Read-Host " This is destructive and cannot be undone. Continue? (Y/N)"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host ">>> Cancelled. No VMs were removed." -ForegroundColor Yellow
        exit 0
    }
}

# Stop, delete, purge
foreach ($vm in $targets) {
    Write-Host ">>> Stopping $vm..." -ForegroundColor Green
    multipass stop $vm 2>$null
    Write-Host ">>> Deleting $vm..." -ForegroundColor Green
    multipass delete $vm
}

Write-Host ">>> Purging deleted VMs to reclaim disk..." -ForegroundColor Green
multipass purge

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " TEARDOWN COMPLETE — resources freed." -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan

# Show what's left
Write-Host ">>> Remaining Multipass instances:" -ForegroundColor Cyan
multipass list
