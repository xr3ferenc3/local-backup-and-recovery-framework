# Retention Policy

This document explains how retention works in this framework, how to
configure it correctly, and the operational risks of misconfiguration.
Retention is destructive by nature - read this in full before running the
retention scripts with `-Force` / `--force` for the first time in any
environment.

---

## What Retention Enforcement Does

Over time, every backup set or snapshot consumes disk space, and a
backup destination with no retention policy eventually fills the
destination volume, causing the next backup run to fail at the worst
possible moment - often during an actual incident, when a fresh backup is
most needed.

The retention scripts (`Set-RetentionPolicy.ps1` on Windows,
`enforce-retention.sh` on Linux) remove backup sets or snapshots that
exceed a configured age, while always preserving a minimum number of
recent sets regardless of age.

---

## The Two Governing Settings

### `retain_days` / `RETAIN_DAYS`

The age threshold, in days, beyond which a backup set or snapshot becomes
eligible for deletion. Age is calculated from the timestamp embedded in
the backup set or snapshot's directory name - not filesystem metadata,
which can be altered by copy operations, antivirus scans, or storage
migrations.

**Default: 30 days.**

This default reflects a balance between recovery window and storage
consumption, documented in full in `backup-strategy.md`. A shorter window
reduces storage use but narrows the window in which a slowly-discovered
problem can still be recovered from. A longer window does the opposite.

### `minimum_sets_to_keep` / `MINIMUM_SNAPSHOTS_TO_KEEP`

A hard floor on the number of backup sets or snapshots that are **never**
deleted, regardless of how old they are.

**Default: 3.**

This setting exists to protect against a specific failure scenario: a
system that goes offline, or whose backup job silently fails, for longer
than `retain_days`. Without this floor, age-based retention alone could
purge every backup set on the next successful run, leaving zero recovery
points at exactly the moment recovery becomes necessary.

---

## How the Two Settings Interact

Retention evaluation works in two passes:

1. **The most recent `minimum_sets_to_keep` backup sets are always
   protected**, regardless of their age. They are never even evaluated
   against `retain_days`.

2. **Of the remaining backup sets** (everything beyond the protected
   floor), any set older than `retain_days` is eligible for purge. Sets
   within the age window are retained.

### Worked example

Configuration: `retain_days = 30`, `minimum_sets_to_keep = 3`

Existing backup sets, newest first, with their age:

| Set | Age (days) | Outcome |
|---|---|---|
| Set A | 1 | Retained (within protected floor) |
| Set B | 8 | Retained (within protected floor) |
| Set C | 15 | Retained (within protected floor) |
| Set D | 35 | **Purged** (outside floor, exceeds 30-day window) |
| Set E | 45 | **Purged** (outside floor, exceeds 30-day window) |
| Set F | 60 | **Purged** (outside floor, exceeds 30-day window) |

Sets A, B, and C are protected purely by their position in the
minimum-floor - note that Set C, at 15 days, would also have survived
purely on age, but is counted toward the floor first either way.

### Edge case: all backup sets exceed the age threshold

If a system has been offline for 90 days and only 3 backup sets exist,
all 3 older than `retain_days`:

Total sets present (3) <= minimum_sets_to_keep (3)
→ No purge candidates. All 3 sets are retained.

This is the floor working as designed - it prevents the worst-case
scenario of zero recoverable backup sets.

---

## Dry-Run by Default

Both retention scripts default to dry-run mode. This is governed by:

- Windows: `retention.dry_run_retention_by_default` in
  `windows-backup.json`
- Linux: `DRY_RUN_RETENTION_BY_DEFAULT` in `linux-backup.conf`

**Both default to `true` in the example configuration files.**

In dry-run mode, the script logs every action it *would* take -
including which backup sets it would delete and how much space it would
reclaim - without deleting anything. This allows safe review before any
destructive action occurs.

To perform actual deletion, the operator must explicitly pass `-Force`
(Windows) or `--force` (Linux) on the command line. Passing this flag
overrides the config default for that run only; it does not change the
configuration file.

**Recommended practice for any new environment:** run the retention
script without `-Force` / `--force` first. Review the dry-run output
carefully. Only then run again with the flag once you are confident the
purge candidates are correct.

---

## Choosing Values for Your Environment

### Factors to consider for `retain_days`

| Factor | Effect on recommended value |
|---|---|
| How quickly are problems typically noticed? | Slower discovery → longer retention needed |
| Available destination storage | Less storage → shorter retention required |
| Compliance or audit requirements | May mandate a specific minimum retention period - check your organization's policy |
| Rate of data change | High-churn data may need shorter retention to manage storage; low-churn data can afford longer retention cheaply |

### Factors to consider for `minimum_sets_to_keep` / `MINIMUM_SNAPSHOTS_TO_KEEP`

| Factor | Effect on recommended value |
|---|---|
| Backup frequency | Daily backups with a floor of 3 protect roughly the last 3 days no matter what; weekly backups with the same floor protect roughly 3 weeks |
| Tolerance for "system offline" scenarios | Higher tolerance for extended offline periods → higher floor value |
| Storage cost of protected sets | Each protected set consumes space regardless of age - balance against available storage |

**Minimum recommended value: 3.** A floor of 1 or 2 provides very little
protection against the offline-system failure scenario described above.

---

## Storage Growth Expectations

### Windows

Each backup set produced by `Invoke-Backup.ps1` is a **full copy** of all
configured source paths - robocopy does not implement hard-link
deduplication between backup sets in this framework's implementation
(see `backup-strategy.md` for why). Storage consumption grows roughly
linearly with the number of retained backup sets multiplied by total
source data size.

**Planning guidance:** estimate destination storage needs as
`(total source data size) × (minimum_sets_to_keep, at minimum)`, with
additional headroom for sets retained within the `retain_days` window
beyond the floor.

### Linux

Snapshots produced by `backup.sh` use hard-link incremental backup via
`rsync --link-dest`. Only new or changed files since the previous
snapshot consume additional disk space; unchanged files are hard-linked
and consume no additional space.

**Planning guidance:** storage growth is proportional to the **rate of
change** in source data, not the total source data size multiplied by
the number of snapshots. A dataset with low daily change can retain many
snapshots cheaply. Monitor actual growth using `du -sh` against the
destination root periodically and adjust `RETAIN_DAYS` if growth exceeds
available storage.

---

## What Happens to a Purged Backup Set

Deletion via the retention scripts is a standard filesystem delete
(`Remove-Item -Recurse -Force` on Windows, `rm -rf` on Linux) - it is
**not** a secure wipe and **not** reversible through this framework. Once
a backup set is purged:

- It cannot be recovered through this framework
- Depending on the underlying filesystem and storage media, the data may
  be forensically recoverable through specialized tools until the space
  is overwritten - do not rely on this for sensitive data destruction
  requirements
- If secure deletion is a compliance requirement for your data, this
  framework's retention scripts are not sufficient on their own; consult
  your organization's data destruction policy

---

## Verifying Retention Is Working Correctly

Include this check in `checklists/monthly-review-checklist.md` reviews:

**Windows:**
```powershell
# List current backup sets with age
Get-ChildItem -Path "D:\Backups" -Directory |
    Where-Object { $_.Name -like "PREFIX_*" } |
    Select-Object Name, @{N='AgeDays';E={[math]::Round(((Get-Date) - $_.CreationTime).TotalDays,1)}} |
    Sort-Object AgeDays
```

**Linux:**
```bash
find /mnt/backups -maxdepth 1 -type d -name "LABEL_*" -printf '%f %TY-%Tm-%Td\n' | sort
```

Confirm the oldest retained set is within expectations given your
`retain_days` / `RETAIN_DAYS` and `minimum_sets_to_keep` /
`MINIMUM_SNAPSHOTS_TO_KEEP` configuration.

---

## Related Documentation

| Topic | Document |
|---|---|
| Strategic rationale for the 30-day default | `backup-strategy.md` |
| Risk of misconfigured retention | `threat-model.md` |
| Restoration procedures (retention affects which sets are available) | `restoration-runbook.md` |
| Script syntax reference | `command-reference.md` |