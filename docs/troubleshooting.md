# Troubleshooting Guide

This guide is structured symptom-first. Find the symptom that matches
what you are seeing, read the likely causes, and follow the resolution
steps in order.

Each section covers a specific script or operational stage. If a symptom
spans multiple scripts or is not clearly tied to one stage, check the
General Failures section at the end.

---

## Invoke-Backup.ps1 / backup.sh

### Symptom: Script refuses to run with a permissions error

**Windows:** PowerShell reports `This script requires running as
Administrator`.

**Linux:** Script reports `Permission denied` when accessing a source
path.

**Likely cause:**
- Windows: The script was launched from a non-elevated PowerShell
  session.
- Linux: The user running the script does not have read access to one or
  more configured source paths (e.g. `/etc` or another user's home
  directory).

**Resolution:**
- Windows: Close the current PowerShell session. Open a new PowerShell
  window using "Run as Administrator". Re-run the script.
- Linux: Re-run the script with `sudo`, or add the running user to the
  appropriate group, or adjust the source path permissions if your
  environment allows it. Confirm which path is failing by reviewing the
  log output.

---

### Symptom: Script exits with `Configuration file not found`

**Likely cause:** The live configuration file has not been created yet, or
the path passed to `-ConfigPath` / `--config` is incorrect.

**Resolution:**
1. Confirm the configuration file exists:

   Windows:
```powershell
   Test-Path config\windows-backup.json
```
   Linux:
```bash
   test -f config/linux-backup.conf && echo "Found" || echo "Not found"
```

2. If the file does not exist, create it from the example:

   Windows:
```powershell
   Copy-Item config\windows-backup.example.json config\windows-backup.json
```
   Linux:
```bash
   cp config/linux-backup.example.conf config/linux-backup.conf
```

3. Populate the live configuration file and retry.

---

### Symptom: Script exits with `Required configuration field is missing`

**Likely cause:** The live configuration file is incomplete - one or more
required fields have been left blank or removed.

**Resolution:**
1. Open the live configuration file and compare it against the example
   file to identify which field is missing.
2. The error message names the specific field. Locate that field in the
   example file to read its inline documentation.
3. Populate the missing field and retry.

---

### Symptom: Script exits with `Destination root does not exist`

**Likely cause:** The directory specified in `destination_root` /
`DESTINATION_ROOT` has not been created, or the path is incorrect.

**Resolution:**
1. Confirm the path:

   Windows:
```powershell
   Test-Path "D:\Backups"
```
   Linux:
```bash
   test -d /mnt/backups && echo "Found" || echo "Not found"
```

2. Create it if missing (see the setup guide for your platform).

3. If the path is a network share or mounted volume, confirm the share
   or mount is active before running the backup script.

---

### Symptom: Source path reported as not found - skipped during backup

**Likely cause:** A path in `source_paths` / `SOURCE_PATHS` no longer
exists, was renamed, or was never created. The script logs a warning and
skips the path rather than aborting the entire run.

**Resolution:**
1. Review the log output to identify which source path was skipped.
2. Confirm whether the path should still exist:
   - If it should exist and does not, investigate why it was removed.
   - If it no longer applies, remove it from the configuration file.
3. Update the configuration file accordingly and confirm on the next run.

---

### Symptom: Backup run exits with `COMPLETED_WITH_ERRORS`

**Likely cause:** One or more source paths were skipped (see above), or
robocopy / rsync reported file copy failures for specific files.

**Resolution:**
1. Review the backup run log:

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
   grep '"level":"ERROR"' /mnt/backups/logs/backup_*.json | tail -n 20
```

2. Review the robocopy / rsync log file referenced in the ERROR entries
   for file-level detail.

3. Common causes of individual file copy failures:
   - Windows: file locked by an application and `use_vss` is `false` -
     consider enabling VSS in the configuration.
   - Linux: file permissions changed between backup start and rsync
     reaching that file - usually benign for low-risk files, worth
     investigating for critical files.
   - Both: file was deleted after the backup started but before it was
     processed - transient; safe to ignore if the file is genuinely
     gone.

---

### Symptom: VSS shadow copy creation failed (Windows only)

**Likely cause:** VSS service is disabled, storage for shadow copies is
insufficient, or the script was run without Administrator privileges.

**Resolution:**
1. Confirm the VSS service is enabled and can start:
```powershell
   Get-Service VSS | Select-Object Status, StartType
   Set-Service VSS -StartupType Manual
   Start-Service VSS
```

2. Confirm VSS shadow storage is configured on the source volume:
```powershell
   vssadmin list shadowstorage
```
   If no storage is listed, configure it:
```powershell
   vssadmin add shadowstorage /for=C: /on=C: /maxsize=10%
```

3. If VSS continues to fail and immediate backup is needed, set
   `use_vss` to `false` in the configuration file temporarily. Note that
   this may result in locked files being skipped.

---

## Test-BackupIntegrity.ps1 / verify-backup.sh

### Symptom: Verification reports `FAIL` on file count check

**Likely cause:** Fewer files exist in the backup set than in the source
path. This indicates files were skipped during the backup run.

**Resolution:**
1. Confirm which source path has a count mismatch - the log will show
   per-source counts.
2. Review the backup run log for that source path for robocopy / rsync
   errors.
3. Check whether the source has changed since the backup ran - new files
   added after backup completion will produce a count mismatch on the
   next verification that is not a defect.
4. If the mismatch reflects genuinely missing files, re-run the backup
   and verify again before relying on this backup set for restoration.

---

### Symptom: Verification reports `FAIL` on size check

**Likely cause:** A meaningful size difference exists between source and
backup. This may indicate truncated file transfers, or the source changed
significantly between backup and verification.

**Resolution:**
1. Confirm whether the source data changed between backup and
   verification. If so, the mismatch is expected - wait for the next
   backup run and verify immediately after.
2. If the source has not changed, review the robocopy / rsync log for
   that source path for truncation or write errors.
3. Adjust `fail_on_size_delta_percent` / `FAIL_ON_SIZE_DELTA_PERCENT`
   upward (e.g. to 10) if filesystem overhead differences are
   consistently triggering false failures, but investigate root cause
   before increasing tolerance.

---

### Symptom: Verification reports `FAIL` on hash spot-check

**Likely cause:** A file in the random spot-check sample does not match
its SHA256 value recorded in the manifest at backup time. This indicates
silent corruption during transfer or at rest.

**Resolution:**
1. This is the most serious verification failure. Do not rely on this
   backup set for restoration.
2. Re-run the backup immediately and verify again.
3. If hash failures persist across multiple backup sets, investigate the
   storage medium (source or destination) for underlying hardware issues.
4. Run a filesystem check:

   Windows:
```powershell
   chkdsk D: /f /r
```
   Linux:
```bash
   sudo fsck /dev/sdX
```

---

### Symptom: Spot-check skipped - "No manifest found"

**Likely cause:** The backup was run with manifest generation disabled, or
`generate_manifest` / `generate_manifest` in `backup.sh` failed silently.

**Resolution:**
1. Confirm `MANIFEST_ENABLED` / `integrity.spot_check_enabled` is `true`
   in the configuration.
2. Check whether `backup.manifest` exists in the backup set directory:

   Windows:
```powershell
   Test-Path "D:\Backups\PREFIX_2025-06-15_0200\backup.manifest"
```
   Linux:
```bash
   ls /mnt/backups/LABEL_2025-06-15_0200/backup.manifest
```

3. If the manifest is missing from an otherwise successful backup run,
   re-run the backup to generate a new set with a manifest. The
   backup set without a manifest can still be used for restoration but
   post-restore integrity verification will be limited to file count
   only.

---

## Start-Restore.ps1 / restore.sh

### Symptom: Restoration blocked - "destination is not empty"

**Likely cause:** Default safety behavior. The script refuses to restore
into a directory that already contains files unless `-Force` / `--force`
is explicitly passed.

**Resolution:**
- If restoring to a temporary test location, use an empty directory or
  create a new one.
- If restoring to the original source location during an actual
  recovery, confirm this is intentional, then add `-Force` / `--force`.
- Review `restoration-runbook.md` for guidance on when to use `-Force` /
  `--force` safely.

---

### Symptom: Restoration blocked - "insufficient free space"

**Likely cause:** The destination volume does not have enough free space
to hold the backup set contents.

**Resolution:**
1. Check available space:

   Windows:
```powershell
   Get-PSDrive -Name (Split-Path "D:\RestoreTest" -Qualifier).TrimEnd(':')
```
   Linux:
```bash
   df -h /tmp/restore-test
```

2. Free space on the destination volume, or choose a different
   destination volume with sufficient space.

---

### Symptom: Post-restore file count mismatch

**Likely cause:** One or more files failed to copy during the restoration
run itself.

**Resolution:**
1. Review the restore rsync / robocopy log file referenced in the script
   output for file-level errors.
2. Identify whether the failed files are critical for the recovery. If
   they are, investigate the specific error and retry restoration of the
   affected files individually if needed.

---

## Set-RetentionPolicy.ps1 / enforce-retention.sh

### Symptom: No backup sets are being purged despite age

**Likely cause (most common):** The script is running in dry-run mode
(the default), and `-Force` / `--force` has not been passed.

**Resolution:**
```powershell
# Windows - confirm the mode reported in the console output
.\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json -Force
```
```bash
# Linux
./linux/enforce-retention.sh --config config/linux-backup.conf --force
```

**Likely cause (less common):** The total number of backup sets does not
exceed `minimum_sets_to_keep` / `MINIMUM_SNAPSHOTS_TO_KEEP`. The floor
protects all sets when total count equals the floor value - see
`retention-policy.md` for the logic.

---

### Symptom: More backup sets are purged than expected

**Likely cause:** `retain_days` / `RETAIN_DAYS` or `minimum_sets_to_keep`
/ `MINIMUM_SNAPSHOTS_TO_KEEP` is configured more aggressively than
intended.

**Resolution:**
1. Review the log for the retention run to see exactly which sets were
   purged and why:

   Windows:
```powershell
   Get-Content "D:\Backups\Logs\Set-RetentionPolicy_*.json" | Select-String "Backup set deleted"
```
   Linux:
```bash
   grep '"Snapshot deleted"' /mnt/backups/logs/enforce-retention_*.json
```

2. Deleted backup sets cannot be recovered through this framework. Adjust
   `retain_days` / `RETAIN_DAYS` or `minimum_sets_to_keep` /
   `MINIMUM_SNAPSHOTS_TO_KEEP` in the configuration file before the
   next retention run.

3. Always review the dry-run output before the first live retention run
   in any new environment or after changing retention configuration.

---

## New-BackupReport.ps1 / generate-report.sh

### Symptom: Script exits with "no log data found"

**Likely cause:** The backup run log for the requested backup set has been
rotated out, or the backup set was created outside this framework.

**Resolution:**
1. Confirm `log_retention_days` / `LOG_RETENTION_DAYS` in the
   configuration is long enough to cover the backup set age you are
   trying to report on.
2. If the logs have already rotated, a full report cannot be generated.
   The backup set itself remains usable for restoration - only the
   report will be incomplete.

---

### Symptom: Report shows "Partial Report" - integrity data missing

**Likely cause:** `Test-BackupIntegrity.ps1` / `verify-backup.sh` has not
been run against this backup set, or its result file has been deleted.

**Resolution:**
Run the verification script against the backup set, then re-generate the
report:

Windows:
```powershell
.\windows\Test-BackupIntegrity.ps1 -ConfigPath .\config\windows-backup.json -BackupSet "PREFIX_2025-06-15_0200"
.\windows\New-BackupReport.ps1 -ConfigPath .\config\windows-backup.json -BackupSet "PREFIX_2025-06-15_0200"
```
Linux:
```bash
./linux/verify-backup.sh --config config/linux-backup.conf --snapshot "LABEL_2025-06-15_0200"
./linux/generate-report.sh --config config/linux-backup.conf --snapshot "LABEL_2025-06-15_0200"
```

---

## General Failures

### Symptom: All scripts fail immediately on Linux with unexpected errors

**Likely cause:** Script files do not have execute permission.

**Resolution:**
```bash
chmod +x linux/*.sh
bash -n linux/backup.sh
```

---

### Symptom: Log files are not being created

**Likely cause:** The log directory does not exist or is not writable by
the account running the scripts.

**Resolution:**
Windows:
```powershell
New-Item -ItemType Directory -Path "D:\Backups\Logs" -Force
icacls "D:\Backups\Logs" /grant "${env:USERNAME}:(OI)(CI)F"
```
Linux:
```bash
mkdir -p /mnt/backups/logs
chown "$(whoami)" /mnt/backups/logs
chmod 750 /mnt/backups/logs
```

---

### Symptom: Notification emails are not being sent

**Linux only.** The Windows notification path uses PowerShell's
`Send-MailMessage`, which has no external dependencies. The Linux path
requires a mail transfer agent.

**Resolution:**
1. Confirm `SMTP_SERVER` is populated in the configuration.
2. Confirm `s-nail` or `mailx` is installed:
```bash
   which mailx || which mail || echo "No mail command found"
```
3. Install if missing:
```bash
   sudo dnf install s-nail -y
```
4. Test the mail command independently before relying on script
   notification.

---

## Related Documentation

| Topic | Document |
|---|---|
| Restoration-specific failure modes | `restoration-runbook.md` |
| Retention-specific configuration reference | `retention-policy.md` |
| Full script syntax reference | `command-reference.md` |