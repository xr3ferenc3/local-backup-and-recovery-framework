# Restoration Checklist

This checklist covers both routine restoration testing and actual
incident recovery. It is designed to be followed under pressure, by an
operator who may not have recently read the full documentation.

Before starting, identify which scenario applies:

- **Routine test:** You are verifying that restoration works as
  expected. Use a non-production destination. Stakes are low.
- **Actual incident:** Data has been lost or corrupted and must be
  recovered. Read the Incident Quick Path in `restoration-runbook.md`
  before completing this checklist.

**Date:** ________________________

**Operator:** ________________________

**Host / Environment:** ________________________

**Scenario:** Routine Test / Actual Incident (circle one)

**Backup Set / Snapshot Being Restored From:** ________________________

**Restoration Destination:** ________________________

---

## Section 1: Pre-Restoration Assessment

- [ ] **Identify what needs to be restored.**

  Record the specific files, folders, or dataset being recovered:

  ---
  ---

  - [ ] **Identify when the loss or corruption occurred (for actual
  incidents).**

  This determines which backup set or snapshot to restore from. If
  the incident occurred after the most recent backup, the most recent
  set is appropriate. If the most recent backup already contains the
  corrupted state, select an older set.

  **Incident timestamp (if known):** ________________________

- [ ] **Confirm the selected backup set or snapshot exists.**

  Windows:
```powershell
  Get-ChildItem -Path "D:\Backups" -Directory |
      Sort-Object Name -Descending |
      Select-Object Name, LastWriteTime
```
  Linux:
```bash
  ls -ltd /mnt/backups/*/ | grep -v "logs\|reports"
```

  Backup sets and snapshots are named `{prefix/label}_{yyyy-MM-dd}_{HHmm}`.
  Select the most recent set created **before** the incident.

  **Selected backup set / snapshot:** ________________________

- [ ] **Confirm the selected backup set has a manifest file.**

  A manifest enables post-restore hash verification. If it is missing,
  restoration can still proceed but post-restore confidence is reduced.

  Windows:
```powershell
  Test-Path "D:\Backups\SELECTED_SET_NAME\backup.manifest"
```
  Linux:
```bash
  ls /mnt/backups/SELECTED_SNAPSHOT_NAME/backup.manifest
```

  **Manifest present:** Yes / No

- [ ] **Confirm the restoration destination.**

  For routine tests, use a temporary, empty path:
  - Windows: `D:\RestoreTest`
  - Linux: `/tmp/restore-test`

  For actual incidents restoring to the original location, confirm
  with a second operator or supervisor if available before proceeding.

  For actual incidents restoring to a temporary location first
  (recommended), confirm the temporary path is empty and has
  sufficient space.

---

## Section 2: Pre-Restoration Validation

- [ ] **Confirm sufficient free space at the restoration destination.**

  Windows:
```powershell
  Get-PSDrive -Name (Split-Path "D:\RestoreTest" -Qualifier).TrimEnd(':') |
      Select-Object Used, Free
```
  Linux:
```bash
  df -h /tmp/restore-test 2>/dev/null || df -h /tmp
```

  Minimum free space required equals the total size of the selected
  backup set or snapshot.

- [ ] **Run a dry-run restoration first.**

  Always dry-run before a live restoration. This confirms the
  restoration plan without copying any files and identifies blockers
  before data movement begins.

  Windows:
```powershell
  .\windows\Start-Restore.ps1 `
      -ConfigPath .\config\windows-backup.json `
      -BackupSet "SELECTED_SET_NAME" `
      -Destination "D:\RestoreTest" `
      -DryRun
```
  Linux:
```bash
  ./linux/restore.sh \
      --config config/linux-backup.conf \
      --snapshot "SELECTED_SNAPSHOT_NAME" \
      --destination /tmp/restore-test \
      --dry-run
```

  **Dry-run exit code:** ________________________

  If the dry-run exits with code `2` (fatal error), record the
  blocking reason and resolve it before proceeding:

  ---
  ---

  - [ ] **Dry-run completed without blockers.**

  Do not proceed to live restoration if the dry-run exited with code
  `2`. Code `0` is required to proceed.

---

## Section 3: Live Restoration

- [ ] **Initiate the live restoration.**

  **Standard restoration to a temporary or empty destination:**

  Windows:
```powershell
  .\windows\Start-Restore.ps1 `
      -ConfigPath .\config\windows-backup.json `
      -BackupSet "SELECTED_SET_NAME" `
      -Destination "D:\RestoreTest"
```
  Linux:
```bash
  ./linux/restore.sh \
      --config config/linux-backup.conf \
      --snapshot "SELECTED_SNAPSHOT_NAME" \
      --destination /tmp/restore-test
```

  **Restoration to the original location (requires `-Force` /
  `--force`):**

  Windows:
```powershell
  .\windows\Start-Restore.ps1 `
      -ConfigPath .\config\windows-backup.json `
      -BackupSet "SELECTED_SET_NAME" `
      -Destination "ORIGINAL_SOURCE_PATH" `
      -Force
```
  Linux:
```bash
  sudo ./linux/restore.sh \
      --config config/linux-backup.conf \
      --snapshot "SELECTED_SNAPSHOT_NAME" \
      --destination /original/source/path \
      --force
```

- [ ] **Record the restoration script exit code.**

  Windows:
```powershell
  echo $LASTEXITCODE
```
  Linux:
```bash
  echo $?
```

  **Restoration exit code:** ________________________

  | Exit code | Meaning |
  |---|---|
  | 0 | Restoration completed and post-restore verification passed |
  | 1 | Restoration completed but post-restore verification found issues |
  | 2 | Fatal error - restoration aborted before any files copied |

---

## Section 4: Post-Restoration Verification

- [ ] **Confirm the Restoration Summary output.**

  At the end of every live restoration run, the script prints a
  Restoration Summary. Record the values here:

  **Status:** ________________________

  **Subdirs Restored:** ________________________

  **Subdirs Failed:** ________________________

  **File Count Match:** ________________________ (True / False)

  **Hash Spot-Check:** ________________________ (True / False)

- [ ] **File Count Match is True.**

  If False, some files failed to copy during restoration. Refer to
  `restoration-runbook.md` - Troubleshooting Restoration Failures.

- [ ] **Hash Spot-Check is True (if manifest was present).**

  If False, a restored file does not match its original checksum.
  Do not rely on this restoration for actual recovery until
  investigated. Refer to `restoration-runbook.md`.

- [ ] **Manually spot-check a sample of restored files.**

  Open or review several restored files to confirm they are
  readable, complete, and contain expected content. Automated
  verification confirms bytes match - manual spot-check confirms
  the files are what you expect them to be.

  **Files manually reviewed:**

  ---
  ---

  - [ ] **Confirm restored file permissions are correct (if
  security-sensitive data was restored).**

  Windows:
```powershell
  Get-Acl -Path "D:\RestoreTest\SampleFile.txt" | Format-List
```
  Linux:
```bash
  ls -la /tmp/restore-test/
  stat /tmp/restore-test/sample-file.txt
```

---

## Section 5: Post-Restoration Actions

- [ ] **For actual incidents: move restored data to its final
  location.**

  Once verification passes, manually copy or move needed files
  from the temporary restoration destination into their final
  production location. Do not skip the manual review step - confirm
  the restored content is what you expect before replacing anything
  in production.

- [ ] **For actual incidents: restart any services or applications
  that depend on the restored data.**

  This framework restores files - it does not restart services.
  After restoration, restart and validate any application or service
  that was affected by the data loss.

  **Services restarted:** ________________________

- [ ] **Clean up the temporary restoration destination (routine tests
  only).**

  Windows:
```powershell
  Remove-Item -Path "D:\RestoreTest" -Recurse -Force
```
  Linux:
```bash
  rm -rf /tmp/restore-test
```

---

## Section 6: Documentation and Sign-Off

- [ ] **Record the outcome of this restoration.**

  Routine test or incident recovery without documentation provides
  no audit value. Attach the restoration script log and the backup
  set report to this record.

  **Log file path:** ________________________

  **Report file path:** ________________________

  **Restoration outcome:** ________________________

- [ ] **For actual incidents: file an incident record or ticket**
  referencing:
  - What was lost or corrupted and when
  - Which backup set or snapshot was used
  - Verification results (File Count Match, Hash Spot-Check)
  - Final resolution and any services restarted

- [ ] **For routine tests: record the test in the monthly review
  log.**

  The `checklists/monthly-review-checklist.md` includes a restoration
  test as a required item. Mark it complete with today's date and
  the backup set or snapshot tested.

**Notes / Issues Found:**

---
---

**Restoration confirmed successful:** Yes / No / Partial

**Checklist completed by:** ________________________

**Time checklist completed:** ________________________

---

*A restoration that has not been documented has not been completed.
File this checklist with your operational records before closing the
restoration activity.*