# RHEL 9 Setup Guide

This guide walks through setting up the Local Backup and Recovery
Framework on RHEL 9, from prerequisites through to a verified first
backup.

Assume no prior exposure to this framework. Each step states what to do,
why it matters, and how to confirm it worked before moving to the next
step.

This guide is also applicable to Rocky Linux 9 and AlmaLinux 9, which are
binary-compatible with RHEL 9.

---

## Prerequisites

### System requirements

| Requirement | Detail |
|---|---|
| Operating system | RHEL 9 (Rocky Linux 9, AlmaLinux 9 are compatible) |
| Bash | 4.0 or later - included by default |
| Disk space | Destination volume must have free space at minimum equal to the total size of all source paths combined, accounting for incremental snapshot growth over time |
| Permissions | Root or sudo access for system paths; standard user sufficient for user-space paths |

### Verify Bash version

```bash
bash --version | head -n 1
```
Expected: Version `4.0` or higher. RHEL 9 ships with Bash 5.1 by default.

### Install rsync

rsync is the one external dependency in this framework's Linux path. It
is available in the default RHEL 9 repositories.

```bash
sudo dnf install rsync -y
```

**Verification:**
```bash
rsync --version | head -n 1
```
Expected: Version information is displayed without error.

### Confirm coreutils and findutils are present

These ship by default on every RHEL 9 installation, but confirm their
presence:

```bash
which sha256sum find du df shuf
```
Expected: A path is returned for each command. If any are missing
(unlikely on a standard installation), install via:
```bash
sudo dnf install coreutils findutils -y
```

### (Optional) Install a mail transfer agent for notifications

Required only if you intend to enable email notifications
(`SMTP_SERVER` configured).

```bash
sudo dnf install s-nail -y
```

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/YOUR-USERNAME/local-backup-and-recovery-framework.git
cd local-backup-and-recovery-framework
```

**Verification:**
```bash
ls -la
```
Expected: `windows/`, `linux/`, `config/`, `docs/`, `checklists/`,
`output/` directories are all present.

---

## Step 2: Make Scripts Executable

```bash
chmod +x linux/*.sh
```

**Verification:**
```bash
ls -la linux/
```
Expected: Each `.sh` file shows `x` permission bits, e.g.
`-rwxr-xr-x`.

---

## Step 3: Prepare the Destination Volume

Identify or create the path where backups will be stored. This should
ideally be physically separate storage from the source data - see
`threat-model.md` for why.

```bash
sudo mkdir -p /mnt/backups
sudo mkdir -p /mnt/backups/logs
sudo mkdir -p /mnt/backups/reports

# Set ownership to the account that will run the backup scripts
sudo chown -R "$(whoami):$(whoami)" /mnt/backups
```

**Verification:**
```bash
test -d /mnt/backups && test -d /mnt/backups/logs && test -d /mnt/backups/reports && echo "Directories confirmed"
```
Expected output: `Directories confirmed`

---

## Step 4: Create Your Configuration File

```bash
cp config/linux-backup.example.conf config/linux-backup.conf
nano config/linux-backup.conf
```

### Minimum fields to review and update

| Field | What to set it to |
|---|---|
| `SOURCE_PATHS` | A space-separated list of absolute paths you want backed up |
| `DESTINATION_ROOT` | The path created in Step 3 (e.g. `/mnt/backups`) |
| `BACKUP_HOST_LABEL` | A short identifier for this host, e.g. your hostname |
| `LOG_DIRECTORY` | e.g. `/mnt/backups/logs` |
| `REPORT_OUTPUT_DIRECTORY` | e.g. `/mnt/backups/reports` |
| `RETAIN_DAYS` | Review the default of `30`; adjust per `retention-policy.md` |

Every variable in the example file includes an inline comment explaining
its purpose and acceptable values. Read these before changing defaults.

**Verification - confirm the file sources without error:**
```bash
bash -c "source config/linux-backup.conf && echo 'Configuration sourced successfully'"
```
Expected output: `Configuration sourced successfully`

---

## Step 5: Confirm Source Path Permissions

If any source path requires elevated permissions to read (e.g. `/etc`,
or another user's home directory), the backup script must be run with
sufficient privileges - either as root or via `sudo`.

```bash
# Test read access to each configured source path
for path in $(grep '^SOURCE_PATHS=' config/linux-backup.conf | cut -d'"' -f2); do
    if [[ -r "$path" ]]; then
        echo "OK: $path is readable"
    else
        echo "WARNING: $path is not readable by the current user"
    fi
done
```

If any path reports a warning, plan to run the backup scripts with
`sudo`, or adjust the source path's permissions.

---

## Step 6: Run a Dry-Run Backup

Before copying any real data, validate the configuration end to end using
dry-run mode.

```bash
./linux/backup.sh --config config/linux-backup.conf --dry-run
```

**What to look for in the output:**
- Each configured source path is acknowledged
- No `[ERROR]` entries appear
- The console reports `[DRY RUN] Would execute rsync` for each source

If any source path is reported as not found, correct the path in your
configuration file before proceeding.

---

## Step 7: Run Your First Live Backup

```bash
./linux/backup.sh --config config/linux-backup.conf
```

If any source path requires elevated read permissions (per Step 5), run
with `sudo` instead, ensuring the destination paths remain writable:

```bash
sudo ./linux/backup.sh --config config/linux-backup.conf
```

**Verification:**
```bash
# Confirm a snapshot directory was created
ls -la /mnt/backups/

# Confirm the run summary shows SUCCESS
grep '"message":"Backup run complete"' /mnt/backups/logs/backup_*.json | tail -n 1
```
Expected: A JSON line containing `"status":"SUCCESS"`.

---

## Step 8: Verify the Backup

```bash
./linux/verify-backup.sh --config config/linux-backup.conf
```

**Verification:**
The console output ends with a Verification Summary. Confirm `Status: PASS`.

If the status is `FAIL`, see `troubleshooting.md` before relying on this
snapshot.

---

## Step 9: Generate a Report

```bash
./linux/generate-report.sh --config config/linux-backup.conf
```

**Verification:**
```bash
ls -la /mnt/backups/reports/
```
Open the most recent report file and confirm it contains a Backup
Execution section and an Integrity Verification section, both with
populated data.

---

## Step 10: Test Restoration (Required, Not Optional)

A backup that has never been restored from is an untested assumption.
Perform a restoration test to a non-production destination now, while
the stakes are low, rather than for the first time during an actual
incident.

```bash
./linux/restore.sh --config config/linux-backup.conf --destination /tmp/restore-test --dry-run
```

Review the dry-run output, then perform a live test restore:

```bash
./linux/restore.sh --config config/linux-backup.conf --destination /tmp/restore-test
```

**Verification:**
The console output ends with a Restoration Summary showing
`File Count Match: true` and `Hash Spot-Check: true`.

Clean up the test destination once verified:
```bash
rm -rf /tmp/restore-test
```

For full restoration procedures, including partial restores and
disaster-recovery scenarios, see `restoration-runbook.md`.

---

## Step 11: Schedule the Framework

Manual execution is appropriate for initial testing only. For production
use, schedule the backup, verification, and retention scripts using
`cron`. Full guidance, including recommended timing and conflict
avoidance, is in `scheduling-guide.md`.

---

## Step 12: Complete the Pre-Backup Checklist Going Forward

For every subsequent live backup run in a production context, use
`checklists/pre-backup-checklist.md` and
`checklists/post-backup-checklist.md` to maintain consistency and catch
issues before they become incidents.

---

## Setup Complete - Summary Checklist

- [ ] Bash 4.0+ confirmed
- [ ] rsync installed and confirmed
- [ ] coreutils and findutils confirmed present
- [ ] (Optional) mail transfer agent installed for notifications
- [ ] Repository cloned
- [ ] Scripts made executable
- [ ] Destination volume prepared with `logs/` and `reports/` subdirectories
- [ ] Configuration file created and populated
- [ ] Source path permissions confirmed
- [ ] Dry-run backup completed with no errors
- [ ] Live backup completed with `SUCCESS` status
- [ ] Integrity verification completed with `PASS` status
- [ ] Report generated and reviewed
- [ ] Restoration tested to a non-production destination
- [ ] Scheduling configured (see `scheduling-guide.md`)

---

## Next Steps

| Topic | Document |
|---|---|
| Automate backup execution | `scheduling-guide.md` |
| Understand retention behavior | `retention-policy.md` |
| Full restoration procedures | `restoration-runbook.md` |
| Diagnose a problem | `troubleshooting.md` |
| Script syntax reference | `command-reference.md` |