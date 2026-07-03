#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Enforces backup retention policy by purging backup sets older than the
    configured retention window, while always preserving a minimum number
    of recent sets.

.DESCRIPTION
    Set-RetentionPolicy.ps1 prevents uncontrolled disk consumption from
    accumulated backup sets. It identifies backup sets older than
    retention.retain_days and removes them, subject to a hard floor of
    retention.minimum_sets_to_keep — regardless of age, that many of the
    most recent backup sets are never deleted.

    This script defaults to dry-run behaviour unless -Force is explicitly
    passed, governed by retention.dry_run_retention_by_default in the
    configuration file. Deletion is destructive and irreversible. The
    safety default exists to prevent accidental data loss during initial
    deployment and routine operation.

    Every deletion is logged individually with the backup set name, age,
    and size, producing a complete audit trail of what was removed and why.

.PARAMETER ConfigPath
    Path to the populated JSON configuration file.

.PARAMETER Force
    Required to perform actual deletions. Without this switch, the script
    always runs as a dry run regardless of the dry_run_retention_by_default
    configuration value, UNLESS that value is explicitly false.

.EXAMPLE
    .\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json

.EXAMPLE
    .\windows\Set-RetentionPolicy.ps1 -ConfigPath .\config\windows-backup.json -Force

.NOTES
    Requires: PowerShell 5.1 or later
    Requires: Administrator privileges
    Exit code 0: Retention enforcement completed (including dry runs)
    Exit code 1: One or more deletions failed
    Exit code 2: Fatal error — configuration or destination invalid

    Reference: docs\retention-policy.md
               docs\command-reference.md
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config\windows-backup.json",

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# REGION: Constants
# =============================================================================

$SCRIPT_VERSION  = "1.0.0"
$SCRIPT_NAME     = "Set-RetentionPolicy"
$EXIT_SUCCESS    = 0
$EXIT_FAILURE    = 1
$EXIT_FATAL      = 2
$RunTimestamp    = Get-Date -Format "yyyy-MM-dd_HHmm"
$ScriptStartTime = Get-Date

$Script:HasErrors = $false

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Logging
# =============================================================================

function Write-LogEntry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][ValidateSet("DEBUG", "INFO", "WARN", "ERROR")][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory = $false)][hashtable]$Data = @{}
    )

    $levelOrder  = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
    $configLevel = if ($Script:Config) { $Script:Config.logging.log_level } else { "INFO" }
    if ($levelOrder[$Level] -lt $levelOrder[$configLevel]) { return }

    $entry = [ordered]@{
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        level     = $Level
        script    = $SCRIPT_NAME
        version   = $SCRIPT_VERSION
        message   = $Message
    }
    foreach ($key in $Data.Keys) { $entry[$key] = $Data[$key] }

    $json = $entry | ConvertTo-Json -Compress -Depth 5
    if ($Script:LogFile) { Add-Content -Path $Script:LogFile -Value $json -Encoding UTF8 }

    $colour = switch ($Level) { "DEBUG" { "Gray" }; "INFO" { "Cyan" }; "WARN" { "Yellow" }; "ERROR" { "Red" } }
    Write-Host "[$Level] $Message" -ForegroundColor $colour
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Configuration Loading
# =============================================================================

function Import-BackupConfig {
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-Path -Path $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { throw "Configuration file not found: $Path" }

    try {
        $config = Get-Content -Path $resolved.Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse configuration file: $($_.Exception.Message)"
    }

    $required = @(
        "backup.destination_root",
        "backup.backup_set_prefix",
        "retention.retain_days",
        "retention.minimum_sets_to_keep",
        "logging.log_directory"
    )
    foreach ($field in $required) {
        $parts = $field -split "\."
        $value = $config
        foreach ($part in $parts) { $value = $value.$part }
        if ($null -eq $value -or $value -eq "") { throw "Required configuration field is missing: $field" }
    }

    if ($config.retention.retain_days -lt 1) {
        throw "retention.retain_days must be at least 1. Current value: $($config.retention.retain_days)"
    }

    if ($config.retention.minimum_sets_to_keep -lt 1) {
        throw "retention.minimum_sets_to_keep must be at least 1. A value of 0 would allow deletion of all backups. Current value: $($config.retention.minimum_sets_to_keep)"
    }

    return $config
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Backup Set Discovery and Eligibility
# =============================================================================

function Get-BackupSetInventory {
    <#
    .SYNOPSIS
        Discovers all backup sets under destination_root matching the
        configured prefix, parses their embedded timestamp, and calculates
        size and age for each.
    .OUTPUTS
        Array of backup set objects sorted newest-first.
    #>
    [CmdletBinding()]
    param ()

    $destRoot = $Script:Config.backup.destination_root
    $prefix   = $Script:Config.backup.backup_set_prefix

    $candidates = Get-ChildItem -Path $destRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "${prefix}_*" }

    $inventory = @()

    foreach ($dir in $candidates) {
        # Backup set name format: {prefix}_{yyyy-MM-dd}_{HHmm}
        # Extract and parse the timestamp portion for reliable age calculation
        # independent of filesystem metadata, which can be altered by copy
        # operations, antivirus scans, or filesystem migrations.
        $namePattern = "^${prefix}_(\d{4}-\d{2}-\d{2})_(\d{4})$"
        if ($dir.Name -notmatch $namePattern) {
            Write-LogEntry -Level "WARN" -Message "Directory does not match expected backup set naming pattern — skipping from retention consideration" -Data @{ directory = $dir.Name }
            continue
        }

        $datePart = $Matches[1]
        $timePart = $Matches[2]
        $hour     = $timePart.Substring(0, 2)
        $minute   = $timePart.Substring(2, 2)

        try {
            $setDate = [datetime]::ParseExact("${datePart} ${hour}:${minute}", "yyyy-MM-dd HH:mm", $null)
        }
        catch {
            Write-LogEntry -Level "WARN" -Message "Failed to parse timestamp from backup set name — skipping from retention consideration" -Data @{ directory = $dir.Name }
            continue
        }

        $ageDays   = [math]::Round(((Get-Date) - $setDate).TotalDays, 1)
        $sizeBytes = (Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue |
                      Measure-Object -Property Length -Sum).Sum
        if (-not $sizeBytes) { $sizeBytes = 0 }

        $inventory += [pscustomobject]@{
            Name        = $dir.Name
            FullPath    = $dir.FullName
            SetDate     = $setDate
            AgeDays     = $ageDays
            SizeBytes   = $sizeBytes
            SizeGB      = [math]::Round($sizeBytes / 1GB, 3)
        }
    }

    return $inventory | Sort-Object SetDate -Descending
}

function Get-PurgeCandidates {
    <#
    .SYNOPSIS
        Determines which backup sets are eligible for purge, applying both
        the age threshold and the minimum-sets-to-keep floor.
    .DESCRIPTION
        A backup set is eligible for purge only if BOTH conditions are true:
          1. Its age exceeds retention.retain_days
          2. Removing it would not reduce the total retained set count
             below retention.minimum_sets_to_keep

        The minimum-sets floor is evaluated against the full inventory,
        not just the aged sets, ensuring at least N sets always survive
        regardless of how old they are. This protects against the scenario
        where a system has been offline long enough that all backup sets
        exceed the age threshold.
    .OUTPUTS
        Hashtable with 'purge' and 'retain' arrays.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][array]$Inventory
    )

    $retainDays = $Script:Config.retention.retain_days
    $minKeep    = $Script:Config.retention.minimum_sets_to_keep

    $totalSets = $Inventory.Count

    if ($totalSets -le $minKeep) {
        Write-LogEntry -Level "INFO" -Message "Total backup set count does not exceed minimum retention floor — no purge candidates" -Data @{
            total_sets = $totalSets
            minimum_to_keep = $minKeep
        }
        return @{ purge = @(); retain = $Inventory }
    }

    # Inventory is sorted newest-first. The first $minKeep sets are always
    # protected regardless of age.
    $protected      = $Inventory | Select-Object -First $minKeep
    $evaluationPool = $Inventory | Select-Object -Skip $minKeep

    $purgeCandidates  = $evaluationPool | Where-Object { $_.AgeDays -gt $retainDays }
    $retainedFromPool = $evaluationPool | Where-Object { $_.AgeDays -le $retainDays }

    $retainSets = @($protected) + @($retainedFromPool)

    return @{
        purge  = @($purgeCandidates)
        retain = @($retainSets)
    }
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Purge Execution
# =============================================================================

function Remove-BackupSet {
    <#
    .SYNOPSIS
        Deletes a single backup set directory and logs the deletion with
        full detail for audit purposes.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)][pscustomobject]$BackupSet,
        [Parameter(Mandatory)][bool]$IsDryRun
    )

    if ($IsDryRun) {
        Write-LogEntry -Level "INFO" -Message "[DRY RUN] Would delete backup set" -Data @{
            backup_set = $BackupSet.Name
            age_days   = $BackupSet.AgeDays
            size_gb    = $BackupSet.SizeGB
            path       = $BackupSet.FullPath
        }
        return $true
    }

    if (-not $PSCmdlet.ShouldProcess($BackupSet.FullPath, "Delete backup set")) {
        return $false
    }

    try {
        Remove-Item -Path $BackupSet.FullPath -Recurse -Force
        Write-LogEntry -Level "INFO" -Message "Backup set deleted" -Data @{
            backup_set = $BackupSet.Name
            age_days   = $BackupSet.AgeDays
            size_gb    = $BackupSet.SizeGB
            path       = $BackupSet.FullPath
        }
        return $true
    }
    catch {
        Write-LogEntry -Level "ERROR" -Message "Failed to delete backup set" -Data @{
            backup_set = $BackupSet.Name
            path       = $BackupSet.FullPath
            error      = $_.Exception.Message
        }
        return $false
    }
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Main Execution
# =============================================================================

try {
    Write-Host "`n=== $SCRIPT_NAME v$SCRIPT_VERSION ===" -ForegroundColor White

    $Script:Config = Import-BackupConfig -Path $ConfigPath

    $logDir = $Script:Config.logging.log_directory
    if (-not (Test-Path -Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $Script:LogFile = Join-Path -Path $logDir -ChildPath "${SCRIPT_NAME}_${RunTimestamp}.json"

    # Determine effective dry-run state.
    # -Force overrides the config default. Absent -Force, the config default applies.
    $configDefaultDryRun = $Script:Config.retention.dry_run_retention_by_default
    $isDryRun = if ($Force) { $false } else { [bool]$configDefaultDryRun }

    Write-LogEntry -Level "INFO" -Message "Retention enforcement started" -Data @{
        config_path           = $ConfigPath
        retain_days           = $Script:Config.retention.retain_days
        minimum_sets_to_keep  = $Script:Config.retention.minimum_sets_to_keep
        force_specified       = $Force.IsPresent
        effective_dry_run     = $isDryRun
    }

    if ($isDryRun) {
        Write-LogEntry -Level "WARN" -Message "DRY RUN MODE — no backup sets will be deleted. Pass -Force to perform actual deletions."
    }

    # -------------------------------------------------------------------------
    # Build inventory and determine purge candidates
    # -------------------------------------------------------------------------
    $inventory = Get-BackupSetInventory

    Write-LogEntry -Level "INFO" -Message "Backup set inventory built" -Data @{ total_sets = $inventory.Count }

    if ($inventory.Count -eq 0) {
        Write-LogEntry -Level "WARN" -Message "No backup sets found matching configured prefix — nothing to do" -Data @{
            destination_root = $Script:Config.backup.destination_root
            prefix            = $Script:Config.backup.backup_set_prefix
        }
        exit $EXIT_SUCCESS
    }

    $evaluation = Get-PurgeCandidates -Inventory $inventory

    Write-LogEntry -Level "INFO" -Message "Retention evaluation complete" -Data @{
        total_sets      = $inventory.Count
        purge_count     = $evaluation.purge.Count
        retain_count    = $evaluation.retain.Count
    }

    # -------------------------------------------------------------------------
    # Execute purge
    # -------------------------------------------------------------------------
    $deletedCount = 0
    $failedCount  = 0
    $deletedSizeGB = 0

    foreach ($set in $evaluation.purge) {
        $result = Remove-BackupSet -BackupSet $set -IsDryRun $isDryRun
        if ($result) {
            $deletedCount++
            $deletedSizeGB += $set.SizeGB
        }
        else {
            $failedCount++
            $Script:HasErrors = $true
        }
    }

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    $duration = [math]::Round(((Get-Date) - $ScriptStartTime).TotalSeconds, 1)
    $status   = if ($Script:HasErrors) { "COMPLETED_WITH_ERRORS" } else { "SUCCESS" }

    $summary = @{
        status              = $status
        dry_run             = $isDryRun
        total_sets_evaluated = $inventory.Count
        sets_purged         = $deletedCount
        sets_purge_failed   = $failedCount
        sets_retained       = $evaluation.retain.Count
        space_reclaimed_gb  = [math]::Round($deletedSizeGB, 3)
        duration_seconds    = $duration
        log_file            = $Script:LogFile
    }

    Write-LogEntry -Level "INFO" -Message "Retention enforcement complete" -Data $summary

    Write-Host "`n--- Retention Summary ---" -ForegroundColor White
    Write-Host "Status              : $status"
    Write-Host "Mode                : $(if ($isDryRun) { 'DRY RUN' } else { 'LIVE' })" -ForegroundColor $(if ($isDryRun) { "Yellow" } else { "White" })
    Write-Host "Total Sets          : $($inventory.Count)"
    Write-Host "Purged              : $deletedCount"
    Write-Host "Purge Failed        : $failedCount"
    Write-Host "Retained            : $($evaluation.retain.Count)"
    Write-Host "Space Reclaimed     : $($summary.space_reclaimed_gb) GB $(if ($isDryRun) { '(estimated)' })"
    Write-Host "Duration            : ${duration}s"
    Write-Host "Log File            : $($Script:LogFile)`n"

    exit $(if ($Script:HasErrors) { $EXIT_FAILURE } else { $EXIT_SUCCESS })

}
catch {
    $errMsg = $_.Exception.Message
    if ($Script:LogFile) {
        Write-LogEntry -Level "ERROR" -Message "Fatal error during retention enforcement" -Data @{ error = $errMsg }
    } else {
        Write-Host "[ERROR] Fatal error during retention enforcement: $errMsg" -ForegroundColor Red
    }
    exit $EXIT_FATAL
}

# =============================================================================
# END REGION
# =============================================================================