# Command Reference

Quick-reference guide for all scripts in this framework. This document
covers syntax, parameters, flags, examples, expected output, and exit
codes for every script on both platforms.

Use this document during daily operations when you need to look up exact
syntax. For operational context - when to run what and why - see the
setup guides, restoration runbook, and scheduling guide.

---

## Windows Scripts

All Windows scripts accept `-ConfigPath` as their primary parameter.
All scripts require PowerShell 5.1 or later. Scripts that modify system
state or access protected paths require an elevated (Administrator)
session.

---

### `Invoke-Backup.ps1`

Executes a backup run for all configured source paths.

**Syntax:**
```powershell
.\windows\Invoke-Backup.ps1 [-ConfigPath <string>] [-DryRun]
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-ConfigPath` | String | No | `config\windows-backup.json` | Path to the populated JSON configuration file |
| `-DryRun` | Switch | No | Off | Log intended actions without executing robocopy or creating VSS snapshots |

**Examples:**

```powershell
# Standard backup run
.\windows\Invoke-Backup.ps1 -ConfigPath .\config\windows-backup.json

# Validate configuration without copying files
.\windows\Invoke-Backup.ps1 -ConfigPath .\config\windows-backup.json -DryRun
```

**Expected output (success):**
```
=== Invoke-Backup v1.0.0 ===
[INFO] Backup run started
[INFO] VSS shadow copy created successfully
[INFO] Starting robocopy
[INFO] Robocopy completed successfully
[INFO] Manifest generated
--- Run Summary ---
Status          : SUCCESS
Backup Set      : WINSRV01_2025-06-15_0200
Sources Total   : 3
Sources Success : 3
Sources Failed  : 0
Duration        : 47s
Log File        : D:\Backups\Logs\Invoke-Backup_2025-06-15_0200.json
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | All sources backed up successfully |
| 1 | One or more sources failed - partial backup |
| 2 | Fatal error - no files copied |

**Requires:** Administrator session, robocopy (built in), VSS service
(if `use_vss` is `true`)

---

### `Test-BackupIntegrity.ps1`

Verifies a completed backup set against its source paths.

**Syntax:**
```powershell
.\windows\Test-BackupIntegrity.ps1 [-ConfigPath <string>] [-BackupSet <string>]
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-ConfigPath` | String | No | `config\windows-backup.json` | Path to the populated JSON configuration file |
| `-BackupSet` | String | No | Most recent | Name of the backup set to verify (e.g. `WINSRV01_2025-06-15_0200`) |

**Examples:**

```powershell
# Verify the most recent backup set
.\windows\Test-BackupIntegrity.ps1 -ConfigPath .\config\windows-backup.json

# Verify a specific backup set
.\windows\Test-BackupIntegrity.ps1 -ConfigPath .\config\windows-backup.json -BackupSet WINSRV01_2025-06-15_0200
```

**Expected output (pass):**

```
=== Test-BackupIntegrity v1.0.0 ===
[INFO] Verifying backup set
[INFO] File count check ... pass
[INFO] Size comparison check ... pass
[DEBUG] Spot-check hash comparison ... pass
--- Verification Summary ---
Status         : PASS
Backup Set     : WINSRV01_2025-06-15_0200
Checks Passed  : 3 / 3
Duration       : 12s
Log File       : D:\Backups\Logs\Test-BackupIntegrity_2025-06-15_0202.json
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | All checks passed |
| 1 | One or more checks failed |
| 2 | Fatal error - configuration invalid or backup set not found |

---

### `Start-Restore.ps1`

Restores a backup set to a specified destination.

**Syntax:**
```powershell
.\windows\Start-Restore.ps1 [-ConfigPath <string>] -Destination <string>
                             [-BackupSet <string>] [-SourceSubPath <string>]
                             [-DryRun] [-Force]
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-ConfigPath` | String | No | `config\windows-backup.json` | Path to the populated JSON configuration file |
| `-Destination` | String | **Yes** | - | Absolute path to restore files to |
| `-BackupSet` | String | No | Most recent | Name of the backup set to restore from |
| `-SourceSubPath` | String | No | All subdirs | Restrict restoration to a specific subdirectory within the backup set |
| `-DryRun` | Switch | No | Off | Validate the restoration plan without copying files |
| `-Force` | Switch | No | Off | Allow restoration into a non-empty destination |

**Examples:**

```powershell
# Dry-run restoration to a test location
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination D:\RestoreTest -DryRun

# Full restoration from most recent backup set
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination D:\RestoreTest

# Restore a specific backup set
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -BackupSet WINSRV01_2025-06-15_0200 -Destination D:\RestoreTest

# Partial restoration - one source path only
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -SourceSubPath "C__Users_Administrator_Documents" -Destination D:\RestoreTest

# Restore to original location (disaster recovery)
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination C:\Users\Administrator\Documents -Force
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Restoration completed and post-restore verification passed |
| 1 | Restoration completed but post-restore verification found issues |
| 2 | Fatal error - restoration aborted before any files copied |

**Requires:** Administrator session

---

### `Set-RetentionPolicy.ps1`

Enforces backup retention by purging backup sets older than the
configured window.

**Syntax:**
```powershell
.\windows\Set-RetentionPolicy.ps1 [-ConfigPath <string>] [-Force]
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-ConfigPath` | String | No | `config\windows-backup.json` | Path to the populated JSON configuration file |
| `-Force` | Switch | No | Off | Perform actual deletions. Without this flag, the script runs as a dry run unless `dry_run_retention_by_default` is `false` in the configuration |

**Examples:**

```powershell
# Preview what would be purged (dry run)
.\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json

# Enforce retention and delete eligible backup sets
.\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json -Force
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Retention enforcement completed (including dry runs) |
| 1 | One or more deletions failed |
| 2 | Fatal error - configuration or destination invalid |

**Requires:** Administrator session

---

### `New-BackupReport.ps1`

Generates a structured report from backup and verification log data.

**Syntax:**
```powershell
.\windows\New-BackupReport.ps1 [-ConfigPath <string>] [-BackupSet <string>] [-OutputPath <string>]
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-ConfigPath` | String | No | `config\windows-backup.json` | Path to the populated JSON configuration file |
| `-BackupSet` | String | No | Most recent | Name of the backup set to report on |
| `-OutputPath` | String | No | Configured `report_output_directory` | Override the report output directory for this run |

**Examples:**

```powershell
# Generate a report for the most recent backup set
.\windows\New-BackupReport.ps1 -ConfigPath .\config\windows-backup.json

# Generate a report for a specific backup set
.\windows\New-BackupReport.ps1 -ConfigPath .\config\windows-backup.json -BackupSet WINSRV01_2025-06-15_0200

# Generate a report to a custom output path
.\windows\New-BackupReport.ps1 -ConfigPath .\config\windows-backup.json -OutputPath C:\Temp\Reports
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Report generated with complete data |
| 1 | Report generated but some data was missing (partial report) |
| 2 | Fatal error - no log data found; no report generated |

---

## Linux Scripts

All Linux scripts accept `--config` as their primary flag. All scripts
require Bash 4.0 or later. Scripts that access restricted source paths
require `sudo`.

---

### `backup.sh`

Executes a backup run for all configured source paths.

**Syntax:**
```bash
./linux/backup.sh --config <path> [--dry-run]
```

**Flags:**

| Flag | Required | Description |
|---|---|---|
| `--config <path>` | Yes | Path to the populated configuration file |
| `--dry-run` | No | Log intended actions without executing rsync |

**Examples:**

```bash
# Standard backup run
./linux/backup.sh --config config/linux-backup.conf

# Validate configuration without copying files
./linux/backup.sh --config config/linux-backup.conf --dry-run

# Run with elevated privileges for system paths
sudo ./linux/backup.sh --config config/linux-backup.conf
```

**Expected output (success):**
```
=== backup v1.0.0 ===
[INFO] Backup run started
[INFO] Previous snapshot found for incremental linking
[INFO] Snapshot directory created
[INFO] Starting rsync
[INFO] rsync completed successfully
[INFO] Manifest generated
--- Run Summary ---
Status          : SUCCESS
Snapshot        : RHEL9-SRV01_2025-06-15_0200
Sources Total   : 3
Sources Success : 3
Sources Failed  : 0
Duration        : 38s
Log File        : /mnt/backups/logs/backup_2025-06-15_0200.json
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | All sources backed up successfully |
| 1 | One or more sources failed - partial backup |
| 2 | Fatal error - no files copied |

---

### `verify-backup.sh`

Verifies a completed snapshot against its source paths.

**Syntax:**
```bash
./linux/verify-backup.sh --config <path> [--snapshot <name>]
```

**Flags:**

| Flag | Required | Description |
|---|---|---|
| `--config <path>` | Yes | Path to the populated configuration file |
| `--snapshot <name>` | No | Snapshot name to verify. Defaults to most recent. |

**Examples:**

```bash
# Verify the most recent snapshot
./linux/verify-backup.sh --config config/linux-backup.conf

# Verify a specific snapshot
./linux/verify-backup.sh --config config/linux-backup.conf --snapshot RHEL9-SRV01_2025-06-15_0200
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | All checks passed |
| 1 | One or more checks failed |
| 2 | Fatal error - configuration invalid or snapshot not found |

---

### `restore.sh`

Restores a snapshot to a specified destination.

**Syntax:**
```bash
./linux/restore.sh --config <path> --destination <path>
                   [--snapshot <name>] [--source-subdir <name>]
                   [--dry-run] [--force]
```

**Flags:**

| Flag | Required | Description |
|---|---|---|
| `--config <path>` | Yes | Path to the populated configuration file |
| `--destination <path>` | Yes | Absolute path to restore files to |
| `--snapshot <name>` | No | Snapshot to restore from. Defaults to most recent. |
| `--source-subdir <name>` | No | Restrict restoration to a specific snapshot subdirectory |
| `--dry-run` | No | Validate the restoration plan without copying files |
| `--force` | No | Allow restoration into a non-empty destination |

**Examples:**

```bash
# Dry-run restoration to a test location
./linux/restore.sh --config config/linux-backup.conf --destination /tmp/restore-test --dry-run

# Full restoration from most recent snapshot
./linux/restore.sh --config config/linux-backup.conf --destination /tmp/restore-test

# Restore a specific snapshot
./linux/restore.sh --config config/linux-backup.conf --snapshot RHEL9-SRV01_2025-06-15_0200 --destination /tmp/restore-test

# Partial restoration - one source subdirectory only
./linux/restore.sh --config config/linux-backup.conf --source-subdir home_admin --destination /tmp/restore-test

# Restore to original location (disaster recovery)
sudo ./linux/restore.sh --config config/linux-backup.conf --destination /home/admin --force
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Restoration completed and post-restore verification passed |
| 1 | Restoration completed but post-restore verification found issues |
| 2 | Fatal error - restoration aborted before any files copied |

---

### `enforce-retention.sh`

Enforces backup retention by purging snapshots older than the configured
window.

**Syntax:**
```bash
./linux/enforce-retention.sh --config <path> [--force]
```

**Flags:**

| Flag | Required | Description |
|---|---|---|
| `--config <path>` | Yes | Path to the populated configuration file |
| `--force` | No | Perform actual deletions. Without this flag, the script runs as a dry run unless `DRY_RUN_RETENTION_BY_DEFAULT` is `false` in the configuration |

**Examples:**

```bash
# Preview what would be purged (dry run)
./linux/enforce-retention.sh --config config/linux-backup.conf

# Enforce retention and delete eligible snapshots
./linux/enforce-retention.sh --config config/linux-backup.conf --force
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Retention enforcement completed (including dry runs) |
| 1 | One or more deletions failed |
| 2 | Fatal error - configuration or destination invalid |

---

### `generate-report.sh`

Generates a structured report from backup and verification log data.

**Syntax:**
```bash
./linux/generate-report.sh --config <path> [--snapshot <name>] [--output <path>]
```

**Flags:**

| Flag | Required | Description |
|---|---|---|
| `--config <path>` | Yes | Path to the populated configuration file |
| `--snapshot <name>` | No | Snapshot to report on. Defaults to most recent. |
| `--output <path>` | No | Override the report output directory for this run |

**Examples:**

```bash
# Generate a report for the most recent snapshot
./linux/generate-report.sh --config config/linux-backup.conf

# Generate a report for a specific snapshot
./linux/generate-report.sh --config config/linux-backup.conf --snapshot RHEL9-SRV01_2025-06-15_0200

# Generate a report to a custom output path
./linux/generate-report.sh --config config/linux-backup.conf --output /tmp/reports
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Report generated with complete data |
| 1 | Report generated but some data was missing (partial report) |
| 2 | Fatal error - no log data found; no report generated |

---

## Cross-Platform Notes

| Topic | Windows | Linux |
|---|---|---|
| Configuration file | `config\windows-backup.json` | `config/linux-backup.conf` |
| Backup set / snapshot naming | `{prefix}_{yyyy-MM-dd}_{HHmm}` | `{label}_{yyyy-MM-dd}_{HHmm}` |
| Default config parameter | `-ConfigPath` | `--config` |
| Elevated execution | Run PowerShell as Administrator | Run with `sudo` |
| Dry-run flag | `-DryRun` | `--dry-run` |
| Force flag | `-Force` | `--force` |
| Log format | JSON (one entry per line) | JSON (one entry per line) |

