# Post-Backup Checklist

Complete this checklist immediately after a backup script run completes
in a production context. It confirms the backup is usable, generates the
required audit record, and identifies any issues before they become
problems.

This checklist is a direct continuation of `pre-backup-checklist.md`.
Do not skip it because the backup script reported success — the script
reporting success and the backup being genuinely usable for restoration
are two different things.

**Date:** ________________________

**Operator:** ________________________

**Host / Environment:** ________________________

**Backup Set / Snapshot Name:** ________________________

**Backup Script Exit Code:** ________________________

---

## Section 1: Backup Script Exit Code

- [ ] **The backup script exited with code `0`.**

  Confirm the exit code immediately after the script completes:

  Windows:
```powershell
  echo $LASTEXITCODE
```
  Linux:
```bash
  echo $?
```

  | Exit code | Meaning | Action required |
  |---|---|---|
  | 0 | All sources backed up successfully | Continue checklist |
  | 1 | One or more sources failed — partial backup | Investigate before continuing; do not rely on this backup set for critical data until failures are understood |
  | 2 | Fatal error — backup aborted | Do not continue checklist; investigate using `troubleshooting.md` and re-run the backup before the next scheduled window |

---

## Section 2: Backup Run Log Review

- [ ] **The backup log file was created for this run.**

  Windows:
```powershell
  Get-ChildItem "D:\Backups\Logs" -Filter "Invoke-Backup_*.json" |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1 -ExpandProperty FullName
```
  Linux:
```bash
  ls -lt /mnt/backups/logs/backup_*.json | head -n 1
```

  Confirm the file was created within the last hour. If no recent log
  file exists, the script may have failed before initializing logging —
  check the console output.

- [ ] **No ERROR-level entries appear in the backup log.**

  Windows:
```powershell
  Get-ChildItem "D:\Backups\Logs" -Filter "Invoke-Backup_*.json" |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1 |
      Get-Content |
      Where-Object { $_ -like '*"level":"ERROR"*' }
```
  Linux:
```bash
  grep '"level":"ERROR"' /mnt/backups/logs/backup_*.json |
      tail -n 20
```
  Expected: No output. If ERROR entries appear, record them in the
  Notes section below and refer to `troubleshooting.md`.

- [ ] **The backup set or snapshot directory was created.**

  Windows:
```powershell
  Get-ChildItem -Path "D:\Backups" -Directory |
      Sort-Object Name -Descending |
      Select-Object -First 1
```
  Linux:
```bash
  ls -ltd /mnt/backups/*/ | head -n 3
```
  Confirm the directory name matches the expected timestamp and prefix
  / label.

- [ ] **The manifest file was generated inside the backup set.**

  Windows:
```powershell
  $latest = (Get-ChildItem "D:\Backups" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
  Test-Path "$latest\backup.manifest"
```
  Linux:
```bash
  latest=$(find /mnt/backups -maxdepth 1 -type d -name "*_*" | sort -r | head -n 1)
  test -f "${latest}/backup.manifest" && echo "Manifest present" || echo "Manifest MISSING"
```
  Expected: `True` / `Manifest present`

  If the manifest is missing, the backup set can still be used for
  restoration but integrity spot-check verification will not be
  available. Re-run the backup to generate a new set with a manifest
  before relying on this set.

---

## Section 3: Integrity Verification

- [ ] **Run the integrity verification script and confirm PASS.**

  Windows:
```powershell
  .\windows\Test-BackupIntegrity.ps1 -ConfigPath .\config\windows-backup.json
```
  Linux:
```bash
  ./linux/verify-backup.sh --config config/linux-backup.conf
```

  Record the result:

  **Verification status:** ________________________ (PASS / FAIL)

  **Checks performed:** ________________________

  **Checks passed:** ________________________

  If any check fails, do not treat this backup set as confirmed
  reliable for restoration. Refer to the `Verification Failures`
  section in `troubleshooting.md` before proceeding.

---

## Section 4: Report Generation

- [ ] **Generate the backup report and confirm it is complete.**

  Windows:
```powershell
  .\windows\New-BackupReport.ps1 -ConfigPath .\config\windows-backup.json
```
  Linux:
```bash
  ./linux/generate-report.sh --config config/linux-backup.conf
```

  Confirm the exit code is `0` (complete report) rather than `1`
  (partial report).

  **Report file path:** ________________________

  **Report exit code:** ________________________ (0 = complete, 1 = partial)

- [ ] **Open the report and confirm both sections are populated.**

  A complete report contains:
  - Backup Execution section with a `PASS` or `ATTENTION REQUIRED`
    status
  - Integrity Verification section with a `PASS` or `FAIL` status

  If either section shows `No data found`, the corresponding log or
  result file is missing. Refer to `troubleshooting.md`.

---

## Section 5: Destination Storage Review

- [ ] **Remaining free space on the destination volume is within
  acceptable bounds.**

  Windows:
```powershell
  Get-PSDrive D | Select-Object Used, Free
```
  Linux:
```bash
  df -h /mnt/backups
```

  If free space has fallen below 20% of total destination volume
  capacity, consider running the retention script or provisioning
  additional storage before the next backup window. Do not allow the
  destination volume to fill completely — a full destination volume
  causes the next backup run to fail.

- [ ] **Log directory disk usage is within acceptable bounds.**

  Over time, log files accumulate. Confirm the log directory is not
  consuming unexpected amounts of space:

  Windows:
```powershell
  (Get-ChildItem "D:\Backups\Logs" -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB
```
  Linux:
```bash
  du -sh /mnt/backups/logs/
```

  If log storage is growing unexpectedly fast, confirm
  `log_retention_days` / `LOG_RETENTION_DAYS` is configured and
  functioning correctly.

---

## Section 6: Notification Confirmation (If Configured)

- [ ] **If `notify_on_failure` / `NOTIFY_ON_FAILURE` is configured,
  confirm no failure notification was received.**

  A failure notification received during or after the backup window is
  a finding that must be investigated before this item can be checked.
  Do not assume a notification was a false positive without reviewing
  the log.

- [ ] **If `notify_on_success` / `NOTIFY_ON_SUCCESS` is configured,
  confirm the success notification was received.**

  If no success notification was received but the script appears to
  have run, confirm the SMTP configuration is correct and the mail
  transfer agent is functional.

---

## Section 7: Final Sign-Off

- [ ] All Section 1 through 6 items checked or resolved.
- [ ] Any issues found have been documented in the Notes section below.
- [ ] If any check failed, the finding has been recorded in an incident
  or issue ticket before sign-off.

**Backup set / snapshot confirmed usable for restoration:** Yes / No

**Notes / Issues Found:**

---

**Checklist completed by:** ________________________

**Time checklist completed:** ________________________

---

*File this completed checklist with your operational records. Attach
or reference the generated report from Section 4 for a complete audit
record of this backup run.*

*If a restoration test is scheduled, proceed to
`checklists/restoration-checklist.md`.*