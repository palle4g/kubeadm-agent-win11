# Kubernetes Cluster Agent (Multipass on Windows11)

An automated agent that builds, recovers, and manages a small kubeadm-based
Kubernetes cluster running in Multipass VMs on a Windows desktop.

It replaces the manual workflow of opening multiple Multipass shells, running
per-node recovery scripts, and copy-pasting the `kubeadm join` command after
every reboot.

## Project layout

kubeadm-agent-win11/ ├── src/ │ ├── Start-Cluster.ps1 # build + recover the cluster │ ├── Stop-Cluster.ps1 # pause: stop VMs, keep them │ ├── Remove-Cluster.ps1 # teardown: delete + purge VMs │ └── Backup-ClusterFiles.ps1 # back up each VM home dir ├── docs/ │ ├── USAGE.md │ ├── TROUBLESHOOTING.md │ └── CHANGELOG.md ├── README.md ├── LICENSE └── logs/ # runtime transcripts (git-ignored)

## What it does

- Checks prerequisites (Multipass installed, VMs present).
- Creates VMs (control plane + workers) when missing.
- Provisions VMs only when needed (containerd, kubeadm/kubelet/kubectl, recovery scripts).
- Recovers the control plane after reboots (handles IP drift automatically).
- Recovers and re-joins worker nodes, with retries.
- Waits for the API server and all nodes to become Ready.
- Copies a corrected kubeconfig to Windows for local kubectl use.
- Opens interactive shells to all nodes when finished (interactive mode).
- Prints a clear failure summary and returns a meaningful exit code.

## Capabilities

- Variable worker nodes: default 2, maximum 3.
- Interactive mode (guided prompts) and unattended mode (`-NonInteractive`).
- Fail-safe resource checking: unattended runs only create VMs with comfortable headroom.
- Idempotent: safe to re-run; skips work already done.
- -DryRun previews all actions and makes no changes to VMs or the cluster,
  though it does write a transcript log.

## What you can use it for

- Quickly standing up a lab/test Kubernetes cluster.
- Recovering a cluster after a desktop reboot (solves Multipass IP drift).
- Repeatable, portable cluster bootstrap on any machine with Multipass.

## Requirements

- Windows 11 with PowerShell (5.1+ or PowerShell 7+).
- Multipass installed (https://multipass.run/).
- Sufficient CPU/RAM/disk for the requested cluster size.

## Quick start

```powershell
cd C:\k8s-agent\src
.\Start-Cluster.ps1
See USAGE.md for all options and TROUBLESHOOTING.md for help.
Cluster lifecycle
•	Build / recover: .\Start-Cluster.ps1
•	Pause (keep VMs): .\Stop-Cluster.ps1
•	Resume: .\Start-Cluster.ps1
•	Tear down (delete): .\Remove-Cluster.ps1
•	Open node shells: run the three Start-Process ... multipass shell ... commands (see USAGE.md → Working with the cluster afterward)
Notes
•	"3-node cluster" means 1 control plane + 2 workers (the default).
•	The agent covers the control plane as well as workers.
•	All discovered node## VMs are joined; pass -Workers to limit which ones.
•	Kubernetes package repos for old minor versions get retired over time; if provisioning fails at the package step, re-run with a supported -K8sMinor.
Working with the cluster afterward
When Start-Cluster.ps1 finishes (interactive mode), it automatically opens three PowerShell windows — one shell into each node (controlplane, node01, node02).
Manually opening the node shells
If you ever need to open the shells yourself — for example:
•	the cluster is already running and you just want terminals,
•	you closed the windows and want them back,
•	you ran in -NonInteractive mode (which does not open shells),
•	the script was interrupted before the shell-opening step —
run these from a normal PowerShell window:
Start-Process powershell -ArgumentList "-NoExit","-Command","multipass shell controlplane"
Start-Process powershell -ArgumentList "-NoExit","-Command","multipass shell node01"
Start-Process powershell -ArgumentList "-NoExit","-Command","multipass shell node02"
Each command opens a separate window and drops you into that VMs Ubuntu shell. -NoExit keeps the window open after the shell starts.
You do NOT need to re-run Start-Cluster.ps1 just to get the shells — the cluster stays up, and these commands simply attach terminals to the running VMs.
Working from Windows with kubectl (optional)
If you prefer kubectl on Windows instead of shelling into a node, the agent copies a corrected kubeconfig to %USERPROFILE%.kube\config. If that copy failed or was skipped, copy it manually:
multipass exec controlplane -- bash -c "cat ~/.kube/config > /tmp/kubeconfig.txt"
multipass transfer controlplane:/tmp/kubeconfig.txt "$env:USERPROFILE\.kube\config"
$cpIp = (multipass info controlplane --format csv | ConvertFrom-Csv).IPv4
(Get-Content "$env:USERPROFILE\.kube\config") -replace 'server: https://.*:6443', "server: https://${cpIp}:6443" | Set-Content "$env:USERPROFILE\.kube\config"
multipass exec controlplane -- bash -c "rm -f /tmp/kubeconfig.txt"
kubectl get nodes
Security
•	Never commit kubeconfig files, tokens, join commands, or certificate data.
•	The runtime logs/ folder is git-ignored for this reason.
•	If a secret is ever leaked, rotate/revoke it immediately.
License
Licensed under the Apache License 2.0. See the LICENSE file for details.
