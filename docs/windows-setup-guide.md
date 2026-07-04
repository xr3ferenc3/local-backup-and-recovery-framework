# Windows Server 2022 Setup Guide

This guide walks through setting up the Local Backup and Recovery
Framework on Windows Server 2022, from prerequisites through to a
verified first backup.

Assume no prior exposure to this framework. Each step states what to do,
why it matters, and how to confirm it worked before moving to the next
step.

---

## Prerequisites

### System requirements

| Requirement | Detail |
|---|---|
| Operating system | Windows Server 2022 (Windows Server 2016/2019 are compatible but untested by this project) |
| PowerShell | 5.1 or later - included by default |
| Disk space | Destination volume must have free space at minimum equal to the total size of all source paths combined |
| Permissions | Local Administrator or Backup Operator group membership |

### Verify PowerShell version

```powershell
$PSVersionTable.PSVersion
```

Expected output: `Major` version `5` or higher. PowerShell 5.1 ships by
default with Windows Server 2022; no installation is required.

### Verify the Volume Shadow Copy Service is available

VSS is required only if `use_vss` is set to `true` in your configuration
(the recommended default for backing up systems with files that may be
open during the backup window).

```powershell
Get-Service -Name VSS
```

Expected output: `Status` showing `Stopped` is normal - VSS starts
automatically on demand when a shadow copy is requested. Confirm the
service exists and is not `Disabled`:

```powershell
Get-Service -Name VSS | Select-Object Status, StartType
```

If `StartType` shows `Disabled`, change it:

```powershell
Set-Service -Name VSS -StartupType Manual
```

---

## Step 1: Clone the Repository

```powershell
git clone https://github.com/YOUR-USERNAME/local-backup-and-recovery-framework.git
cd local-backup-and-recovery-framework
```

**Verification:**
```powershell
Get-ChildItem -Recurse -Depth 1
```
Expected: `windows\`, `linux\`, `config\`, `docs\`, `checklists\`, `output\`
directories are all present.

---

## Step 2: Prepare the Destination Volume

Identify or create the volume or path where backups will be stored. This
should ideally be physically separate storage from the source data - see
`threat-model.md` for why.

```powershell
# Example: create a backup root on a secondary volume
New-Item -ItemType Directory -Path "D:\Backups" -Force
New-Item -ItemType Directory -Path "D:\Backups\Logs" -Force
New-Item -ItemType Directory -Path "D:\Backups\Reports" -Force
```

**Verification:**
```powershell
Test-Path "D:\Backups"
Test-Path "D:\Backups\Logs"
Test-Path "D:\Backups\Reports"
```
Expected: All three return `True`.

---

## Step 3: Create Your Configuration File

Copy the example configuration and populate it for your environment.

```powershell
Copy-Item config\windows-backup.example.json config\windows-backup.json
notepad config\windows-backup.json
```

### Minimum fields to review and update

| Field | What to set it to |
|---|---|
| `backup.source_paths` | An array of absolute paths you want backed up |
| `backup.destination_root` | The path created in Step 2 (e.g. `D:\Backups`) |
| `backup.backup_set_prefix` | A short identifier for this host, e.g. your hostname |
| `backup.use_vss` | `true` is recommended unless VSS is unavailable |
| `logging.log_directory` | e.g. `D:\Backups\Logs` |
| `reporting.report_output_directory` | e.g. `D:\Backups\Reports` |
| `retention.retain_days` | Review the default of `30`; adjust per `retention-policy.md` |

Every field in the example file includes an inline `_comment` explaining
its purpose and acceptable values. Read these before changing defaults.

**Verification - confirm the JSON is valid:**
```powershell
Get-Content config\windows-backup.json | ConvertFrom-Json | Out-Null
if ($?) { Write-Host "Configuration is valid JSON" -ForegroundColor Green }
```

---

## Step 4: Run a Dry-Run Backup

Before copying any real data, validate the configuration end to end using
dry-run mode.

```powershell
.\windows\Invoke-Backup.ps1 -ConfigPath .\config\windows-backup.json -DryRun
```

**What to look for in the output:**
- Each configured source path is acknowledged
- No `[ERROR]` entries appear
- The console reports `[DRY RUN] Would create backup set directory`
- The console reports `[DRY RUN] Would execute robocopy` for each source

If any source path is reported as not found, correct the path in your
configuration file before proceeding.

---

## Step 5: Run Your First Live Backup

```powershell
.\windows\Invoke-Backup.ps1 -ConfigPath .\config\windows-backup.json
```

This must be run from an elevated (Administrator) PowerShell session. The
script enforces this via `#Requires -RunAsAdministrator` and will refuse
to run otherwise.

**Verification:**
```powershell
# Confirm a backup set directory was created
Get-ChildItem -Path "D:\Backups" -Directory

# Confirm the run summary shows SUCCESS
Get-ChildItem -Path "D:\Backups\Logs" -Filter "Invoke-Backup_*.json" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Get-Content |
    Select-String '"message":"Backup run complete"'
```
Expected: A JSON line containing `"status":"SUCCESS"`.

---

## Step 6: Verify the Backup

```powershell
.\windows\Test-BackupIntegrity.ps1 -ConfigPath .\config\windows-backup.json
```

**Verification:**
The console output ends with a Verification Summary. Confirm `Status: PASS`.

If the status is `FAIL`, see `troubleshooting.md` before relying on this
backup set.

---

## Step 7: Generate a Report

```powershell
.\windows\New-BackupReport.ps1 -ConfigPath .\config\windows-backup.json
```

**Verification:**
```powershell
Get-ChildItem -Path "D:\Backups\Reports" -Filter "report_*.md" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
```
Open the report file and confirm it contains a Backup Execution section
and an Integrity Verification section, both with populated data.

---

## Step 8: Test Restoration (Required, Not Optional)

A backup that has never been restored from is an untested assumption.
Perform a restoration test to a non-production destination now, while
the stakes are low, rather than for the first time during an actual
incident.

```powershell
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination "D:\RestoreTest" -DryRun
```

Review the dry-run output, then perform a live test restore:

```powershell
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination "D:\RestoreTest"
```

**Verification:**
The console output ends with a Restoration Summary showing
`File Count Match: True` and `Hash Spot-Check: True`.

Clean up the test destination once verified:
```powershell
Remove-Item -Path "D:\RestoreTest" -Recurse -Force
```

For full restoration procedures, including partial restores and
disaster-recovery scenarios, see `restoration-runbook.md`.

---

## Step 9: Schedule the Framework

Manual execution is appropriate for initial testing only. For production
use, schedule the backup, verification, and retention scripts using Task
Scheduler. Full guidance, including recommended timing and conflict
avoidance, is in `scheduling-guide.md`.

---

## Step 10: Complete the Pre-Backup Checklist Going Forward

For every subsequent live backup run in a production context, use
`checklists/pre-backup-checklist.md` and
`checklists/post-backup-checklist.md` to maintain consistency and catch
issues before they become incidents.

---

## Setup Complete - Summary Checklist

- [ ] PowerShell 5.1+ confirmed
- [ ] VSS service confirmed available
- [ ] Repository cloned
- [ ] Destination volume prepared with `Backups`, `Logs`, `Reports`
      subdirectories
- [ ] Configuration file created and populated
- [ ] Dry-run backup completed with no errors
- [ ] Live backup completed with `SUCCESS` status
- [ ] Integrity verification completed with `PASS` status
- [ ] Report generated and reviewed
- [ ] Restoration tested to a non-production destination
- [ ] Scheduling configured (see `scheduling-guide.md`)

---

## Next Steps

| Topic | Document |
|---|---|
| Automate backup execution | `scheduling-guide.md` |
| Understand retention behavior | `retention-policy.md` |
| Full restoration procedures | `restoration-runbook.md` |
| Diagnose a problem | `troubleshooting.md` |
| Script syntax reference | `command-reference.md` |