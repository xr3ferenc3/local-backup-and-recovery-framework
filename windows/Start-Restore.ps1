#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Performs a guided restoration of a backup set to a specified destination.

.DESCRIPTION
    Start-Restore.ps1 restores files from a completed backup set back to a
    target destination, with pre-restore validation, conflict detection,
    dry-run support, and post-restore verification.

    Restoration is the step most backup processes never test. This script
    is designed to make restoration low-friction enough that it gets tested
    regularly — not just during an actual incident.

    The script will not overwrite an existing non-empty destination unless
    -Force is explicitly specified, preventing accidental data loss during
    restoration testing.

.PARAMETER ConfigPath
    Path to the populated JSON configuration file.

.PARAMETER BackupSet
    Name of the backup set directory to restore from
    (e.g. WINSRV01_2025-06-15_0200). If omitted, the most recent backup
    set is used.

.PARAMETER SourceSubPath
    Optional. Restricts restoration to a specific subdirectory within the
    backup set (matches the safe-name subdirectory created during backup,
    e.g. C__Users_Administrator_Documents). If omitted, all subdirectories
    in the backup set are restored.

.PARAMETER Destination
    Absolute path to restore files to. Must not be the original source
    path unless -Force is specified, to prevent accidental overwrite during
    routine restoration testing.

.PARAMETER DryRun
    Validates the restoration plan and logs intended actions without
    copying any files.

.PARAMETER Force
    Allows restoration into a non-empty destination, including the
    original source path. Required for actual disaster recovery restores.
    Without -Force, the script refuses to restore into any directory
    that already contains files, by design.

.EXAMPLE
    .\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination D:\RestoreTest -DryRun

.EXAMPLE
    .\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -BackupSet WINSRV01_2025-06-15_0200 -Destination D:\RestoreTest

.EXAMPLE
    .\windows\Start-Restore.ps1 -ConfigPath .\config\windows-backup.json -Destination C:\Users\Administrator\Documents -Force

.NOTES
    Requires: PowerShell 5.1 or later
    Requires: Administrator privileges
    Exit code 0: Restoration completed successfully
    Exit code 1: Restoration completed with errors
    Exit code 2: Fatal error — restoration aborted before any files copied

    Reference: docs\restoration-runbook.md
               checklists\restoration-checklist.md
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config\windows-backup.json",

    [Parameter(Mandatory = $false)]
    [string]$BackupSet,

    [Parameter(Mandatory = $false)]
    [string]$SourceSubPath,

    [Parameter(Mandatory)]
    [string]$Destination,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# REGION: Constants
# =============================================================================

$SCRIPT_VERSION  = "1.0.0"
$SCRIPT_NAME     = "Start-Restore"
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

    $required = @("backup.destination_root", "backup.backup_set_prefix", "logging.log_directory")
    foreach ($field in $required) {
        $parts = $field -split "\."
        $value = $config
        foreach ($part in $parts) { $value = $value.$part }
        if ($null -eq $value -or $value -eq "") { throw "Required configuration field is missing: $field" }
    }

    return $config
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Backup Set Resolution
# =============================================================================

function Resolve-BackupSetPath {
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$RequestedSet)

    $destRoot = $Script:Config.backup.destination_root

    if ($RequestedSet) {
        $path = Join-Path -Path $destRoot -ChildPath $RequestedSet
        if (-not (Test-Path -Path $path)) { throw "Specified backup set not found: $path" }
        return $path
    }

    $prefix = $Script:Config.backup.backup_set_prefix
    $sets = Get-ChildItem -Path $destRoot -Directory |
            Where-Object { $_.Name -like "${prefix}_*" } |
            Sort-Object Name -Descending

    if ($sets.Count -eq 0) { throw "No backup sets found under destination root: $destRoot" }

    Write-LogEntry -Level "INFO" -Message "No backup set specified — using most recent" -Data @{ selected = $sets[0].Name }
    return $sets[0].FullName
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Pre-Restore Validation
# =============================================================================

function Test-PreRestoreConditions {
    <#
    .SYNOPSIS
        Validates the restoration plan before any files are copied.
        Checks destination state, manifest presence, and source set integrity.
    .OUTPUTS
        Hashtable describing validation result and any blocking conditions.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$BackupSetPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $blockers = @()
    $warnings = @()

    # Check backup set has a manifest — used for post-restore verification
    $manifestPath = Join-Path -Path $BackupSetPath -ChildPath "backup.manifest"
    if (-not (Test-Path -Path $manifestPath)) {
        $warnings += "No manifest found in backup set — post-restore verification will be limited to file count only."
    }

    # Check destination conflict
    if (Test-Path -Path $DestinationPath) {
        $existingItems = Get-ChildItem -Path $DestinationPath -Recurse -File -ErrorAction SilentlyContinue
        if ($existingItems.Count -gt 0 -and -not $Force) {
            $blockers += "Destination '$DestinationPath' is not empty ($($existingItems.Count) existing files). Use -Force to restore into a non-empty destination."
        }
    }

    # Check available disk space at destination
    $destDrive = (Get-Item -Path (Split-Path -Path $DestinationPath -Qualifier) -ErrorAction SilentlyContinue)
    if ($destDrive) {
        $driveLetter = (Split-Path -Path $DestinationPath -Qualifier).TrimEnd(':')
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='${driveLetter}:'"
        $backupSetSizeBytes = (Get-ChildItem -Path $BackupSetPath -Recurse -File -ErrorAction SilentlyContinue |
                                Measure-Object -Property Length -Sum).Sum
        if ($disk -and $backupSetSizeBytes -and $disk.FreeSpace -lt $backupSetSizeBytes) {
            $blockers += "Insufficient free space at destination. Required: $([math]::Round($backupSetSizeBytes/1GB,2)) GB. Available: $([math]::Round($disk.FreeSpace/1GB,2)) GB."
        }
    }

    return @{
        can_proceed = ($blockers.Count -eq 0)
        blockers    = $blockers
        warnings    = $warnings
    }
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Restoration Execution
# =============================================================================

function Invoke-RestoreCopy {
    <#
    .SYNOPSIS
        Executes robocopy to restore files from the backup set to the
        destination. Does not use /MIR — restoration is always additive,
        never destructive of pre-existing destination content beyond
        what -Force has already authorised.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $roboArgs = @(
        $SourcePath,
        $DestinationPath,
        "/E",
        "/COPYALL",
        "/DCOPY:DA",
        "/R:3",
        "/W:5",
        "/NP",
        "/NDL"
    )

    $roboLogFile = Join-Path -Path $Script:Config.logging.log_directory -ChildPath "restore_robocopy_${RunTimestamp}.log"
    $roboArgs   += "/LOG:$roboLogFile"

    if ($DryRun) {
        Write-LogEntry -Level "INFO" -Message "[DRY RUN] Would execute restore robocopy" -Data @{
            source      = $SourcePath
            destination = $DestinationPath
        }
        return $true
    }

    if (-not (Test-Path -Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    Write-LogEntry -Level "INFO" -Message "Starting restore copy" -Data @{ source = $SourcePath; destination = $DestinationPath }

    $roboProcess = Start-Process -FilePath "robocopy.exe" -ArgumentList $roboArgs -Wait -PassThru -NoNewWindow
    $exitCode    = $roboProcess.ExitCode

    if ($exitCode -ge 8) {
        Write-LogEntry -Level "ERROR" -Message "Restore copy reported failures" -Data @{
            source = $SourcePath; destination = $DestinationPath; exit_code = $exitCode; robocopy_log = $roboLogFile
        }
        $Script:HasErrors = $true
        return $false
    }

    Write-LogEntry -Level "INFO" -Message "Restore copy completed" -Data @{
        source = $SourcePath; destination = $DestinationPath; exit_code = $exitCode
    }
    return $true
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Post-Restore Verification
# =============================================================================

function Test-PostRestoreIntegrity {
    <#
    .SYNOPSIS
        Compares restored file count and a hash spot-check sample against
        the original manifest to confirm restoration completeness.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$BackupSetPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $manifestPath = Join-Path -Path $BackupSetPath -ChildPath "backup.manifest"

    $sourceFileCount = (Get-ChildItem -Path $BackupSetPath -Recurse -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -ne "backup.manifest" } | Measure-Object).Count
    $restoredFileCount = (Get-ChildItem -Path $DestinationPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count

    $countPass = ($sourceFileCount -eq $restoredFileCount)

    Write-LogEntry -Level $(if ($countPass) { "INFO" } else { "ERROR" }) -Message "Post-restore file count check" -Data @{
        backup_set_count = $sourceFileCount
        restored_count   = $restoredFileCount
        pass             = $countPass
    }

    $hashResults = @()
    $hashPass    = $true

    if (Test-Path -Path $manifestPath) {
        $manifestLines = Get-Content -Path $manifestPath -Encoding UTF8
        $sampleSize    = [math]::Min(5, $manifestLines.Count)
        $sample        = $manifestLines | Get-Random -Count $sampleSize

        foreach ($line in $sample) {
            $parts = $line -split "  ", 2
            if ($parts.Count -ne 2) { continue }
            $expectedHash = $parts[0]
            $relativePath = $parts[1]
            $restoredFile = Join-Path -Path $DestinationPath -ChildPath $relativePath

            if (-not (Test-Path -Path $restoredFile)) {
                $hashResults += @{ file = $relativePath; pass = $false; reason = "file_missing" }
                $hashPass = $false
                continue
            }

            $actualHash = (Get-FileHash -Path $restoredFile -Algorithm SHA256).Hash
            $pass = ($actualHash -eq $expectedHash)
            if (-not $pass) { $hashPass = $false }
            $hashResults += @{ file = $relativePath; pass = $pass }
        }
    }
    else {
        Write-LogEntry -Level "WARN" -Message "No manifest available — skipping post-restore hash spot-check"
    }

    return @{
        file_count_pass    = $countPass
        backup_set_count   = $sourceFileCount
        restored_count     = $restoredFileCount
        hash_spot_check    = $hashResults
        hash_spot_check_pass = $hashPass
        overall_pass       = ($countPass -and $hashPass)
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

    Write-LogEntry -Level "INFO" -Message "Restoration run started" -Data @{
        config_path  = $ConfigPath
        destination  = $Destination
        dry_run      = $DryRun.IsPresent
        force        = $Force.IsPresent
    }

    if ($DryRun) {
        Write-LogEntry -Level "WARN" -Message "DRY RUN MODE — no files will be copied"
    }

    $backupSetPath = Resolve-BackupSetPath -RequestedSet $BackupSet
    $backupSetName = Split-Path -Path $backupSetPath -Leaf

    Write-LogEntry -Level "INFO" -Message "Restoring from backup set" -Data @{ backup_set = $backupSetName; path = $backupSetPath }

    # -------------------------------------------------------------------------
    # Pre-restore validation — runs even in dry-run mode
    # -------------------------------------------------------------------------
    $validation = Test-PreRestoreConditions -BackupSetPath $backupSetPath -DestinationPath $Destination

    foreach ($warning in $validation.warnings) {
        Write-LogEntry -Level "WARN" -Message $warning
    }

    if (-not $validation.can_proceed) {
        foreach ($blocker in $validation.blockers) {
            Write-LogEntry -Level "ERROR" -Message "Restoration blocked: $blocker"
        }
        throw "Pre-restore validation failed. Restoration aborted before any files were copied. Review blockers above."
    }

    # -------------------------------------------------------------------------
    # Determine which subdirectories to restore
    # -------------------------------------------------------------------------
    if ($SourceSubPath) {
        $subDirs = @(Join-Path -Path $backupSetPath -ChildPath $SourceSubPath)
        if (-not (Test-Path -Path $subDirs[0])) {
            throw "Specified source subdirectory not found in backup set: $SourceSubPath"
        }
    }
    else {
        $subDirs = (Get-ChildItem -Path $backupSetPath -Directory).FullName
    }

    if ($subDirs.Count -eq 0) {
        throw "No restorable content found in backup set: $backupSetPath"
    }

    # -------------------------------------------------------------------------
    # Execute restoration
    # -------------------------------------------------------------------------
    $restoredCount = 0
    $failedCount   = 0

    foreach ($subDir in $subDirs) {
        $success = Invoke-RestoreCopy -SourcePath $subDir -DestinationPath $Destination
        if ($success) { $restoredCount++ } else { $failedCount++ }
    }

    # -------------------------------------------------------------------------
    # Post-restore verification
    # -------------------------------------------------------------------------
    $postRestoreResult = $null
    if (-not $DryRun) {
        $postRestoreResult = Test-PostRestoreIntegrity -BackupSetPath $backupSetPath -DestinationPath $Destination
        if (-not $postRestoreResult.overall_pass) { $Script:HasErrors = $true }
    }

    $duration = [math]::Round(((Get-Date) - $ScriptStartTime).TotalSeconds, 1)
    $status   = if ($Script:HasErrors) { "COMPLETED_WITH_ERRORS" } else { "SUCCESS" }

    $summary = @{
        status              = $status
        backup_set          = $backupSetName
        destination         = $Destination
        subdirs_restored    = $restoredCount
        subdirs_failed      = $failedCount
        dry_run             = $DryRun.IsPresent
        post_restore_check  = $postRestoreResult
        duration_seconds    = $duration
        log_file            = $Script:LogFile
    }

    Write-LogEntry -Level "INFO" -Message "Restoration run complete" -Data $summary

    Write-Host "`n--- Restoration Summary ---" -ForegroundColor White
    Write-Host "Status            : $status" -ForegroundColor $(if ($Script:HasErrors) { "Red" } else { "Green" })
    Write-Host "Backup Set        : $backupSetName"
    Write-Host "Destination       : $Destination"
    Write-Host "Subdirs Restored  : $restoredCount"
    Write-Host "Subdirs Failed    : $failedCount"
    if ($postRestoreResult) {
        Write-Host "File Count Match  : $($postRestoreResult.file_count_pass)"
        Write-Host "Hash Spot-Check   : $($postRestoreResult.hash_spot_check_pass)"
    }
    Write-Host "Duration          : ${duration}s"
    Write-Host "Log File          : $($Script:LogFile)`n"

    exit $(if ($Script:HasErrors) { $EXIT_FAILURE } else { $EXIT_SUCCESS })

}
catch {
    $errMsg = $_.Exception.Message
    if ($Script:LogFile) {
        Write-LogEntry -Level "ERROR" -Message "Fatal error — restoration aborted" -Data @{ error = $errMsg }
    } else {
        Write-Host "[ERROR] Fatal error — restoration aborted: $errMsg" -ForegroundColor Red
    }
    exit $EXIT_FATAL
}

# =============================================================================
# END REGION
# =============================================================================