# Pre-Backup Checklist

Complete this checklist before initiating a live backup run in a
production context. It takes less than five minutes and prevents the
most common causes of failed or incomplete backup runs.

This checklist is designed to be printed and kept at the workstation
or server console, or used as a digital reference during backup
operations.

**Date:** ________________________

**Operator:** ________________________

**Host / Environment:** ________________________

**Planned Backup Window:** ________________________

---

## Section 1: Destination Storage

- [ ] **Destination volume is mounted and accessible.**

  Windows — confirm the destination drive letter is available:
```powershell
  Test-Path "D:\Backups"
```
  Linux — confirm the destination mount is active:
```bash
  mountpoint -q /mnt/backups && echo "Mounted" || echo "NOT MOUNTED"
```

- [ ] **Sufficient free space exists on the destination volume.**

  Windows:
```powershell
  Get-PSDrive D | Select-Object Used, Free
```
  Linux:
```bash
  df -h /mnt/backups
```
  Minimum free space required equals the total size of all configured
  source paths. If space is tight, run the retention script first:

  Windows (dry run first):
```powershell
  .\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json
```
  Linux (dry run first):
```bash
  ./linux/enforce-retention.sh --config config/linux-backup.conf
```
  Review the output, then pass `-Force` / `--force` if the candidates
  are correct.

- [ ] **Log directory exists and is writable.**

  Windows:
```powershell
  Test-Path "D:\Backups\Logs"
```
  Linux:
```bash
  test -d /mnt/backups/logs && test -w /mnt/backups/logs && echo "OK" || echo "CHECK REQUIRED"
```

---

## Section 2: Source Paths

- [ ] **All configured source paths exist and are accessible.**

  Windows:
```powershell
  $config = Get-Content .\config\windows-backup.json | ConvertFrom-Json
  foreach ($p in $config.backup.source_paths) {
      Write-Host "$p : $(if (Test-Path $p) { 'OK' } else { 'NOT FOUND' })"
  }
```
  Linux:
```bash
  source config/linux-backup.conf
  for p in $SOURCE_PATHS; do
      test -e "$p" && echo "OK: $p" || echo "NOT FOUND: $p"
  done
```

- [ ] **No unexpected recent changes to critical source paths that
  should be investigated before backup.**

  Review recently modified files in a critical source path to confirm
  no unexpected activity has occurred before it is captured in a backup:

  Windows:
```powershell
  Get-ChildItem "C:\inetpub\wwwroot" -Recurse |
      Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) } |
      Select-Object FullName, LastWriteTime
```
  Linux:
```bash
  find /var/www/html -type f -mtime -1 -ls
```

---

## Section 3: Windows-Specific Checks

- [ ] **Volume Shadow Copy Service is available (if `use_vss` is `true`).**

```powershell
  Get-Service VSS | Select-Object Status, StartType
```
  Expected: `StartType` is `Manual` or `Automatic`. If `Disabled`,
  correct before proceeding:
```powershell
  Set-Service VSS -StartupType Manual
```

- [ ] **No previous VSS shadow copies have accumulated unexpectedly.**

  Accumulated VSS shadow copies consume storage. Confirm none are
  orphaned from a previous failed run:
```powershell
  vssadmin list shadows
```
  If orphaned shadows are present from a previous failed run, delete
  them:
```powershell
  vssadmin delete shadows /all /quiet
```

---

## Section 4: Configuration Review

- [ ] **Configuration file has not been modified unexpectedly since the
  last backup run.**

  Windows:
```powershell
  (Get-Item .\config\windows-backup.json).LastWriteTime
```
  Linux:
```bash
  stat config/linux-backup.conf | grep Modify
```

- [ ] **Configuration file is valid and parseable.**

  Windows:
```powershell
  Get-Content .\config\windows-backup.json | ConvertFrom-Json | Out-Null
  if ($?) { Write-Host "Configuration valid" }
```
  Linux:
```bash
  bash -c "source config/linux-backup.conf && echo 'Configuration valid'"
```

- [ ] **Retention settings are configured as intended.**

  Confirm `retain_days` / `RETAIN_DAYS` and
  `minimum_sets_to_keep` / `MINIMUM_SNAPSHOTS_TO_KEEP` match your
  documented retention policy before any live run that will be followed
  by a retention enforcement run.

---

## Section 5: System State

- [ ] **No active system maintenance, patching, or large file
  operations are in progress that would significantly change source data
  during the backup window.**

  Backing up a system mid-patch or while a large file operation is
  in progress can produce an inconsistent snapshot. Where possible,
  schedule backups before maintenance windows, not during them.

- [ ] **Previous backup run completed successfully (if applicable).**

  Confirm the most recent prior backup run is not still running or
  failed silently:

  Windows:
```powershell
  Get-ChildItem "D:\Backups\Logs" -Filter "Invoke-Backup_*.json" |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1 |
      Get-Content |
      Select-String '"message":"Backup run complete"'
```
  Linux:
```bash
  grep '"message":"Backup run complete"' /mnt/backups/logs/backup_*.json | tail -n 1
```

---

## Section 6: Final Confirmation

- [ ] All Section 1 through 5 items checked.
- [ ] Any items that required corrective action have been resolved.
- [ ] The backup run is being initiated in an elevated session
  (Administrator on Windows, root or sudo on Linux).

**Notes / Issues Found:**

---

**Checklist completed by:** ________________________

**Time checklist completed:** ________________________

---

*Proceed to run the backup script once all items are checked or
resolved. Move to `checklists/post-backup-checklist.md` immediately
after the backup script completes.*