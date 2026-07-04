# Backup Strategy

This document explains the strategic decisions behind this framework's
design: what to back up, how often, how long to retain it, and why the
defaults are what they are. Where a decision comes from established
practice versus a judgment call specific to this framework, that is
stated explicitly.

---

## The 3-2-1 Rule, Applied With Native Tools

The 3-2-1 backup rule is industry-standard guidance, not specific to this
framework: keep **3** copies of data, on **2** different types of storage
media, with **1** copy offsite.

This framework directly implements the "copies" and "media" portions of
the rule:

- **Copy 1:** The live source data on the production system.
- **Copy 2:** The backup set or snapshot on the configured
  `destination_root`, ideally on separate physical storage.

The **offsite** portion of the rule is intentionally **not automated** by
this framework. Native OS tooling has no built-in, dependency-free
mechanism for offsite replication that meets this project's "no cloud
infrastructure, no enterprise tools" constraint. The recommended approach,
documented in `threat-model.md`, is for the operator to periodically copy
completed backup sets to removable media or a separate-site network share
using a manual or separately scheduled process.

**This is a known and accepted scope boundary**, not an oversight. A
sysadmin operating this framework should establish their own offsite
process appropriate to their environment, and the architecture supports
this without modification - `destination_root` can point to any mounted
path, including one on a separate site.

---

## What to Back Up

### Modern guidance (not from the source books)

Neither *Mastering Windows Server 2022* nor the *RHCSA Study Guide*
prescribes a specific backup scope methodology - backup is covered at the
tool level (Windows Server Backup, `rsync`, `tar`), not at the strategic
level. The scope guidance below reflects current, industry-standard
operational practice.

**Back up:**
- User data and documents
- Application configuration that is not trivially reproducible from a
  deployment process (e.g., hand-tuned config files, custom scripts)
- Web content and site files
- Any data that, if lost, would require manual recreation

**Do not back up using this framework:**
- The operating system itself (use OS-level imaging or, ideally,
  infrastructure-as-code / reproducible provisioning instead)
- Installed application binaries (these should be reinstallable from
  source media or package managers)
- Live database engine files (see the database-consistency limitation
  in `threat-model.md`; back up database exports instead)
- Temporary files, caches, and other transient data (excluded by default
  via `exclude_directories` / `EXCLUDE_PATTERNS`)

This scope decision reflects a core operational principle: **back up what
cannot be regenerated, not what can be reinstalled.** Backing up
reinstallable software wastes storage and backup time without reducing
recovery risk.

---

## Backup Frequency

This framework does not impose a frequency - that is a scheduling
decision documented in `scheduling-guide.md`. The strategic guidance here
is about how to choose a frequency.

**General guidance:**

| Data change rate | Recommended frequency |
|---|---|
| High (active user documents, daily-changing config) | Daily |
| Moderate (web content updated periodically) | Daily to every few days |
| Low (rarely-changing reference configuration) | Weekly |

**The governing question is not "how often is convenient" but "how much
data am I willing to lose."** This is the Recovery Point Objective (RPO)
concept from standard IT operations practice - it is not covered in
either source book but is essential, current operational thinking. A
daily backup means a worst-case data loss of just under 24 hours. If that
is unacceptable for a given dataset, the frequency must increase
accordingly, which this framework supports through standard OS scheduling
(Task Scheduler / cron) at any interval the administrator configures.

---

## Retention Strategy

### Why 30 days is the default

The example configuration files default `retain_days` to 30. This balances
two competing pressures: enough history to recover from a problem that
wasn't noticed immediately, against finite disk space.

A 30-day window covers the common real-world scenario where a file
corruption, accidental deletion, or unwanted change is not discovered for
one to three weeks - longer than a naive "keep the last 7 days" policy
would survive, but not so long that storage consumption becomes
unmanageable on a typical SMB environment's available disk space.

### Why a minimum-sets floor exists independent of age

`minimum_sets_to_keep` (Windows) / `MINIMUM_SNAPSHOTS_TO_KEEP` (Linux)
exists to handle a specific failure scenario: a system that is offline,
or whose backup job silently fails, for longer than the retention window.
Without a hard floor, age-based retention alone could purge every backup
set, leaving zero recovery points at exactly the moment recovery becomes
necessary. This is a deliberate defensive design decision specific to
this framework, addressing a gap that naive "delete anything older than N
days" retention scripts commonly have.

### Why retention defaults to dry-run

Both retention scripts default to dry-run mode
(`dry_run_retention_by_default` / `DRY_RUN_RETENTION_BY_DEFAULT`).
Deletion is irreversible. A misconfigured retention window or an
unexpected directory-naming collision could otherwise destroy needed
backup history on the very first run in a new environment. Defaulting to
a preview, requiring explicit `-Force` / `--force` for actual deletion, is
a deliberate safety-first design choice for this framework.

---

## Open-File and Consistency Handling

### Windows: VSS shadow copies

*Mastering Windows Server 2022* covers Volume Shadow Copy Service as a
built-in Windows capability. This framework uses VSS to take a
point-in-time snapshot of the source volume before copying, allowing
backup of files that are open or locked by running processes (for
example, a document open in an application, or a log file actively being
written). This is current, supported, native Windows practice - not an
outdated recommendation.

### Linux: no equivalent snapshot mechanism used

The RHCSA study guide covers `rsync` as a file synchronization tool but
does not address point-in-time consistency for actively-changing files.
This framework does not orchestrate LVM snapshots or similar
filesystem-level consistency mechanisms for the Linux backup path. This
is a deliberate scope decision: LVM snapshot orchestration introduces
meaningful complexity (snapshot volume sizing, cleanup, filesystem
freeze/thaw coordination) that would push this project beyond the "low-end
laptop, no enterprise tooling" design constraint.

**Operational implication:** files actively being written to during a
Linux backup run may be captured in a partially-written state. For most
SMB use cases (user documents, configuration files, web content), this
risk is low because such files are not under constant heavy write load.
For workloads with continuously-written files, the operator should
either schedule backups during low-activity windows or implement
application-level export-then-backup patterns, as recommended for
databases in `threat-model.md`.

---

## Hard-Link Incremental Snapshots (Linux)

### Why this approach was chosen

The Linux backup path uses `rsync --link-dest` to create
hard-link-based incremental snapshots: each snapshot directory presents a
complete view of the source at that point in time, but files unchanged
since the previous snapshot consume no additional disk space, because
they are hard-linked rather than copied.

This is the standard, widely-recognized native approach to space-efficient
incremental backup on Linux without third-party tooling - it requires
only `rsync` and a filesystem that supports hard links (virtually all
Linux filesystems, including ext4 and XFS used by default on RHEL 9). It
predates and remains functionally comparable in principle to the
snapshot mechanisms in many enterprise backup products, implemented here
with built-in tools only.

### Why Windows does not use an equivalent pattern

`robocopy` does not have a direct hard-link incremental mode equivalent to
`rsync --link-dest`. Implementing true hard-link deduplication on NTFS
would require manual NTFS hard-link creation logic layered on top of
robocopy, adding meaningful complexity and fragility for a feature that
VSS-based full copies, combined with this framework's retention policy,
adequately substitute for at the SMB scale this project targets. This is
an explicit complexity-versus-benefit trade-off, not an oversight.

---

## Where Recommendations in the Source Books Are Outdated

This framework draws primarily from *Mastering Windows Server 2022* and
the *RHCSA Study Guide*, but flags the following points where modern
practice diverges from what is commonly taught in foundational material:

**Treating Windows Server Backup as the default backup answer.** Windows
Server Backup remains a valid built-in tool, but for file-level,
verifiable, scriptable backup with structured logging - the operational
needs of this framework - direct robocopy plus VSS invocation provides
more granular control and easier integration into a verification and
reporting pipeline than Windows Server Backup's image-based model. This
framework's choice reflects current scripting-first operational practice,
not a rejection of Windows Server Backup as invalid; the two serve
different purposes (image-level system recovery versus file-level data
recovery).

**Treating `cron` scheduling without monitoring as sufficient.**
Foundational Linux material commonly covers `cron` syntax without
emphasizing that an unmonitored scheduled job can fail silently for
extended periods. This framework's notification system
(`notify_on_failure` / `NOTIFY_ON_FAILURE`, defaulting to enabled) and
emphasis on structured, reviewable logs reflects current operational
practice: a scheduled backup job without failure alerting is considered
an incomplete implementation in modern operations, not a finished one.

---

## Summary of Strategic Defaults

| Decision | Default | Rationale Source |
|---|---|---|
| Retention window | 30 days | Modern practice - balances recovery window against storage |
| Minimum sets/snapshots floor | 3 | Framework-specific defensive design |
| Retention dry-run by default | Enabled | Framework-specific safety design |
| Open-file handling (Windows) | VSS shadow copy | Book-covered, current practice |
| Open-file handling (Linux) | None - scope boundary | Framework-specific scope decision |
| Incremental method (Linux) | Hard-link snapshots via rsync | Modern practice, book-adjacent (rsync is book-covered) |
| Incremental method (Windows) | Not implemented - full copy per set | Framework-specific complexity trade-off |
| Offsite replication | Not automated - manual operator process | Framework-specific scope boundary |
| Failure notification | Enabled by default | Modern practice - addresses a gap in foundational material |

---

## Related Documentation

| Topic | Document |
|---|---|
| What this framework protects against and does not | `threat-model.md` |
| How all components connect | `architecture-overview.md` |
| Detailed retention configuration | `retention-policy.md` |
| Scheduling recommendations | `scheduling-guide.md` |