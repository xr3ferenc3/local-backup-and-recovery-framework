# Restoration Runbook

This is the most operationally critical document in this repository. It
is written to be usable under pressure, during an actual incident, by an
operator who may not have read the rest of the documentation recently.

If you are here because something is wrong, start with the **Incident
Quick Path** below. If you are here to perform routine restoration
testing, skip to **Routine Restoration Testing**.

---

## Incident Quick Path

Use this section when data has actually been lost or corrupted and you
need to recover it now.

### Step 1: Stop and assess - do not skip this

Before restoring anything, confirm:

1. **What was lost or corrupted?** Identify the specific files, folders,
   or the entire dataset.
2. **When did it happen?** This determines which backup set or snapshot
   to restore from. If the loss happened recently, the most recent
   backup may already include the bad state - you may need an older
   backup set.
3. **Where should it be restored to?** Restoring directly back to the
   original location overwrites whatever is currently there. If there is
   any doubt, restore to a temporary location first, verify, then move
   files into place manually.

### Step 2: Identify the correct backup set or snapshot

**Windows:**
```powershell
Get-ChildItem -Path "D:\Backups" -Directory | Sort-Object Name -Descending | Select-Object Name
```

**Linux:**
```bash
ls -la /mnt/backups/ | grep "^d"
```

Backup set / snapshot names embed their creation timestamp:
`{prefix}_{yyyy-MM-dd}_{HHmm}`. Choose the most recent set created
**before** the incident occurred.

### Step 3: Restore to a temporary location first

This is the default, safest path. Do not restore directly over the
original location unless you have already confirmed via Step 1 that
doing so is intentional and safe.

**Windows:**
```powershell
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -BackupSet "PREFIX_2025-06-15_0200" -Destination "D:\IncidentRestore"
```

**Linux:**
```bash
./linux/restore.sh --config config/linux-backup.conf --snapshot "LABEL_2025-06-15_0200" --destination /mnt/incident-restore
```

### Step 4: Verify the restoration before using it

Check the Restoration Summary printed at the end of the script run.
Confirm:
- `File Count Match: True` / `true`
- `Hash Spot-Check: True` / `true`

If either shows `False` / `false`, **do not rely on this restoration**.
See the Troubleshooting section below, and consider trying the next most
recent backup set as a fallback.

### Step 5: Move restored data into place

Once verified, manually review the restored content in the temporary
location and copy or move what is needed into its final location. This
manual final step is intentional - it ensures a human reviews the
restored content before it replaces anything in production.

### Step 6: Document the incident

Use the restored report and console output as the factual basis for an
incident record or ticket. Note: what was lost, when, which backup set
was used, verification results, and the final resolution.

---

## Routine Restoration Testing

This section is for the monthly restoration test required by
`checklists/monthly-review-checklist.md`. The goal is to confirm
restoration actually works, before you need it during a real incident.

### Full restoration test (all source paths)

**Windows:**
```powershell
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination "D:\RestoreTest" -DryRun
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination "D:\RestoreTest"
```

**Linux:**
```bash
./linux/restore.sh --config config/linux-backup.conf --destination /tmp/restore-test --dry-run
./linux/restore.sh --config config/linux-backup.conf --destination /tmp/restore-test
```

Always run with `-DryRun` / `--dry-run` first to confirm the restoration
plan before committing to an actual file copy.

### Partial restoration test (single source path only)

Use `-SourceSubPath` (Windows) or `--source-subdir` (Linux) to restrict
restoration to a single source subdirectory. This is useful when only
one dataset needs to be tested, or when a real incident affects only one
location.

The subdirectory name matches the "safe name" generated from the source
path during backup - special characters are replaced with underscores.

**Windows example:**
If your source path is `C:\Users\Administrator\Documents`, the safe-name
subdirectory is `C__Users_Administrator_Documents`.
```powershell
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -SourceSubPath "C__Users_Administrator_Documents" -Destination "D:\RestoreTest"
```

**Linux example:**
If your source path is `/home/admin`, the safe-name subdirectory is
`home_admin`.
```bash
./linux/restore.sh --config config/linux-backup.conf --source-subdir "home_admin" --destination /tmp/restore-test
```

**If you are unsure of the exact safe-name subdirectory**, list the
contents of the backup set or snapshot directly:

**Windows:**
```powershell
Get-ChildItem -Path "D:\Backups\PREFIX_2025-06-15_0200" -Directory
```

**Linux:**
```bash
ls -la /mnt/backups/LABEL_2025-06-15_0200/
```

### Recording the test

After every restoration test, complete
`checklists/restoration-checklist.md` and file the result with your
monthly review records. A restoration test that is not documented
provides no audit value.

---

## Restoring to the Original Source Location

This is a higher-risk operation than restoring to a temporary location,
and is appropriate only when you have already confirmed (via Step 1 of
the Incident Quick Path) that this is the correct action.

Restoring to the original location, where files already exist, requires
`-Force` (Windows) or `--force` (Linux), because the scripts refuse to
restore into a non-empty destination by default. This default exists
specifically to prevent accidental overwrites - see `threat-model.md`.

**Windows:**
```powershell
.\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -BackupSet "PREFIX_2025-06-15_0200" -Destination "C:\Users\Administrator\Documents" -Force
```

**Linux:**
```bash
sudo ./linux/restore.sh --config config/linux-backup.conf --snapshot "LABEL_2025-06-15_0200" --destination /home/admin --force
```

**Before running with `-Force` / `--force`:**
1. Confirm you have selected the correct backup set or snapshot
2. Confirm the destination path is exactly correct - there is no
   confirmation prompt once `-Force` / `--force` is passed
3. Consider taking a manual copy of the current (possibly corrupted)
   state of the destination first, in case the restoration needs to be
   reversed

---

## Disaster Recovery Scenario: Source Volume Lost Entirely

If the original source volume or disk has failed entirely and a
replacement is now in place:

1. Confirm the new volume/disk is mounted and accessible at the expected
   path.
2. Confirm sufficient free space exists for the restoration - restoration
   scripts validate this automatically and will refuse to proceed if
   insufficient space is detected.
3. Run the restoration using `-Force` / `--force`, since the destination,
   while now empty due to the volume replacement, may need this flag if
   any placeholder directories exist.
4. After restoration, run application or service validation specific to
   what was restored - this framework verifies file-level integrity, not
   application functionality. A restored application configuration file
   may be byte-for-byte correct but the application itself still needs to
   be restarted or reconfigured to use it.

---

## What Restoration Verification Does and Does Not Confirm

**Confirms:**
- The expected number of files are present at the destination
- A sample of files match their original SHA256 checksum
- The restoration script completed without file copy errors

**Does NOT confirm:**
- That an application using the restored files will function correctly
- That a restored database export file, once restored, has actually been
  imported back into a live database
- That file permissions and ownership exactly match the pre-incident
  state (robocopy `/COPYALL` and rsync `-a` both preserve permissions and
  ownership during backup and restore, but verify this explicitly for
  security-sensitive data)

After any restoration involving security-relevant data (user home
directories, configuration with embedded credentials, etc.), manually
verify permissions:

**Windows:**
```powershell
Get-Acl -Path "D:\RestoreTest\SomeFile.txt" | Format-List
```

**Linux:**
```bash
ls -la /tmp/restore-test/
stat /tmp/restore-test/somefile.txt
```

---

## Troubleshooting Restoration Failures

| Symptom | Likely Cause | Resolution |
|---|---|---|
| Restoration blocked with "destination is not empty" | Default safety behavior - destination already contains files | Use `-Force` / `--force` if intentional, or choose an empty destination |
| Restoration blocked with "insufficient free space" | Destination volume does not have enough room | Free space, or choose a different destination |
| `File Count Match: False` after restoration | Some files failed to copy during restoration | Check the restore rsync/robocopy log referenced in the script output for the specific file-level errors |
| `Hash Spot-Check: False` after restoration | A restored file does not match its original checksum - possible corruption during backup or restore | Try restoring from an earlier backup set; if the problem persists across sets, investigate the backup destination storage for underlying corruption |
| "No manifest found" warning | The backup set/snapshot predates manifest generation, or manifest generation failed during backup | Restoration proceeds with file-count verification only; treat this restoration with additional manual review |
| Script reports "Specified backup set/snapshot not found" | Typo in the backup set/snapshot name, or it was purged by retention | List available sets per Step 2 of the Incident Quick Path above |

For additional failure modes not specific to restoration, see
`troubleshooting.md`.

---

## Related Documentation

| Topic | Document |
|---|---|
| What restoration protects against and does not | `threat-model.md` |
| Printable restoration checklist | `checklists/restoration-checklist.md` |
| Full script syntax reference | `command-reference.md` |
| Why retention can affect which backups are available to restore | `retention-policy.md` |