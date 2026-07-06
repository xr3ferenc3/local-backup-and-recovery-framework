# Changelog

All notable changes to this project are documented in this file.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and
the format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

Changes staged for the next release are tracked here during active development.

---

## [1.0.0] - 2026-07-06

### Added

#### Repository Foundation
- `.gitignore` with explicit suppression rules for live config files, logs,
  runtime output, credentials, and editor artifacts
- `LICENSE` - MIT license
- `README.md` - full project overview, quick start, structure reference,
  and operational philosophy

#### Configuration Layer
- `config/windows-backup.example.json` - fully documented example configuration
  file for Windows backup operations, with inline `_comment` keys explaining
  every field, its purpose, acceptable values, and default rationale
- `config/linux-backup.example.conf` - fully documented example configuration
  file for Linux backup operations, shell-sourceable key-value format with
  inline comments for every variable

#### Windows Scripts
- `windows/Invoke-Backup.ps1` - robocopy-based backup with VSS shadow copy
  support, structured JSON logging, config-file-driven operation, SHA256
  manifest generation, and SMTP failure notification
- `windows/Test-BackupIntegrity.ps1` - post-backup integrity verification via
  file count comparison, total size comparison within a configurable tolerance,
  and SHA256 spot-check hashing against the backup manifest
- `windows/Start-Restore.ps1` - guided restoration with pre-restore validation,
  destination conflict protection, dry-run mode, `-Force` override for
  non-empty destinations, and post-restore file count and hash verification
- `windows/Set-RetentionPolicy.ps1` - automated purge of backup sets exceeding
  a configurable retention window, with a hard minimum-sets floor, dry-run
  by default, and full deletion audit logging
- `windows/New-BackupReport.ps1` - aggregates backup execution and integrity
  verification log data into a structured Markdown or JSON report suitable
  for tickets, audits, and operational records

#### Linux Scripts
- `linux/backup.sh` - rsync-based incremental backup using hard-link snapshots
  via `--link-dest`, structured JSON logging, config-file-driven operation,
  SHA256 manifest generation, and SMTP failure notification
- `linux/verify-backup.sh` - post-backup integrity verification via file count
  comparison, apparent size comparison within a configurable tolerance, and
  SHA256 spot-check hashing against the snapshot manifest
- `linux/restore.sh` - guided restoration with pre-restore validation,
  destination conflict protection, dry-run mode, `--force` override for
  non-empty destinations, and post-restore file count and hash verification
- `linux/enforce-retention.sh` - automated purge of snapshots exceeding a
  configurable retention window, with a hard minimum-snapshots floor,
  path-safety guard against deletion outside the destination root, dry-run
  by default, and full deletion audit logging
- `linux/generate-report.sh` - aggregates backup execution and integrity
  verification log data into a structured Markdown or JSON report suitable
  for tickets, audits, and operational records

#### Documentation
- `docs/architecture-overview.md` - component map, data flow diagram,
  shared concept cross-reference, and "where to go next" navigation table
- `docs/threat-model.md` - explicit documentation of what this framework
  protects against, what it does not protect against, trust boundaries,
  and a recommended minimum security posture
- `docs/backup-strategy.md` - strategic rationale for backup scope,
  frequency, retention defaults, open-file handling, the hard-link
  incremental model, and explicit identification of where foundational
  book recommendations are outdated
- `docs/windows-setup-guide.md` - step-by-step Windows Server 2022 setup
  covering prerequisites, VSS verification, destination preparation,
  configuration, dry-run validation, live backup, verification, reporting,
  restoration testing, and scheduling
- `docs/linux-setup-guide.md` - step-by-step RHEL 9 setup covering
  prerequisites, rsync installation, permission validation, destination
  preparation, configuration, dry-run validation, live backup, verification,
  reporting, restoration testing, and scheduling
- `docs/restoration-runbook.md` - incident quick path for actual data loss
  events, routine restoration testing procedures, partial restoration
  guidance, disaster recovery scenario, and restoration failure
  troubleshooting table
- `docs/retention-policy.md` - retention model explanation, two-setting
  interaction with worked example and edge cases, storage growth
  expectations per platform, purge irreversibility documentation, and
  verification guidance
- `docs/troubleshooting.md` - symptom-first failure mode reference
  organised by script, covering all ten scripts on both platforms with
  causes and resolution steps for each documented failure mode
- `docs/command-reference.md` - complete syntax, parameter tables, usage
  examples, expected output, and exit code reference for all ten scripts
  across both platforms
- `docs/scheduling-guide.md` - Task Scheduler setup for Windows using
  `schtasks`, cron setup for Linux, recommended timing and conflict
  avoidance, verification of scheduled execution, and monitoring discipline

#### Checklists
- `checklists/pre-backup-checklist.md` - printable pre-run checklist
  covering destination storage, source path validation, VSS state,
  configuration currency, and system state
- `checklists/post-backup-checklist.md` - printable post-run checklist
  covering exit code confirmation, log review, manifest verification,
  integrity verification execution, report generation, and storage review
- `checklists/restoration-checklist.md` - printable restoration checklist
  covering incident assessment, backup set selection, pre-restore
  validation, dry-run execution, live restoration, post-restore
  verification, and sign-off for both routine tests and actual incidents
- `checklists/monthly-review-checklist.md` - printable monthly operational
  review checklist covering backup run continuity, storage trend review,
  retention verification and enforcement, required restoration test,
  scheduling confirmation, and configuration currency review

#### Sample Output
- `output/sample-windows-backup-report.json` - representative JSON output
  from a completed Windows backup and integrity verification run, including
  per-source file count and size detail and per-file spot-check hash results
- `output/sample-linux-backup-report.json` - representative JSON output
  from a completed Linux backup and integrity verification run, accurately
  reflecting the shell-constructed JSON format produced by the Linux scripts

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