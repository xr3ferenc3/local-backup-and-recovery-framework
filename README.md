# Local Backup and Recovery Framework

A structured, scriptable, and fully documented backup and recovery framework
for Windows Server 2022 and RHEL 9 environments using only native OS tooling.

Designed for systems administrators in small-to-medium environments who need
a reliable, auditable backup workflow without enterprise backup software.

---

## What This Is

This repository is an operational framework, not a script collection.

Every component - scripts, configuration files, documentation, and checklists
- connects to a documented workflow. Scripts produce outputs that feed
documentation. Documentation references scripts by name. Checklists reference
both. The repository functions as a coherent operational system.

What it provides:

- Automated backup execution on Windows Server 2022 and RHEL 9
- Post-backup integrity verification using file count, size, and hash comparison
- Guided restoration with dry-run mode and post-restore verification
- Automated retention enforcement with full deletion audit logging
- Structured report generation suitable for tickets, audits, and records
- Complete operational documentation written for a junior sysadmin audience
- Printable checklists for backup runs, restoration events, and monthly review

---

## What This Is Not

This framework does not replace enterprise backup software in environments
that require it. It does not provide:

- Bare-metal or image-based system recovery
- Database-consistent backups for live SQL, Exchange, or similar workloads
- Offsite or cloud replication
- Centralised multi-host backup management
- Real-time or continuous data protection

These limitations are documented in full in
[`docs/threat-model.md`](docs/threat-model.md) and
[`docs/backup-strategy.md`](docs/backup-strategy.md).

---

## Who This Is For

This framework is designed for:

- Systems administrators managing Windows Server 2022 or RHEL 9 systems
- Environments without enterprise backup solutions (Veeam, Commvault, etc.)
- SMB IT teams that need auditable, documented backup processes
- Sysadmins who want a backup workflow they can explain, verify, and defend

---

## Platform Requirements

### Windows

| Requirement | Detail |
|---|---|
| Operating system | Windows Server 2022 (compatible with 2016 and 2019) |
| PowerShell version | 5.1 or later (built in) |
| Required tools | robocopy (built in), VSS service (built in) |
| Scheduling | Task Scheduler (built in) |
| Permissions | Local Administrator or Backup Operator group membership |

### Linux

| Requirement | Detail |
|---|---|
| Operating system | RHEL 9 (compatible with Rocky Linux 9, AlmaLinux 9) |
| Bash version | 4.0 or later (built in) |
| Required tools | rsync, sha256sum (coreutils), find (findutils) |
| Scheduling | crond (built in) |
| Permissions | Root or sudo access for system paths; standard user for user-space paths |

**Installing rsync on RHEL 9:**
```bash
sudo dnf install rsync -y
```

rsync is the only external dependency in this framework. It is available in
the default RHEL 9 package repositories and is included in virtually every
Linux environment.

---

## Quick Start

### Windows

**1. Clone the repository:**
```powershell
git clone https://github.com/YOUR-USERNAME/local-backup-and-recovery-framework.git
cd local-backup-and-recovery-framework
```

**2. Create your configuration file:**
```powershell
Copy-Item config\windows-backup.example.json config\windows-backup.json
notepad config\windows-backup.json
```

**3. Review the setup guide:**
See [`docs/windows-setup-guide.md`](docs/windows-setup-guide.md) for full
prerequisites, configuration reference, and first-run verification steps.

**4. Run your first backup:**
```powershell
.\windows\Invoke-Backup.ps1 -ConfigPath .\config\windows-backup.json
```

**5. Verify the backup:**
```powershell
.\windows\Test-BackupIntegrity.ps1 -ConfigPath .\config\windows-backup.json
```

---

### Linux

**1. Clone the repository:**
```bash
git clone https://github.com/YOUR-USERNAME/local-backup-and-recovery-framework.git
cd local-backup-and-recovery-framework
```

**2. Make scripts executable:**
```bash
chmod +x linux/*.sh
```

**3. Create your configuration file:**
```bash
cp config/linux-backup.example.conf config/linux-backup.conf
nano config/linux-backup.conf
```

**4. Review the setup guide:**
See [`docs/linux-setup-guide.md`](docs/linux-setup-guide.md) for full
prerequisites, configuration reference, and first-run verification steps.

**5. Run your first backup:**
```bash
./linux/backup.sh --config config/linux-backup.conf
```

**6. Verify the backup:**
```bash
./linux/verify-backup.sh --config config/linux-backup.conf
```

---

## Repository Structure

# Project Structure

```text
local-backup-and-recovery-framework/
│
├── .gitignore                          # Suppresses live config, logs, secrets
├── CHANGELOG.md                        # Version history and change log
├── LICENSE                             # MIT license
├── README.md                           # This file
│
├── windows/                            # Windows Server 2022 scripts
│   ├── Invoke-Backup.ps1               # Execute a backup run
│   ├── Test-BackupIntegrity.ps1        # Verify backup completeness
│   ├── Start-Restore.ps1               # Execute a guided restoration
│   ├── Set-RetentionPolicy.ps1         # Enforce retention and purge old sets
│   └── New-BackupReport.ps1            # Generate audit-ready report
│
├── linux/                              # RHEL 9 scripts
│   ├── backup.sh                       # Execute a backup run
│   ├── verify-backup.sh                # Verify backup completeness
│   ├── restore.sh                      # Execute a guided restoration
│   ├── enforce-retention.sh            # Enforce retention and purge old sets
│   └── generate-report.sh              # Generate audit-ready report
│
├── config/                             # Configuration templates
│   ├── windows-backup.example.json     # Windows configuration reference
│   └── linux-backup.example.conf       # Linux configuration reference
│
├── docs/                               # Operational documentation
│   ├── architecture-overview.md        # How all components connect
│   ├── threat-model.md                 # What this protects and what it does not
│   ├── backup-strategy.md              # Strategic rationale and design decisions
│   ├── windows-setup-guide.md          # Windows prerequisites and setup
│   ├── linux-setup-guide.md            # Linux prerequisites and setup
│   ├── restoration-runbook.md          # Full and partial restoration procedures
│   ├── retention-policy.md             # Retention model and customisation
│   ├── troubleshooting.md              # Symptom-first failure mode reference
│   ├── command-reference.md            # Script syntax and parameter reference
│   └── scheduling-guide.md             # Task Scheduler and cron integration
│
├── checklists/                         # Printable operational checklists
│   ├── pre-backup-checklist.md         # Before initiating a backup run
│   ├── post-backup-checklist.md        # After completing a backup run
│   ├── restoration-checklist.md        # During an active recovery event
│   └── monthly-review-checklist.md     # Periodic operational review
│
└── output/                             # Sample script output
    ├── sample-windows-backup-report.json
    └── sample-linux-backup-report.json
```

---

## Script Reference

### Windows Scripts

| Script | Purpose | Key Parameters |
|---|---|---|
| `Invoke-Backup.ps1` | Execute a backup run | `-ConfigPath`, `-DryRun` |
| `Test-BackupIntegrity.ps1` | Verify backup completeness | `-ConfigPath`, `-BackupSet` |
| `Start-Restore.ps1` | Execute a guided restoration | `-ConfigPath`, `-BackupSet`, `-Destination`, `-DryRun` |
| `Set-RetentionPolicy.ps1` | Purge old backup sets | `-ConfigPath`, `-WhatIf` |
| `New-BackupReport.ps1` | Generate audit-ready report | `-ConfigPath`, `-BackupSet`, `-OutputPath` |

Full syntax, examples, and expected output for each script:
[`docs/command-reference.md`](docs/command-reference.md)

---

### Linux Scripts

| Script | Purpose | Key Flags |
|---|---|---|
| `backup.sh` | Execute a backup run | `--config`, `--dry-run` |
| `verify-backup.sh` | Verify backup completeness | `--config`, `--snapshot` |
| `restore.sh` | Execute a guided restoration | `--config`, `--snapshot`, `--destination`, `--dry-run` |
| `enforce-retention.sh` | Purge old backup snapshots | `--config`, `--dry-run` |
| `generate-report.sh` | Generate audit-ready report | `--config`, `--snapshot`, `--output` |

Full syntax, examples, and expected output for each script:
[`docs/command-reference.md`](docs/command-reference.md)

---

## Documentation Index

| Document | When to read it |
|---|---|
| [`docs/architecture-overview.md`](docs/architecture-overview.md) | Start here to understand how the framework fits together |
| [`docs/threat-model.md`](docs/threat-model.md) | Before deploying - understand what this does and does not protect |
| [`docs/backup-strategy.md`](docs/backup-strategy.md) | Before configuring - understand the strategic decisions behind the defaults |
| [`docs/windows-setup-guide.md`](docs/windows-setup-guide.md) | When setting up on Windows Server 2022 |
| [`docs/linux-setup-guide.md`](docs/linux-setup-guide.md) | When setting up on RHEL 9 |
| [`docs/restoration-runbook.md`](docs/restoration-runbook.md) | During a recovery event or restoration test |
| [`docs/retention-policy.md`](docs/retention-policy.md) | When configuring or adjusting retention settings |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | When a script fails or produces unexpected output |
| [`docs/command-reference.md`](docs/command-reference.md) | Quick lookup for script syntax and parameters |
| [`docs/scheduling-guide.md`](docs/scheduling-guide.md) | When automating backup runs |

---

## Operational Workflow

A complete backup cycle for either platform follows this sequence:

Configure → Backup → Verify → Report → Schedule → Review → Test Restore

**Configure:** Copy the example config file, populate paths and retention
settings, review the setup guide for your platform.

**Backup:** Run the backup script. Review the log output. Confirm exit code 0.

**Verify:** Run the integrity verification script against the completed backup
set. Confirm file count, size, and hash spot-checks pass.

**Report:** Generate a structured report from the completed backup and
verification run. File the report or attach it to the relevant ticket.

**Schedule:** Automate the backup and verification steps using Task Scheduler
or cron. See the scheduling guide for recommended timing and conflict avoidance.

**Review:** Complete the monthly review checklist. Confirm retention is
enforcing correctly. Review disk trend. Confirm logs are rotating.

**Test Restore:** Perform a restoration test to a non-production destination
at least monthly. A backup that has never been restored from is an untested
assumption, not a verified capability.

---

## A Note on Restoration Testing

Most backup processes fail at the restoration step - not because the backups
were not made, but because restoration was never tested.

This framework includes a guided restoration script with dry-run mode
precisely to lower the barrier to restoration testing. The
[`docs/restoration-runbook.md`](docs/restoration-runbook.md) documents both
full and partial restoration scenarios.

**Restoration testing should be scheduled, not optional.**

The [`checklists/monthly-review-checklist.md`](checklists/monthly-review-checklist.md)
includes a restoration test as a required monthly task.

---

## Security Considerations

- Configuration files containing local paths must not be committed to version
  control. The `.gitignore` suppresses live config files by name.
- Backup destinations should have restricted permissions. Only the backup
  service account or operator should have write access.
- Backup logs may contain hostnames and file path information. Treat them
  as internal operational records, not public artifacts.
- This framework does not encrypt backup data. Encryption at the destination
  (filesystem-level or volume-level) is the operator's responsibility.
- Full security considerations are documented in
  [`docs/threat-model.md`](docs/threat-model.md).

---

## Contributing

This repository is a portfolio and operational reference project.

If you find an error, a missing failure mode, or an improvement that would
make this more useful in a real operational context, open an issue or submit
a pull request with a clear description of the problem and the proposed change.

Contributions that add complexity without operational justification will not
be merged.

---

## License

MIT License - see [`LICENSE`](LICENSE) for full terms.

This software is provided as-is. The operator is responsible for all
operational decisions, including backup scope, retention configuration,
restoration testing, and destination security.