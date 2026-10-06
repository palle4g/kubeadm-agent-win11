<#
    Start-Cluster.ps1
    Portable kubeadm cluster agent for Multipass on Windows.

    Features:
      - Prerequisite checks (Multipass, VMs)
      - Optional auto-creation of missing VMs (-CreateMissingVMs)
      - Automatic provisioning ONLY when needed (containerd, kubeadm, scripts)
      - Variable number of worker nodes
      - Automatic control-plane recovery (handles IP drift)
      - Automatic worker recovery + join (with retries)
      - On-screen failure notifications
      - Transcript logging

    Usage examples:
      .\Start-Cluster.ps1
      .\Start-Cluster.ps1 -Workers node01,node02,node03
      .\Start-Cluster.ps1 -CreateMissingVMs -WorkerCount 3
      .\Start-Cluster.ps1 -CreateMissingVMs -WorkerCount 2 -Cpus 4 -Memory 4G -Disk 40G
#>

param(
    [string[]]$Workers = @(),
    [switch]$CreateMissingVMs,
    [int]$WorkerCount = 2,
    [string]$Cpus = "2",
    [string]$Memory = "2G",
    [string]$Disk = "20G",
    [string]$K8sMinor = "v1.31",          # Kubernetes minor version for package repo
    [string]$CalicoVersion = "v3.28.2",
    [string]$PodCidr = "192.168.0.0/16",
    [switch]$ForceReset,          # allow rebuilding a healthy cluster unattended
    [switch]$NonInteractive,
    [switch]$DryRun          # preview actions without making changes
)

if ($WorkerCount -lt 1) { $WorkerCount = 1 }
if ($WorkerCount -gt 3) {
    Write-Host "!!! Maximum of 3 worker nodes allowed. Capping to 3." -ForegroundColor Yellow
    $WorkerCount = 3
}
if ($Workers.Count -gt 3) {
    Write-Host "!!! More than 3 workers specified. Using the first 3." -ForegroundColor Yellow
    $Workers = $Workers[0..2]
}

$ErrorActionPreference = "Stop"
$controlPlaneName = "controlplane"

# Track failures so we can summarize at the end instead of dying silently.
$script:Failures = @()

function Write-DryRun([string]$msg) {
    Write-Host "    [DRY-RUN] Would: $msg" -ForegroundColor Magenta
}

function Add-Failure([string]$msg) {
    $script:Failures += $msg
    Write-Host "!!! FAILURE: $msg" -ForegroundColor Red
}

# Ensure log directory exists
$logDir = "C:\k8s-agent\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force| Out-Null }
Start-Transcript -Path "$logDir\cluster-$(Get-Date -Format yyyyMMdd-HHmmss).log" | Out-Null

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " KUBEADM CLUSTER AGENT" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if ($DryRun) {
    Write-Host ">>> DRY-RUN MODE: no changes will be made." -ForegroundColor Magenta
}


# ------------------------------------------------------------------
# Prerequisite checks
# ------------------------------------------------------------------
function Test-Prerequisites {
    Write-Host ">>> Running prerequisite checks..." -ForegroundColor Cyan
    $problems = @()

    try {
        $null = multipass version
        Write-Host "    [OK] Multipass is installed." -ForegroundColor Green
    } catch {
        Write-Host "    [FAIL] Multipass is not installed or not on PATH." -ForegroundColor Red
        Write-Host "           Action: Install from https://multipass.run/ then reboot." -ForegroundColor Yellow
        $problems += "Multipass missing"
        return $problems
    }

    $existingNames = (multipass list --format csv | ConvertFrom-Csv) |
        Select-Object -ExpandProperty Name

    if ($existingNames -notcontains $controlPlaneName) {
        Write-Host "    [WARN] Control plane VM '$controlPlaneName' does not exist." -ForegroundColor Yellow
        $problems += "controlplane missing"
    } else {
        Write-Host "    [OK] Control plane VM exists." -ForegroundColor Green
    }

    $foundWorkers = $existingNames | Where-Object { $_ -match '^node\d+$' }
    if (-not $foundWorkers) {
        Write-Host "    [WARN] No worker VMs found." -ForegroundColor Yellow
        $problems += "no workers"
    } else {
        Write-Host "    [OK] Found worker(s): $($foundWorkers -join ', ')" -ForegroundColor Green
    }

    return $problems
}

# ------------------------------------------------------------------
# Create missing VMs
# ------------------------------------------------------------------
function New-ClusterVMs {
    param([int]$Count, [string]$Cpus, [string]$Memory, [string]$Disk)

    Write-Host ">>> Creating any missing VMs..." -ForegroundColor Cyan
    $existingNames = (multipass list --format csv | ConvertFrom-Csv) |
        Select-Object -ExpandProperty Name

    if ($existingNames -notcontains $controlPlaneName) {
        Write-Host "    Creating $controlPlaneName..." -ForegroundColor Green
        multipass launch --name $controlPlaneName --cpus $Cpus --memory $Memory --disk $Disk
    }

    for ($i = 1; $i -le $Count; $i++) {
        $name = "node{0:D2}" -f $i
        if ($existingNames -notcontains $name) {
            Write-Host "    Creating $name..." -ForegroundColor Green
            multipass launch --name $name --cpus $Cpus --memory $Memory --disk $Disk
        }
    }
}

# ------------------------------------------------------------------
# Provisioning helpers (run only when needed)
# ------------------------------------------------------------------
function Test-NeedsProvisioning {
    param([string]$Vm)
    # Returns $true if kubeadm is missing on the VM.
    $has = multipass exec $Vm -- bash -c "command -v kubeadm >/dev/null 2>&1 && echo yes || echo no"
    return ($has.Trim() -ne "yes")
}

function Invoke-BaseProvision {
    param([string]$Vm, [string]$K8sMinor)

    Write-Host ">>> Provisioning base Kubernetes packages on $Vm..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-DryRun "provision base packages on $Vm (containerd, kubeadm/kubelet/kubectl)"
        return
    }

    $bootstrap = @"
set -e
echo '=== Disabling swap ==='
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

echo '=== Kernel modules & sysctl ==='
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo '=== Installing containerd ==='
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo '=== Adding Kubernetes apt repo ($K8sMinor) ==='
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8sMinor/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8sMinor/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo '=== Installing kubelet kubeadm kubectl ==='
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet

echo '=== Base provisioning complete ==='
"@

    # Write the bootstrap to a file inside the VM and run it
    $bootstrap | multipass exec $Vm -- bash -c "cat > /tmp/bootstrap.sh"
    multipass exec $Vm -- bash -c "bash /tmp/bootstrap.sh"
}

function Install-ControlPlaneScript {
    param([string]$Vm, [string]$CalicoVersion, [string]$PodCidr)

    Write-Host ">>> Installing recover-cp2.sh on $Vm..." -ForegroundColor Cyan

    $cpScript = @"
#!/bin/bash
set -e
echo '============================================'
echo ' CONTROL PLANE RECOVERY'
echo '============================================'
CP_IP=\$(hostname -I | awk '{print \$1}')
echo ">>> Current IP detected: \$CP_IP"
K8S_VER=\$(kubeadm version -o short)
echo ">>> Recovering at detected version: \$K8S_VER"
sleep 2
echo '=== 0. Ensure containerd is up ==='
sudo systemctl enable containerd
sudo systemctl restart containerd
sleep 5
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps >/dev/null && echo '>>> containerd OK' || { echo '!!! containerd not reachable'; exit 1; }
echo '=== 1. Pre-pull images ==='
sudo kubeadm config images pull --kubernetes-version=\$K8S_VER
echo '=== 2. Reset any existing cluster ==='
sudo kubeadm reset -f
sudo rm -rf ~/.kube /etc/cni/net.d
echo '=== 2b. Restart containerd after reset ==='
sudo systemctl restart containerd
sleep 5
echo "=== 3. Re-init on current IP: \$CP_IP ==="
sudo kubeadm init --apiserver-advertise-address=\$CP_IP --pod-network-cidr=$PodCidr --kubernetes-version=\$K8S_VER
echo '=== 4. Setting up kubeconfig ==='
mkdir -p \$HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
echo '=== 5. Applying Calico ==='
if [ ! -f ~/calico.yaml ]; then
  curl -fsSL -o ~/calico.yaml https://cdn.jsdelivr.net/gh/projectcalico/calico@$CalicoVersion/manifests/calico.yaml
fi
kubectl apply -f ~/calico.yaml
echo '============================================'
echo " CONTROL PLANE READY on \$CP_IP"
echo '============================================'
sleep 10
kubeadm token create --print-join-command
"@

    $cpScript | multipass exec $Vm -- bash -c "cat > ~/recover-cp2.sh"
    # multipass exec $Vm -- bash -c "chmod +x ~/recover-cp2.sh"
    multipass exec $Vm -- bash -c "sed -i 's/\r$//' ~/recover-cp2.sh && chmod +x ~/recover-cp2.sh"
}

function Install-WorkerScript {
    param([string]$Vm)

    Write-Host ">>> Installing recover-node.sh on $Vm..." -ForegroundColor Cyan

    $wScript = @"
#!/bin/bash
set -e
echo '============================================'
echo ' NODE RECOVERY (worker rejoin)'
echo '============================================'
echo '=== 0. Ensure containerd is up ==='
sudo systemctl enable containerd
sudo systemctl restart containerd
sleep 5
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps >/dev/null && echo '>>> containerd OK' || { echo '!!! containerd not reachable'; exit 1; }
echo '=== 1. Reset any existing state ==='
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
echo '============================================'
echo ' NODE RESET COMPLETE'
echo '============================================'
"@

    $wScript | multipass exec $Vm -- bash -c "cat > ~/recover-node.sh"
    # multipass exec $Vm -- bash -c "chmod +x ~/recover-node.sh"
    multipass exec $Vm -- bash -c "sed -i 's/\r$//' ~/recover-node.sh && chmod +x ~/recover-node.sh"
}

function Ensure-Provisioned {
    param([string]$Vm, [string]$Role, [string]$K8sMinor, [string]$CalicoVersion, [string]$PodCidr)

    # Base packages
    if (Test-NeedsProvisioning -Vm $Vm) {
        Write-Host ">>> $Vm needs base provisioning." -ForegroundColor Yellow
        Invoke-BaseProvision -Vm $Vm -K8sMinor $K8sMinor
    } else {
        Write-Host "    [OK] $Vm already has kubeadm - skipping base provisioning." -ForegroundColor Green
    }

    # Recovery scripts
    if ($Role -eq "controlplane") {
        $has = multipass exec $Vm -- bash -c "test -f ~/recover-cp2.sh && echo yes || echo no"
        if ($has.Trim() -ne "yes") {
             if ($DryRun) { 
                Write-DryRun "install recover-cp2.sh on $Vm" 
            }
             else { 
                Install-ControlPlaneScript -Vm $Vm -CalicoVersion $CalicoVersion -PodCidr $PodCidr 
            }
            # Install-ControlPlaneScript -Vm $Vm -CalicoVersion $CalicoVersion -PodCidr $PodCidr
        } else {
            Write-Host "    [OK] recover-cp2.sh present on $Vm." -ForegroundColor Green
        }
    } else {
        $has = multipass exec $Vm -- bash -c "ls ~/recover-node*.sh 2>/dev/null | head -n1"
        if (-not $has.Trim()) {
        #    Install-WorkerScript -Vm $Vm
            if ($DryRun) { 
                Write-DryRun "install recover-node.sh on $Vm" 
            }
            else { 
                Install-WorkerScript -Vm $Vm 
            }

        } else {
            Write-Host "    [OK] Recovery script present on $Vm." -ForegroundColor Green
        }
    }
}

function Test-ClusterHealthy {
    # Returns $true if the control plane is reachable AND at least one node is Ready.
    try {
        $ready = multipass exec $controlPlaneName -- bash -c "kubectl get --raw='/readyz' 2>/dev/null"
        if ($ready.Trim() -ne "ok") { return $false }

        $readyNodes = multipass exec $controlPlaneName -- bash -c `
            "kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready '"
        return ([int]($readyNodes.Trim()) -gt 0)
    } catch {
        return $false
    }
}

# ==================================================================
# MAIN FLOW
# ==================================================================

# --- Prerequisite checks ---
$issues = Test-Prerequisites

if ($issues.Count -gt 0 -and $CreateMissingVMs) {
    if ($issues -contains "Multipass missing") {
        Add-Failure "Cannot create VMs: Multipass is not installed. Install it (https://multipass.run/) and re-run."
    } else {
        if ($DryRun) {
            Write-DryRun "create missing VMs (control plane + up to $WorkerCount workers)"
        } else {
            Write-Host ">>> -CreateMissingVMs specified. Creating missing VMs..." -ForegroundColor Cyan
            New-ClusterVMs -Count $WorkerCount -Cpus $Cpus -Memory $Memory -Disk $Disk
            $issues = Test-Prerequisites
        }
    }
}

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "!!! Prerequisite checks failed:" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host ">>> Fix the items above, or re-run with -CreateMissingVMs to auto-create VMs." -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host ">>> All prerequisite checks passed." -ForegroundColor Green

# --- Discover workers ---
if ($Workers.Count -eq 0) {
    $Workers = (multipass list --format csv | ConvertFrom-Csv) |
        Where-Object { $_.Name -match '^node\d+$' } |
        Select-Object -ExpandProperty Name |
        Sort-Object
}
if ($Workers.Count -eq 0) {
    Add-Failure "No worker nodes available to join."
    Write-Host ">>> Aborting: no workers." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host ">>> Workers: $($Workers -join ', ')" -ForegroundColor Cyan

# --- Ensure all VMs are running ---
$allVms = @($controlPlaneName) + $Workers
$current = (multipass list --format csv | ConvertFrom-Csv)
foreach ($vm in $allVms) {
    $state = ($current | Where-Object { $_.Name -eq $vm }).State
    if ($state -ne "Running") {
         if ($DryRun) {
            Write-DryRun "start VM $vm"
        } else {
            Write-Host ">>> Starting $vm..." -ForegroundColor Green
            multipass start $vm
        }
    }
}

# --- Provision only where needed ---
Ensure-Provisioned -Vm $controlPlaneName -Role "controlplane" -K8sMinor $K8sMinor -CalicoVersion $CalicoVersion -PodCidr $PodCidr
foreach ($w in $Workers) {
    Ensure-Provisioned -Vm $w -Role "worker" -K8sMinor $K8sMinor -CalicoVersion $CalicoVersion -PodCidr $PodCidr
}

# --- Guard: don't clobber a healthy cluster without consent ---
Write-Host ">>> Checking whether a healthy cluster is already running..." -ForegroundColor Cyan
if (Test-ClusterHealthy) {
    Write-Host "" 
    Write-Host "============================================" -ForegroundColor Yellow
    Write-Host " A HEALTHY CLUSTER IS ALREADY RUNNING" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
    multipass exec $controlPlaneName -- bash -c "kubectl get nodes -o wide"
    Write-Host ""
    Write-Host " Proceeding will RESET and RE-INITIALIZE the cluster." -ForegroundColor Yellow
    Write-Host " All current workloads/pods will be lost (VMs are kept)." -ForegroundColor Yellow
    Write-Host ""
    if ($DryRun) {
        Write-DryRun "a healthy cluster is running; a real run would prompt before resetting it"
        Write-DryRun "skip reset and continue preview without changing anything"
    }
    elseif ($NonInteractive) {
        # In unattended mode, do NOT destroy a healthy cluster automatically.
        Write-Host ">>> NonInteractive mode: healthy cluster detected; leaving it untouched." -ForegroundColor Green
        Write-Host ">>> To force a rebuild unattended, run with -ForceReset." -ForegroundColor Yellow
        if (-not $ForceReset) {
            Stop-Transcript | Out-Null
            exit 0
        }
        Write-Host ">>> -ForceReset specified; proceeding with reset." -ForegroundColor Yellow
    } else {
        $answer = Read-Host " Tear down and re-initialize the existing cluster? (Y/N)"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host ">>> Leaving the existing cluster untouched. Exiting." -ForegroundColor Green
            Stop-Transcript | Out-Null
            exit 0
        }
        Write-Host ">>> Proceeding with reset at user request." -ForegroundColor Yellow
    }
} else {
    Write-Host "    No healthy running cluster detected - proceeding normally." -ForegroundColor Green
}


# --- Recover control plane ---
Write-Host ">>> Recovering control plane..." -ForegroundColor Green
try {
    if ($DryRun) {
        Write-DryRun "run recover-cp2.sh on $controlPlaneName (reset + re-init cluster)"
    } else {
        multipass exec $controlPlaneName -- bash -c "bash ~/recover-cp2.sh"
    }
} catch {
    Add-Failure "Control plane recovery failed. Check the log above."
    Write-Host ">>> Aborting: control plane not recovered." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# --- Wait for API readiness ---
if (-not $DryRun) {
Write-Host ">>> Waiting for API server..." -ForegroundColor Green
$attempt = 0; $ready = ""
do {
    Start-Sleep -Seconds 5; $attempt++
    $ready = multipass exec $controlPlaneName -- bash -c "kubectl get --raw='/readyz' 2>/dev/null"
    Write-Host "    attempt $attempt/40 -> '$ready'"
} until ($ready -eq "ok" -or $attempt -ge 40)

if ($ready -ne "ok") {
    Add-Failure "API server did not become ready in time."
    Write-Host ">>> Aborting: API not ready." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
}

# --- Generate fresh join command ---
if ($DryRun) {
    Write-DryRun "generate a fresh kubeadm join command"
} else {
    try {
    Write-Host ">>> Generating join command..." -ForegroundColor Green
    $joinCmd = multipass exec $controlPlaneName -- bash -c "kubeadm token create --print-join-command"
    $joinCmd = $joinCmd.Trim()
    Write-Host ">>> Join command captured." -ForegroundColor Green
    } catch {        
    Add-Failure "Failed to generate join command from control plane."
    Stop-Transcript | Out-Null
    exit 1
    }
}

# --- Recover + join each worker (with retries) ---
foreach ($w in $Workers) {
    Write-Host ">>> Recovering $w..." -ForegroundColor Green
    if ($DryRun) {
        Write-DryRun "run recovery script on $w and join it to the cluster"
        continue
    }
    try {
        $script = (multipass exec $w -- bash -c "ls ~/recover-node*.sh 2>/dev/null | head -n1").Trim()
        if (-not $script) {
            Add-Failure "$w has no recover-node*.sh script; cannot recover."
            continue
        }
        multipass exec $w -- bash -c "bash $script"
    } catch {
        Add-Failure "$w recovery script failed."
        continue
    }

    $joined = $false
    for ($i = 1; $i -le 3; $i++) {
        Write-Host ">>> Joining $w (attempt $i)..." -ForegroundColor Green
        try {
            multipass exec $w -- sudo bash -c "$joinCmd"
            $joined = $true
            break
        } catch {
            Write-Host "    join attempt $i failed, resetting and retrying..." -ForegroundColor Yellow
            multipass exec $w -- sudo bash -c "kubeadm reset -f; rm -rf /etc/cni/net.d" 2>$null
            Start-Sleep -Seconds 10
        }
    }
    if (-not $joined) {
        Add-Failure "$w failed to join after 3 attempts."
    }
}

# --- Wait for all nodes Ready ---
if (-not $DryRun) {
Write-Host ">>> Waiting for all nodes to become Ready..." -ForegroundColor Green
$attempt = 0; $notReady = 999
do {
    Start-Sleep -Seconds 10; $attempt++
    $raw = multipass exec $controlPlaneName -- bash -c "kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready ' | wc -l"
    $notReady = [int]($raw.Trim())
    Write-Host "    attempt $attempt/40 -> $notReady node(s) not Ready"
} until ($notReady -eq 0 -or $attempt -ge 40)

if ($notReady -ne 0) {
    Add-Failure "$notReady node(s) did not reach Ready state in time."
}
}

# --- Final status ---
Write-Host ">>> Final cluster status:" -ForegroundColor Cyan
multipass exec $controlPlaneName -- bash -c "kubectl get nodes -o wide"

# --- Open interactive shells FIRST (so you always get your panels) ---
if ($DryRun) {
    Write-DryRun "open interactive shells for: $((@($controlPlaneName) + $Workers) -join ', ')"
    Write-DryRun "copy kubeconfig to $env:USERPROFILE\.kube\config"
}
elseif (-not $NonInteractive) {
    Write-Host ">>> Opening interactive shells..." -ForegroundColor Cyan
    foreach ($vm in (@($controlPlaneName) + $Workers)) {
        Start-Process powershell -ArgumentList "-NoExit","-Command","multipass shell $vm"
    }
    Write-Host "    Opened $(( @($controlPlaneName) + $Workers).Count) shell window(s)." -ForegroundColor Green
}


# --- Copy corrected kubeconfig to Windows (optional convenience) ---
if (-not $DryRun) {
Write-Host ">>> Copying kubeconfig to Windows..." -ForegroundColor Green
try {
    $kubeDir = Join-Path $env:USERPROFILE ".kube"
    if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null }
    $destPath = Join-Path $kubeDir "config"

    $job = Start-Job -ScriptBlock {
        param($cpName, $destPath)

        $ip = (multipass info $cpName --format csv | ConvertFrom-Csv).IPv4

        # Transfer to a neutral temp file first (avoids sftp permission-set error on the .kube path)
        $tmp = Join-Path $env:TEMP "kubeconfig_transfer.txt"
        multipass exec $cpName -- bash -c "cat ~/.kube/config > /tmp/kubeconfig.txt"
        multipass transfer "${cpName}:/tmp/kubeconfig.txt" $tmp
        multipass exec $cpName -- bash -c "rm -f /tmp/kubeconfig.txt"

        # Read the temp file, rewrite server IP, write to the real kubeconfig path
        (Get-Content $tmp) -replace 'server: https://.*:6443', "server: https://${ip}:6443" |
            Set-Content $destPath
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue

        [PSCustomObject]@{ Ip = $ip; Dest = $destPath }
    } -ArgumentList $controlPlaneName, $destPath

    if (Wait-Job $job -Timeout 90) {
        $result = Receive-Job $job
        if ($result -and (Test-Path $result.Dest)) {
            Write-Host "    kubeconfig written to $($result.Dest) (server https://$($result.Ip):6443)" -ForegroundColor Green
        } else {
            Write-Host "    [WARN] kubeconfig job finished but no file produced (non-fatal)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "    [WARN] kubeconfig copy timed out (90s); skipping (non-fatal)." -ForegroundColor Yellow
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
} catch {
        Write-Host "    [WARN] Could not copy kubeconfig to Windows (non-fatal)." -ForegroundColor Yellow
}
}
# --- Final status ---
# Write-Host ">>> Final cluster status:" -ForegroundColor Cyan
# multipass exec $controlPlaneName -- bash -c "kubectl get nodes -o wide"

# ==================================================================
# FAILURE NOTIFICATION SUMMARY (printed on screen for the user)
# ==================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
if ($script:Failures.Count -eq 0) {
    Write-Host " CLUSTER READY - no failures reported." -ForegroundColor Green
} else {
    Write-Host " COMPLETED WITH $($script:Failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }

    # Export failures to a timestamped file alongside the transcript
    $failFile = Join-Path $logDir "failures-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
    $script:Failures | Out-File -Encoding utf8 $failFile
    Write-Host " Failures written to: $failFile" -ForegroundColor Yellow
    Write-Host " Review the transcript log in $logDir." -ForegroundColor Yellow
}
Write-Host "============================================" -ForegroundColor Cyan

Stop-Transcript | Out-Null
if ($script:Failures.Count -gt 0) { exit 1 } else { exit 0 }


