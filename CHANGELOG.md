# Changelog

All notable changes to this project are documented in this file.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and
the format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

Changes staged for the next release are tracked here during active development.

---

## [1.0.0] - 2026-07-03

### Added

#### Repository Foundation
- `.gitignore` with explicit suppression rules for live config files, logs,
  runtime output, credentials, and editor artifacts
- `LICENSE` - MIT license
- `README.md` - full project overview, quick start, structure reference,
  and operational philosophy

#### Configuration Layer
- `config/windows-backup.example.json` - fully documented example configuration
  file for Windows backup operations
- `config/linux-backup.example.conf` - fully documented example configuration
  file for Linux backup operations

#### Windows Scripts
- `windows/Invoke-Backup.ps1` - robocopy-based backup with VSS shadow copy
  support, structured JSON logging, and config-file-driven operation
- `windows/Test-BackupIntegrity.ps1` - post-backup integrity verification via
  file count comparison, size comparison, and SHA256 spot-check hashing
- `windows/Start-Restore.ps1` - guided restoration with dry-run mode, conflict
  detection, pre-restore validation, and post-restore verification
- `windows/Set-RetentionPolicy.ps1` - automated purge of backup sets exceeding
  configurable retention window with full deletion audit logging
- `windows/New-BackupReport.ps1` - aggregates backup and verification log data
  into a structured Markdown report for tickets, audits, and records

#### Linux Scripts
- `linux/backup.sh` - rsync-based incremental backup using hard-link snapshots,
  structured JSON logging, and config-file-driven operation
- `linux/verify-backup.sh` - post-backup integrity verification via file count
  comparison, size comparison, and SHA256 spot-check hashing against manifest
- `linux/restore.sh` - guided restoration with dry-run mode, conflict detection,
  privilege validation, and post-restore verification
- `linux/enforce-retention.sh` - automated purge of backup snapshots exceeding
  configurable retention window with full deletion audit logging
- `linux/generate-report.sh` - aggregates backup and verification log data into
  a structured Markdown report for tickets, audits, and records

#### Documentation
- `docs/architecture-overview.md` - component map, data flow, and design
  rationale for the full framework
- `docs/threat-model.md` - explicit documentation of what this framework
  protects against and what it does not address
- `docs/backup-strategy.md` - strategic rationale for backup scope, frequency,
  retention, and the 3-2-1 rule in a native-tools context
- `docs/windows-setup-guide.md` - step-by-step Windows Server 2022 setup
  covering prerequisites, configuration, scheduling, and first-run verification
- `docs/linux-setup-guide.md` - step-by-step RHEL 9 setup covering
  prerequisites, permissions, cron integration, and first-run verification
- `docs/restoration-runbook.md` - full and partial restoration procedures for
  both platforms, written for use under incident conditions
- `docs/retention-policy.md` - retention model documentation, customization
  guidance, default value rationale, and misconfiguration risk
- `docs/troubleshooting.md` - symptom-first failure mode reference for every
  script on both platforms
- `docs/command-reference.md` - quick-reference syntax, parameters, examples,
  and expected output for all scripts
- `docs/scheduling-guide.md` - Task Scheduler (Windows) and cron (Linux)
  integration with timing recommendations and conflict-avoidance guidance

#### Checklists
- `checklists/pre-backup-checklist.md` - human verification steps before
  initiating a backup run
- `checklists/post-backup-checklist.md` - human verification steps after a
  completed backup run
- `checklists/restoration-checklist.md` - step-by-step restoration checklist
  for use during an active recovery event
- `checklists/monthly-review-checklist.md` - periodic operational review
  covering retention, log review, test restore, and documentation currency

#### Sample Output
- `output/sample-windows-backup-report.json` - representative output from a
  completed Windows backup and verification run
- `output/sample-linux-backup-report.json` - representative output from a
  completed Linux backup and verification run

---

## Version Numbering Reference

| Increment | When to use |
|---|---|
| MAJOR (x.0.0) | Breaking changes to script interfaces, config schema, or output format |
| MINOR (1.x.0) | New scripts, new documentation sections, or new operational capabilities |
| PATCH (1.0.x) | Bug fixes, clarifications, typo corrections, non-breaking improvements |

---

## Changelog Maintenance Rules

- Every change that affects operational behavior must be logged here
- Documentation-only changes are logged under `Changed` or `Added`
- Deprecated features are listed under `Deprecated` before removal
- Removed features are listed under `Removed` with a reason
- Security-relevant changes are listed under `Security`
- The `[Unreleased]` section is always present and always at the top
- Entries are written for a junior sysadmin audience, not a developer audience