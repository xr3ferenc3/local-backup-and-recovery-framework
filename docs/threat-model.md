# Threat Model

This document defines what the Local Backup and Recovery Framework
protects against, what it explicitly does not protect against, and the
operational risks an administrator must independently manage when deploying
it.

A backup tool that does not state its limitations invites misuse. This
document exists so that no operator deploys this framework under a false
assumption about what it does.

---

## What This Framework Protects Against

### Accidental file deletion or modification

The framework's primary use case. If a user deletes a file, overwrites a
document, or a file becomes corrupted, the most recent backup set or
snapshot provides a recovery point. This is the scenario the framework is
explicitly designed and tested around.

### Single-volume hardware failure (with offsite/secondary destination)

If the backup destination is a separate physical volume, external drive,
or network share from the source, a hardware failure on the source volume
does not affect the backup. This protection only holds if the operator has
configured `destination_root` to point to genuinely separate physical
storage. A destination on the same physical disk as the source provides no
protection against disk failure.

### Silent data corruption

The SHA256 manifest and spot-check verification are specifically designed
to detect corruption that would otherwise go unnoticed - a robocopy or
rsync run can report success while having transferred a truncated or
bit-flipped file. The spot-check sample, while not exhaustive, provides
meaningful confidence that data was not silently corrupted in transit.

### Untested restoration assumptions

Most backup failures are discovered at the moment of restoration, not at
the moment of backup. The guided restoration scripts, with dry-run support
and post-restore verification, are designed to make restoration testing
routine rather than exceptional. This is a process protection, not a
purely technical one - see `backup-strategy.md` for the operational
practice this requires.

### Uncontrolled retention growth

Without retention enforcement, backup destinations fill disks over time,
eventually causing backup failures at the worst possible moment. The
retention scripts, with their dry-run-by-default safety posture, prevent
both uncontrolled growth and accidental over-deletion.

---

## What This Framework Does NOT Protect Against

### Ransomware and malicious encryption

If ransomware encrypts files on the source volume and the backup
destination is continuously writable and reachable from the same host
(e.g., a mapped network drive or an always-mounted external disk), the
ransomware may also encrypt or corrupt the backup destination, or the next
scheduled backup run may faithfully copy the encrypted files over the
previous good backup set.

**Mitigation the operator must implement independently:** Use a backup
destination that is not continuously writable from the production host -
for example, a destination that is only mounted during the backup window,
or a destination with append-only or immutable storage characteristics.
This framework does not implement immutable storage; that is an
infrastructure-level decision outside its scope.

### Destination compromise

This framework does not encrypt backup data at rest. Anyone with
filesystem access to the destination can read the backed-up files in
plain text. If the destination is a network share, anyone with network
access to that share and appropriate permissions can read backup contents.

**Mitigation the operator must implement independently:** Restrict
filesystem and share permissions on the destination to the minimum
necessary accounts. Apply disk-level or volume-level encryption
(BitLocker on Windows, LUKS on Linux) if the destination contains
sensitive data and the threat model includes physical device theft.

### Source compromise prior to backup

If an attacker has already compromised the source system and planted
malicious files or modified existing files before a backup run, the
backup faithfully preserves that compromised state. This framework cannot
distinguish between a legitimate file change and a malicious one - it
backs up what exists, not what should exist.

**Mitigation the operator must implement independently:** Endpoint
detection and response, regular patching, and security baseline
hardening are out of scope for a backup tool and must be addressed
through other means.

### Catastrophic site loss

If both source and destination are in the same physical location (same
building, same site), a fire, flood, or other site-level disaster destroys
both simultaneously. This framework, used with only a local or directly
attached destination, provides no offsite protection.

**Mitigation the operator must implement independently:** Maintain at
minimum one backup copy at a separate physical location. This may be
implemented by periodically copying completed backup sets to removable
media taken offsite, or by pointing `destination_root` at a network share
hosted at a separate site. The framework's filesystem-path-based design
supports this without modification, but the operator must establish and
maintain the offsite copy process.

### Application-consistent or database-consistent backup

For Windows, VSS shadow copy support allows safe backup of open files, but
this framework does not orchestrate application-aware quiescing for
database engines (SQL Server, Exchange, etc.). A backup of live database
files using this framework's VSS support is file-consistent, not
necessarily transaction-consistent. For Linux, there is no equivalent
snapshot mechanism in use; files are read by rsync as they exist at the
moment of access, with no point-in-time guarantee across multiple files.

**Mitigation the operator must implement independently:** For any
production database workload, use the database engine's native backup
and export tooling (e.g., `mysqldump`, `pg_dump`, SQL Server native
backup) to produce a consistent export file, and then back up that export
file using this framework. Do not rely on this framework to directly back
up live database engine files.

### Multi-host or fleet-wide failure

This framework operates on a single host at a time. It includes no
mechanism for centrally managing, monitoring, or auditing backup status
across multiple hosts. In an environment with many systems, each host
requires independent configuration, scheduling, and review.

**Mitigation the operator must implement independently:** For
environments beyond a handful of hosts, a centralized monitoring or backup
management solution is appropriate. This framework's design ceiling is
intentionally the SMB single-host-to-few-hosts use case; see
`backup-strategy.md` for the reasoning behind this scope boundary.

### Insider threat with destination access

An administrator or service account with legitimate write access to the
backup destination can delete or tamper with backup sets, including
historical ones, without the framework detecting or preventing it. There
is no tamper-evidence or write-once enforcement built into this
framework.

**Mitigation the operator must implement independently:** Restrict the
number of accounts with write access to the backup destination. Consider
write-once or append-only storage characteristics at the infrastructure
level for environments where this risk is significant.

---

## Trust Boundaries

| Boundary | Trust Assumption |
|---|---|
| Source paths | Trusted to reflect the legitimate current state of the system being backed up. Not validated for malicious content. |
| Backup destination | Trusted to be reliable storage, reachable, and writable by the account running the scripts. Not assumed to be tamper-proof or encrypted. |
| Configuration file | Trusted to be accurate and maintained by an authorized operator. Not validated against an external policy or schema beyond required-field presence. |
| Log directory | Trusted to be writable and not actively tampered with between script runs. Logs are not cryptographically signed. |
| SMTP relay (if configured) | Trusted to deliver notification emails reliably. Failure to send a notification does not block or fail the underlying backup, verification, or retention operation. |

---

## Operational Risk Acceptance

By deploying this framework, an operator implicitly accepts the following
operational risks unless independently mitigated as described above:

- Backup data is unencrypted at rest unless the destination volume itself
  provides encryption.
- A continuously-writable destination is vulnerable to the same threats
  (including ransomware) as the source, unless isolated.
- Restoration is only as reliable as the operator's discipline in actually
  testing it - the framework provides the tooling, not the habit.
- Retention enforcement is destructive. Misconfiguration of
  `retain_days` or `minimum_sets_to_keep` (Windows) /
  `MINIMUM_SNAPSHOTS_TO_KEEP` (Linux) can result in earlier-than-intended
  data loss if `-Force` / `--force` is used without review of the dry-run
  output first.

---

## Recommended Minimum Security Posture

For any production deployment of this framework, the following baseline
is recommended regardless of environment size:

1. Backup destination on physically or logically separate storage from
   the source.
2. Filesystem or share permissions on the destination restricted to the
   service account or operator only.
3. At least one offsite or off-host copy of recent backup sets,
   maintained through a process outside this framework.
4. Monthly restoration testing using the dry-run and live restore
   scripts, documented via the monthly review checklist.
5. Review of retention dry-run output before the first live retention
   enforcement run in any new environment.

---

## Related Documentation

| Topic | Document |
|---|---|
| Strategic rationale for backup scope and defaults | `backup-strategy.md` |
| How to perform a safe, verified restoration | `restoration-runbook.md` |
| Retention configuration and consequences | `retention-policy.md` |
| Security considerations summary | `README.md` |