# Scheduling Guide

This document covers how to automate backup, verification, retention, and
reporting using native OS scheduling on Windows Server 2022 (Task
Scheduler) and RHEL 9 (cron). It includes recommended timing, conflict
avoidance, and guidance on confirming that scheduled tasks are running
correctly.

Manual execution is appropriate during initial setup and testing only.
In any production context, backup automation must be scheduled - a backup
process that depends on a human remembering to run it will eventually
fail silently.

---

## Recommended Schedule

The following schedule reflects standard practice for a daily backup
workflow in an SMB environment. Adjust timing to suit your environment's
activity patterns and maintenance windows.

| Task | Recommended time | Notes |
|---|---|---|
| Backup | 02:00 daily | Run during the lowest-activity window. Adjust if your environment has overnight jobs that run at 02:00. |
| Verification | 02:30 daily | Run after backup. Allow at least 30 minutes after backup start; adjust if your backup regularly takes longer. |
| Report generation | 03:00 daily | Run after verification completes. |
| Retention enforcement | 03:30 Sunday | Weekly is sufficient. Running retention daily adds no value for a daily backup cadence and introduces unnecessary deletion risk. |

**Conflict avoidance:** The single most common scheduling mistake is
running verification or retention concurrently with an active backup run.
Stagger tasks to ensure backup is complete before dependent tasks start.
If your backup regularly takes more than 30 minutes, adjust the
verification start time accordingly.

---

## Windows: Task Scheduler

All Windows scripts require an elevated session. Task Scheduler must be
configured to run the tasks as an account with local Administrator or
Backup Operator privileges.

### Creating tasks from the command line (recommended)

The `schtasks` command allows Task Scheduler entries to be created from
an elevated PowerShell session without navigating the GUI. This approach
is reproducible, documentable, and auditable.

Open PowerShell as Administrator before running any of the following
commands.

---

#### Task 1: Daily Backup

```powershell
schtasks /create /tn "LocalBackup\DailyBackup" `
    /tr "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File 'C:\Path\To\local-backup-and-recovery-framework\windows\Invoke-Backup.ps1' -ConfigPath 'C:\Path\To\local-backup-and-recovery-framework\config\windows-backup.json'" `
    /sc DAILY /st 02:00 `
    /ru SYSTEM `
    /rl HIGHEST `
    /f
```

Replace `C:\Path\To\local-backup-and-recovery-framework` with the
absolute path to the repository on your system throughout all commands
below.

**Why `/ru SYSTEM`:** The SYSTEM account has local Administrator
privileges and does not require storing a user password in the scheduled
task. This is the recommended account for automated system tasks on
Windows Server. If your backup sources include network paths that require
specific credentials, use a dedicated service account instead.

**Why `/rl HIGHEST`:** Required to satisfy the
`#Requires -RunAsAdministrator` constraint in the backup and restore
scripts.

---

#### Task 2: Daily Verification

```powershell
schtasks /create /tn "LocalBackup\DailyVerification" `
    /tr "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File 'C:\Path\To\local-backup-and-recovery-framework\windows\Test-BackupIntegrity.ps1' -ConfigPath 'C:\Path\To\local-backup-and-recovery-framework\config\windows-backup.json'" `
    /sc DAILY /st 02:30 `
    /ru SYSTEM `
    /rl HIGHEST `
    /f
```

---

#### Task 3: Daily Report

```powershell
schtasks /create /tn "LocalBackup\DailyReport" `
    /tr "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File 'C:\Path\To\local-backup-and-recovery-framework\windows\New-BackupReport.ps1' -ConfigPath 'C:\Path\To\local-backup-and-recovery-framework\config\windows-backup.json'" `
    /sc DAILY /st 03:00 `
    /ru SYSTEM `
    /rl HIGHEST `
    /f
```

---

#### Task 4: Weekly Retention

```powershell
schtasks /create /tn "LocalBackup\WeeklyRetention" `
    /tr "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File 'C:\Path\To\local-backup-and-recovery-framework\windows\Set-RetentionPolicy.ps1' -ConfigPath 'C:\Path\To\local-backup-and-recovery-framework\config\windows-backup.json' -Force" `
    /sc WEEKLY /d SUN /st 03:30 `
    /ru SYSTEM `
    /rl HIGHEST `
    /f
```

Note that `-Force` is included in this scheduled task definition. In
an automated context, the dry-run default is not appropriate - the
retention task exists to perform actual deletion on schedule. Confirm
your retention configuration is correct before this task's first
automated run by executing the dry-run check manually first:

```powershell
.\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json
```

---

### Verifying scheduled tasks are configured correctly

**List all tasks in the LocalBackup folder:**
```powershell
schtasks /query /tn "LocalBackup" /fo LIST /v
```

**Confirm last run result for a specific task:**
```powershell
schtasks /query /tn "LocalBackup\DailyBackup" /fo LIST /v | Select-String "Last Run|Last Result"
```

A `Last Result` of `0` indicates success. Any non-zero value indicates
the task did not complete successfully. Cross-reference with the script's
JSON log file to diagnose the failure.

**Run a task immediately to confirm it executes correctly:**
```powershell
schtasks /run /tn "LocalBackup\DailyBackup"
```

Wait for completion, then review the log file to confirm exit code 0.

---

### Removing scheduled tasks

```powershell
schtasks /delete /tn "LocalBackup\DailyBackup" /f
schtasks /delete /tn "LocalBackup\DailyVerification" /f
schtasks /delete /tn "LocalBackup\DailyReport" /f
schtasks /delete /tn "LocalBackup\WeeklyRetention" /f
```

---

## Linux: cron

All Linux backup tasks should run as `root` or a dedicated service
account with `sudo` access, to ensure read access to all configured
source paths.

### Adding cron entries

Open the root crontab:
```bash
sudo crontab -e
```

Add the following entries. Replace `/path/to` with the absolute path to
the repository on your system throughout all entries below.

```cron
# =============================================================================
# Local Backup and Recovery Framework - cron schedule
# =============================================================================
#
# Format: minute hour day month weekday command
#
# All paths must be absolute. cron does not inherit the user's PATH or
# working directory. Scripts are called with the full path to the
# repository and the full path to the config file.
#
# Output from cron jobs is mailed to root by default. Since this framework
# writes structured logs, stdout/stderr are redirected to the log directory
# to avoid cron mail accumulation. Adjust the redirect path if needed.

# Daily backup - 02:00
0 2 * * * /path/to/local-backup-and-recovery-framework/linux/backup.sh --config /path/to/local-backup-and-recovery-framework/config/linux-backup.conf >> /mnt/backups/logs/cron-backup.log 2>&1

# Daily verification - 02:30
30 2 * * * /path/to/local-backup-and-recovery-framework/linux/verify-backup.sh --config /path/to/local-backup-and-recovery-framework/config/linux-backup.conf >> /mnt/backups/logs/cron-verify.log 2>&1

# Daily report - 03:00
0 3 * * * /path/to/local-backup-and-recovery-framework/linux/generate-report.sh --config /path/to/local-backup-and-recovery-framework/config/linux-backup.conf >> /mnt/backups/logs/cron-report.log 2>&1

# Weekly retention - Sunday 03:30
# --force is included here intentionally. Confirm retention configuration
# is correct with a manual dry run before this entry takes effect.
30 3 * * 0 /path/to/local-backup-and-recovery-framework/linux/enforce-retention.sh --config /path/to/local-backup-and-recovery-framework/config/linux-backup.conf --force >> /mnt/backups/logs/cron-retention.log 2>&1
```

Save and exit the editor. cron will install the updated crontab
automatically.

---

### Critical cron configuration requirements

**Use absolute paths for everything.** cron does not inherit your shell's
`PATH` or `HOME` environment. A script that works interactively but fails
under cron almost always fails because a command or file path is relative
rather than absolute.

Verify that the scripts are accessible at the paths you intend to use:
```bash
ls -la /path/to/local-backup-and-recovery-framework/linux/backup.sh
```

**Confirm execute permissions are set:**
```bash
ls -la /path/to/local-backup-and-recovery-framework/linux/*.sh
```
Every script must show `x` in the permission bits.

**Redirect stdout and stderr.** By default, cron mails any output from
jobs to the local root user. For jobs that run daily, this creates mail
accumulation that is rarely reviewed. Redirect to the log directory
instead, as shown in the crontab above.

---

### Verifying cron jobs are running correctly

**Confirm the crontab is installed:**
```bash
sudo crontab -l
```

**Check the cron log redirect files after the scheduled run time:**
```bash
cat /mnt/backups/logs/cron-backup.log
cat /mnt/backups/logs/cron-verify.log
```

**Check the structured JSON log for the most recent backup run:**
```bash
ls -lt /mnt/backups/logs/backup_*.json | head -n 3
```
The most recent file's modification time should match the last scheduled
run time. If the file is older than expected, the cron job may not have
run.

**Check the system cron log:**
```bash
sudo grep CRON /var/log/cron | tail -n 20
```
Entries show when cron fired each job. If a job is present in the cron
log but its output log shows an error, the script ran but failed - review
the JSON log for the specific failure.

**Test a cron entry manually before its first scheduled run:**
```bash
sudo /path/to/local-backup-and-recovery-framework/linux/backup.sh --config /path/to/local-backup-and-recovery-framework/config/linux-backup.conf
echo "Exit code: $?"
```
Run the exact command from the crontab entry manually (as root or via
sudo), confirm exit code 0, and review the log output before relying
on the cron schedule.

---

### Removing cron entries

Open the root crontab and delete the relevant lines:
```bash
sudo crontab -e
```

Or remove all cron entries for root (use with caution if other tasks are
scheduled):
```bash
sudo crontab -r
```

---

## Monitoring Scheduled Execution

Scheduling a task is not the same as knowing it ran. The following
operational habit is required to catch silent scheduling failures before
they result in an undetected gap in backup coverage.

**Include in your monthly review checklist:**
1. Confirm the most recent backup log file timestamp matches the expected
   schedule (should be within the last 24 hours for a daily job).
2. Confirm the most recent backup log shows `"status":"SUCCESS"` or
   `STATUS: SUCCESS`.
3. Confirm the most recent verification log shows `PASS`.
4. Confirm the most recent retention log shows a run occurred within the
   last 7 days.

These checks are included in `checklists/monthly-review-checklist.md`.

If `notify_on_failure` / `NOTIFY_ON_FAILURE` is configured, a single
failed backup run will trigger a notification. However, this is not a
substitute for periodic human review - a notification system that is
never tested is an assumption, not a mechanism.

---

## Related Documentation

| Topic | Document |
|---|---|
| Script syntax and parameters | `command-reference.md` |
| Setup prerequisites | `windows-setup-guide.md`, `linux-setup-guide.md` |
| What to check monthly | `checklists/monthly-review-checklist.md` |
| Diagnosing a failed scheduled run | `troubleshooting.md` |