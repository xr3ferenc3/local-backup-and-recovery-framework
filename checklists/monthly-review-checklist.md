# Monthly Review Checklist

Complete this checklist once per month. It confirms the backup framework
is operating correctly, storage is healthy, retention is enforcing as
configured, and restoration actually works.

A backup process that is never reviewed is not a backup process - it is
an assumption. This checklist is the operational discipline that
separates the two.

Schedule a fixed time each month for this review. It takes approximately
30 to 60 minutes including the restoration test. Do not defer it.

**Month / Year:** ________________________

**Reviewer:** ________________________

**Host / Environment:** ________________________

**Review Date:** ________________________

---

## Section 1: Backup Run Continuity

Confirm backups have been running successfully throughout the month
without silent failures.

- [ ] **Review backup log files for the past 30 days.**

  Confirm a log file exists for each expected backup run. A missing
  log file indicates the scheduled task or cron job did not fire, or
  the script failed before initializing logging.

  Windows - count log files from the past 30 days:
```powershell
  Get-ChildItem "D:\Backups\Logs" -Filter "Invoke-Backup_*.json" |
      Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) } |
      Measure-Object |
      Select-Object -ExpandProperty Count
```
  Linux:
```bash
  find /mnt/backups/logs -name "backup_*.json" -mtime -30 | wc -l
```
  Expected count: equal to the number of scheduled backup runs in the
  past 30 days (e.g. 30 for daily, 4 for weekly).

  **Actual count:** ________________________

  **Expected count:** ________________________

- [ ] **Confirm all backup runs in the past 30 days exited with
  status `SUCCESS`.**

  Windows:
```powershell
  Get-ChildItem "D:\Backups\Logs" -Filter "Invoke-Backup_*.json" |
      Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) } |
      ForEach-Object { Get-Content $_.FullName } |
      Where-Object { $_ -like '*"message":"Backup run complete"*' } |
      ConvertFrom-Json |
      Select-Object timestamp, status, backup_set
```
  Linux:
```bash
  grep '"message":"Backup run complete"' \
      $(find /mnt/backups/logs -name "backup_*.json" -mtime -30) 2>/dev/null |
      grep -v '"status":"SUCCESS"'
```
  Expected Linux output: no lines (all runs were SUCCESS). Any output
  indicates a run that completed with errors.

  **Any non-SUCCESS runs found:** Yes / No

  If yes, record which runs and what errors were logged:
  ---

  - [ ] **Confirm all verification runs in the past 30 days passed.**

  Windows:
```powershell
  Get-ChildItem "D:\Backups\Logs" -Filter "Test-BackupIntegrity_*.json" |
      Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) } |
      ForEach-Object { Get-Content $_.FullName } |
      Where-Object { $_ -like '*"message":"Integrity verification complete"*' } |
      ConvertFrom-Json |
      Select-Object timestamp, status
```
  Linux:
```bash
  grep '"message":"Integrity verification complete"' \
      $(find /mnt/backups/logs -name "verify-backup_*.json" -mtime -30) 2>/dev/null |
      grep -v '"status":"PASS"'
```
  Expected Linux output: no lines (all verifications passed).

  **Any FAIL verifications found:** Yes / No

---

## Section 2: Storage Review

- [ ] **Review destination volume free space and trend.**

  Windows:
```powershell
  Get-PSDrive D | Select-Object Name,
      @{N='UsedGB';E={[math]::Round($_.Used/1GB,2)}},
      @{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}},
      @{N='TotalGB';E={[math]::Round(($_.Used+$_.Free)/1GB,2)}}
```
  Linux:
```bash
  df -h /mnt/backups
```

  **Destination volume free space:** ________________________

  **Destination volume total capacity:** ________________________

  **Free space percentage:** ________________________

  If free space is below 20% of total capacity, plan storage
  expansion or reduce retention before the next backup window.

- [ ] **Review total size of all current backup sets / snapshots.**

  Windows:
```powershell
  Get-ChildItem "D:\Backups" -Directory |
      Where-Object { $_.Name -like "PREFIX_*" } |
      ForEach-Object {
          $size = (Get-ChildItem $_.FullName -Recurse -File |
              Measure-Object -Property Length -Sum).Sum
          [pscustomobject]@{
              Name    = $_.Name
              SizeGB  = [math]::Round($size/1GB, 3)
          }
      } | Sort-Object Name
```
  Linux:
```bash
  du -sh /mnt/backups/LABEL_*/ 2>/dev/null | sort -k2
```

- [ ] **Review log directory size.**

  Windows:
```powershell
  [math]::Round((Get-ChildItem "D:\Backups\Logs" -Recurse |
      Measure-Object -Property Length -Sum).Sum / 1MB, 2)
```
  Linux:
```bash
  du -sh /mnt/backups/logs/
```

  If log storage is growing unexpectedly fast, confirm
  `log_retention_days` / `LOG_RETENTION_DAYS` is configured and
  functioning. Normal log growth is a few MB per month for daily runs.

---

## Section 3: Retention Verification

- [ ] **Run the retention script in dry-run mode and review the
  output.**

  Windows:
```powershell
  .\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json
```
  Linux:
```bash
  ./linux/enforce-retention.sh --config config/linux-backup.conf
```

  Confirm:
  - The purge candidates listed are genuinely old enough to be
    removed
  - The retained sets include the minimum required number of
    recent sets
  - No unexpectedly recent sets are listed as purge candidates

  **Purge candidates identified:** ________________________

  **Retained sets count:** ________________________

- [ ] **If purge candidates are confirmed correct, run live
  retention enforcement.**

  Windows:
```powershell
  .\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json -Force
```
  Linux:
```bash
  ./linux/enforce-retention.sh --config config/linux-backup.conf --force
```

  **Space reclaimed:** ________________________

  **Sets purged:** ________________________

- [ ] **Confirm the oldest retained backup set / snapshot is within
  the expected retention window.**

  Windows:
```powershell
  Get-ChildItem "D:\Backups" -Directory |
      Where-Object { $_.Name -like "PREFIX_*" } |
      Sort-Object Name |
      Select-Object -First 1 -ExpandProperty Name
```
  Linux:
```bash
  find /mnt/backups -maxdepth 1 -type d -name "LABEL_*" | sort | head -n 1
```

  **Oldest retained set:** ________________________

  **Age of oldest retained set:** ________________________

---

## Section 4: Required Monthly Restoration Test

This section is mandatory. A backup framework without regular
restoration testing is not a verified capability - it is an
unconfirmed assumption. Completing this section once per month is
the minimum discipline required to operate this framework responsibly.

- [ ] **Select a backup set or snapshot for the test.**

  Use the second or third most recent set, not the most recent. This
  tests a set that represents realistic recovery scenario data, not
  the set that was just made.

  **Selected set for restoration test:** ________________________

- [ ] **Complete `checklists/restoration-checklist.md` for this
  test.**

  Do not complete restoration steps inline here - use the dedicated
  restoration checklist, which captures all required detail for the
  test record.

  **Restoration checklist completed:** Yes / No

  **Restoration outcome:** ________________________ (SUCCESS / PARTIAL / FAIL)

  **File Count Match:** ________________________ (True / False)

  **Hash Spot-Check:** ________________________ (True / False)

- [ ] **Restoration test destination was cleaned up after the test.**

  Windows:
```powershell
  Remove-Item -Path "D:\RestoreTest" -Recurse -Force
```
  Linux:
```bash
  rm -rf /tmp/restore-test
```

---

## Section 5: Scheduling and Automation Review

- [ ] **Confirm scheduled tasks / cron jobs are configured and
  active.**

  Windows - list all LocalBackup tasks:
```powershell
  schtasks /query /tn "LocalBackup" /fo LIST /v |
      Select-String "TaskName|Status|Last Run|Last Result"
```
  Linux - confirm crontab entries are present:
```bash
  sudo crontab -l | grep -v '^#' | grep -v '^$'
```

- [ ] **Confirm the last scheduled run of each task completed
  successfully.**

  Windows - check last result for the daily backup task:
```powershell
  schtasks /query /tn "LocalBackup\DailyBackup" /fo LIST /v |
      Select-String "Last Run Time|Last Result"
```
  Expected: `Last Result: 0`

  Linux - check the cron output log for the most recent backup:
```bash
  tail -n 20 /mnt/backups/logs/cron-backup.log
```

  **Last backup task result:** ________________________

  **Last verification task result:** ________________________

  **Last retention task result:** ________________________

- [ ] **Confirm the scheduled task / cron job timing is still
  appropriate.**

  Review whether backup windows, business hours, or maintenance
  schedules have changed since the scheduling was last configured.
  Adjust in Task Scheduler or crontab if needed.

---

## Section 6: Documentation and Configuration Currency

- [ ] **Confirm the configuration file reflects the current
  environment.**

  Review `source_paths` / `SOURCE_PATHS` and confirm all listed
  paths still exist and all paths that should be backed up are
  included. Environments change - new application directories are
  created, old ones are decommissioned.

  Windows:
```powershell
  $config = Get-Content .\config\windows-backup.json | ConvertFrom-Json
  $config.backup.source_paths
```
  Linux:
```bash
  source config/linux-backup.conf
  echo "$SOURCE_PATHS"
```

  **Source paths reviewed and current:** Yes / No / Updated

- [ ] **Confirm `retain_days` / `RETAIN_DAYS` and
  `minimum_sets_to_keep` / `MINIMUM_SNAPSHOTS_TO_KEEP` still
  reflect intended policy.**

  Storage availability, compliance requirements, or operational
  needs may have changed since these were last set. Review and
  update if needed.

- [ ] **Confirm this repository is up to date.**

  Check for any updates to the framework:
```bash
  git fetch origin
  git status
```
  Review and apply updates as appropriate. Any changes to scripts
  or configuration schema should be tested in dry-run mode before
  being applied to a production backup schedule.

---

## Section 7: Monthly Review Sign-Off

- [ ] All sections above completed or documented with findings.
- [ ] Any findings requiring follow-up action have been recorded in
  an issue or ticket.
- [ ] Restoration test completed and documented.
- [ ] No outstanding unresolved findings from this review or the
  previous month's review.

**Outstanding findings requiring follow-up:**
--
**Review completed by:** ________________________

**Review completion date and time:** ________________________

**Next scheduled review:** ________________________

---

*File this completed checklist with your operational records. Keep at
minimum the last three months of completed monthly review checklists
as an audit trail.*