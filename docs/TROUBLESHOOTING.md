## `docs/TROUBLESHOOTING.md`

```markdown
# Troubleshooting

## Logs
Every run writes a timestamped transcript to the logs folder:
C:\k8s-cluster-agent\logs\cluster-YYYYMMDD-HHMMSS.log
Open the most recent log to see exactly what happened, including any failures
collected in the on-screen summary at the end of a run.

## Quick checks
- Confirm Multipass works:
  ```powershell
  multipass version
  multipass list
•	Confirm execution policy allows scripts:
•	Get-ExecutionPolicy -Scope CurrentUser   # expect: RemoteSigned
•	Confirm cluster status from the control plane:
•	multipass exec controlplane -- bash -c "kubectl get nodes -o wide"
Common issues
| Symptom | Likely cause | Fix | |---|---|---| | "Multipass is not installed" | Multipass missing / not on PATH | Install from https://multipass.run/ and reboot | | "Resources are TOO TIGHT" (unattended) | Not enough host headroom | Free RAM/disk, or use fewer/smaller VMs, then re-run | | "Not enough resources" (INSUFFICIENT) | Requested cluster exceeds host | Reduce -WorkerCount, -Memory, or -Disk; free resources | | API server never becomes ready | Wrong advertise IP, or etcd/kubelet not up | On control plane: sudo crictl ps and journalctl -u kubelet | | Worker join fails repeatedly | Token expired or version skew | Agent regenerates a fresh token each run; verify versions match across nodes | | Nodes stuck NotReady | CNI (Calico) not applied or not up | kubectl get pods -n kube-system; confirm Calico pods are Running | | Windows kubectl can't connect | IP drift not reflected in kubeconfig | Re-run the agent; it rewrites the kubeconfig server IP | | apt/package step fails during provisioning | Retired Kubernetes minor version | Re-run with a supported -K8sMinor (e.g., v1.31, v1.32, v1.33) | | containerd "not reachable" | Runtime wedged after reboot | The recovery scripts restart containerd; re-run the agent. Manually: `multipass exec <vm> -- sudo systemctl restart containerd` |
| Script won't run ("cannot be loaded") | Execution policy not set | `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned` |
| Prompts/shell windows behave oddly | Running inside PowerShell ISE | Run the agent in the plain PowerShell console instead |

## Checking versions across nodes
Version skew between the control plane and workers can cause join failures.
Compare them:
```powershell
multipass exec controlplane -- bash -c "kubeadm version -o short"
multipass exec node01       -- bash -c "kubeadm version -o short"
multipass exec node02       -- bash -c "kubeadm version -o short"
If they differ significantly, re-provision the affected node or rebuild with a consistent -K8sMinor.
Inspecting a node directly
Open a shell to investigate:
multipass shell controlplane
Useful commands inside a VM:
sudo crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps
journalctl -u kubelet -n 100 --no-pager
kubectl get pods -A          # control plane only
sudo systemctl status containerd
Freeing resources
List and stop/delete unused Multipass VMs:
multipass list
multipass stop <name>
multipass delete <name>
multipass purge            # reclaims disk from deleted VMs
Or use the project scripts:
.\Stop-Cluster.ps1         # stop VMs, keep them (free RAM/CPU)
.\Remove-Cluster.ps1       # delete + purge VMs (free disk too)
Clean-slate rebuild
To rebuild the cluster from scratch:
.\Remove-Cluster.ps1 -Force
.\Start-Cluster.ps1
The agent will detect that no VMs exist, check resources, create the control plane and workers, provision them, and build the cluster fresh.
Recommended testing order
1.	Non-destructive run against an existing cluster — validates the recover/join path without creating or deleting anything:
2.	.\Start-Cluster.ps1
3.	Reboot-recovery test — restart Windows (triggers IP drift), then run the agent again to confirm it recovers the cluster.
4.	Clean-slate test — only when ready to lose the current cluster:
5.	.\Remove-Cluster.ps1 -Force
6.	.\Start-Cluster.ps1
Exit codes
•	0 — success (no failures reported).
•	1 — one or more failures, or VM creation declined/blocked by resource checks. Useful for automation (e.g., Task Scheduler can detect failures).
Still stuck?
•	Re-read the latest transcript in logs\ — the failure summary at the end lists exactly what went wrong.
•	Confirm host resources are sufficient for the requested cluster size.
•	Confirm the Kubernetes minor version (-K8sMinor) is currently supported.
