# Usage Guide

## Do I need Administrator?
No. Run the agent from a **normal PowerShell console window**.
- `Set-ExecutionPolicy` below uses `-Scope CurrentUser`, which does NOT require admin.
- Administrator is only needed to:
  - Install Multipass (the installer prompts automatically via UAC), or
  - Register a Task Scheduler auto-run task (optional).

## Which PowerShell to use?
- To **run** the agent: use the plain **Windows PowerShell console**. All instructions assume this.
- To **edit** the scripts: PowerShell ISE works, but VS Code + the PowerShell extension is the
  recommended modern editor (better editing, debugging, and Git integration).
- Note: interactive prompts and the auto-opened shell windows are designed/tested against the
  plain console, so run the agent there (not in ISE) to avoid surprises.

## One-time setup
1. Install Multipass and reboot.
2. Allow script execution (persists across sessions — only needed once):
   - Check the current setting first:
     ```powershell
     Get-ExecutionPolicy -Scope CurrentUser
     ```
   - If it is NOT `RemoteSigned`, set it:
     ```powershell
     Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
     ```
   - Re-running this command is harmless (idempotent).

## Running the agent

### Interactive (recommended for people)
```powershell
cd C:\k8s-cluster-agent\src
.\Start-Cluster.ps1
•	If no VMs exist, the agent explains the plan (1 control plane + 2 workers by default), checks host resources, and asks permission before creating anything.
•	If VMs already exist, it skips creation/provisioning and just recovers + joins.
•	When ready, it opens interactive shell windows for each node.
Choosing worker count (max 3)
.\Start-Cluster.ps1 -CreateMissingVMs -WorkerCount 3
Explicit worker list
.\Start-Cluster.ps1 -Workers node01,node02
Unattended (Task Scheduler / automation)
.\Start-Cluster.ps1 -NonInteractive -CreateMissingVMs -WorkerCount 2
•	Creates VMs only if host resources are comfortably sufficient.
•	Exits with fix instructions if resources are tight or insufficient.
•	Does not prompt and does not open shell windows.
Custom VM sizing
.\Start-Cluster.ps1 -CreateMissingVMs -WorkerCount 2 -Cpus 4 -Memory 4G -Disk 40G
Kubernetes version
.\Start-Cluster.ps1 -K8sMinor v1.33
Parameters
| Parameter | Default | Notes | |--------------------|------------------|-------| | -Workers | (auto-discover) | Explicit list of worker VM names; capped at 3 | | -WorkerCount | 2 | Used when creating VMs; capped at 3 | | -CreateMissingVMs | off | Pre-authorize VM creation (still resource-checked) | | -NonInteractive | off | Unattended: no prompts, no shell windows, fail-safe on resources | | -Cpus | 2 | Per-VM logical CPUs | | -Memory | 2G | Per-VM RAM | | -Disk | 20G | Per-VM disk | | -K8sMinor | v1.31 | Kubernetes package repo minor version | | -CalicoVersion | v3.28.2 | CNI manifest version | | -PodCidr | 192.168.0.0/16 | Pod network CIDR |
Behavior notes
•	A "3-node cluster" means 1 control plane + 2 workers (the default).
•	Default worker count is 2; maximum is 3 (values above 3 are auto-capped).
•	Default when no VMs exist is also 2 workers.
•	VM creation covers the control plane AND workers, and creates only what is missing.
•	If more node## VMs exist than intended, ALL discovered nodes are joined. To limit, pass an explicit -Workers list (e.g., -Workers node01,node02).
•	Re-running is safe: existing/provisioned VMs skip creation and provisioning; only recovery + joins run.

Working with the cluster afterward
•	From Windows: kubectl get nodes (the agent copies a corrected kubeconfig to %USERPROFILE%\.kube\config).
•	From a node: use the shell windows the agent opened, or run:
•	multipass shell controlplane
When `Start-Cluster.ps1` finishes (interactive mode), it automatically opens three
PowerShell windows — one shell into each node (controlplane, node01, node02).
- A -DryRun run still writes a transcript log to C:\k8s-agent\logs\ (by design;
  dry runs are not fully write-free, but they make no changes to VMs or the cluster).
- Worker count is capped at 3 (default 2). Values above 3 are reduced to 3.

### Manually opening the node shells
If you ever need to open the shells yourself — for example:
- the cluster is already running and you just want terminals,
- you closed the windows and want them back,
- you ran in `-NonInteractive` mode (which does not open shells),
- the script was interrupted before the shell-opening step —

run these from a normal PowerShell window:

```powershell
Start-Process powershell -ArgumentList "-NoExit","-Command","multipass shell controlplane"
Start-Process powershell -ArgumentList "-NoExit","-Command","multipass shell node01"
Start-Process powershell -ArgumentList "-NoExit","-Command","multipass shell node02"
Each command opens a separate window and drops you into that VMs Ubuntu shell. -NoExit keeps the window open after the shell starts.
You do NOT need to re-run Start-Cluster.ps1 just to get the shells — the cluster stays up, and these commands simply attach terminals to the running VMs.

Working from Windows with kubectl (optional)
If you prefer kubectl on Windows instead of shelling into a node, the agent copies a corrected kubeconfig to %USERPROFILE%\.kube\config. If that copy failed or was skipped, copy it manually:

multipass exec controlplane -- bash -c "cat ~/.kube/config > /tmp/kubeconfig.txt"
multipass transfer controlplane:/tmp/kubeconfig.txt "$env:USERPROFILE\.kube\config"
$cpIp = (multipass info controlplane --format csv | ConvertFrom-Csv).IPv4
(Get-Content "$env:USERPROFILE\.kube\config") -replace 'server: https://.*:6443', "server: https://${cpIp}:6443" | Set-Content "$env:USERPROFILE\.kube\config"
multipass exec controlplane -- bash -c "rm -f /tmp/kubeconfig.txt"
kubectl get nodes

You could optionally also add a short "Open node shells" line to the **Cluster lifecycle** section in both USAGE.md and README.md for quick reference.


Cluster lifecycle
•	Build / recover: .\Start-Cluster.ps1
•	Pause (keep VMs): .\Stop-Cluster.ps1
•	Resume: .\Start-Cluster.ps1
•	Tear down (delete):.\Remove-Cluster.ps1
Optional: auto-recover after reboot (Task Scheduler)
Run once in an elevated PowerShell to register a logon task that self-heals the cluster:
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File C:\k8s-cluster-agent\src\Start-Cluster.ps1 -NonInteractive"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = "PT2M"   # 2-minute delay so networking/Multipass are ready
Register-ScheduledTask -TaskName "K8sClusterAgent" `
    -Action $action -Trigger $trigger -Description "Auto-recover kubeadm cluster at logon"
To remove it later:
Unregister-ScheduledTask -TaskName "K8sClusterAgent" -Confirm:$false
Troubleshooting
See TROUBLESHOOTING.md for logs location, common issues, freeing resources, and clean-slate rebuild steps.


