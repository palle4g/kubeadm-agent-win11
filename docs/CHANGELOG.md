# Changelog

All notable changes to this project are documented in this file.
This project follows a simple versioned format.

## [1.1.0] - 2026-10-02

### Added
- Health-check guard: detects an already-healthy running cluster and prompts
  before resetting/re-initializing it. Interactive runs ask Y/N; unattended
  runs leave a healthy cluster untouched unless `-ForceReset` is given.
- `-ForceReset` switch to allow rebuilding a healthy cluster in `-NonInteractive` mode.
- Auto-opening of interactive shells now runs before the kubeconfig copy, so the
  node shells always open even if the kubeconfig step has trouble.
- Documentation: how/when to manually open node shells and manually copy the
  kubeconfig (USAGE.md).

### Changed
- Kubeconfig copy to Windows is now timeout-guarded (90s) and non-fatal, so it
  can never hang the run.
- Kubeconfig copy uses `multipass transfer` via a neutral temp file to avoid the
  Windows sftp "cannot set permissions" error.
- CRLF normalization (`sed -i 's/\r$//'`) added before making generated recovery
  scripts executable, preventing `bad interpreter: /bin/bash^M` failures.
- Standardized project path to `C:\k8s-agent\` across documentation.
- Enforced worker-count cap (1..3; default 2) in Start-Cluster.ps1.
- Extended -DryRun guards to VM-start and recovery-script installation steps.
- Noted that -DryRun still writes a transcript log by design (not write-free).


### Fixed
- Script hang at "Copying kubeconfig to Windows..." caused by an open-ended
  `multipass exec | Out-File` pipe.
- Duplicate "Final cluster status" output removed.
- Parser errors in the health-check guard caused by smart quotes / string breaks.

## [1.0.0] - initial

### Added
- PowerShell agent (`Start-Cluster.ps1`) orchestrating a kubeadm cluster on
  Multipass VMs from Windows (no manual shells / copy-paste).
- Prerequisite checks (Multipass, VMs).
- Creation of missing VMs (control plane + workers) via interactive prompt or
  `-CreateMissingVMs`.
- Default 2 workers (3-node cluster), maximum 3; auto-capped.
- Fail-safe host resource checking (OK / TIGHT / INSUFFICIENT) with fix guidance;
  unattended runs only create VMs with comfortable headroom.
- Interactive and `-NonInteractive` modes.
- Idempotent provisioning: containerd, kubelet/kubeadm/kubectl, and recovery
  scripts installed only when missing.
- Control-plane recovery (IP-drift aware), API-readiness wait, fresh join command,
  worker recovery + join with retries, all-nodes-Ready wait.
- Kubeconfig copy to Windows (server IP rewritten for drift).
- On-screen failure summary and meaningful exit codes.
- Companion scripts: `Stop-Cluster.ps1`, `Remove-Cluster.ps1`, `Backup-ClusterFiles.ps1`.
- Documentation: README.md, USAGE.md, TROUBLESHOOTING.md.