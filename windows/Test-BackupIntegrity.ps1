#Requires -Version 5.1

<#
.SYNOPSIS
    Verifies the integrity of a completed backup set against its source paths.

.DESCRIPTION
    Test-BackupIntegrity.ps1 performs post-backup verification using three
    independent checks:

      - File count comparison between source and backup set
      - Total byte size comparison between source and backup set
      - SHA256 hash spot-check against the manifest generated at backup time

    A backup is only as trustworthy as its verification. This script exists
    because a completed robocopy run with exit code 0-7 does not guarantee
    that every file is present, complete, and uncorrupted at the destination.

    Output is structured JSON, written to the log directory and to the
    console, and is consumed by New-BackupReport.ps1.

.PARAMETER ConfigPath
    Path to the populated JSON configuration file.

.PARAMETER BackupSet
    Name of the backup set directory to verify (e.g. WINSRV01_2025-06-15_0200).
    If omitted, the most recent backup set under destination_root is used.

.EXAMPLE
    .\windows\Test-BackupIntegrity.ps1 -ConfigPath .\config\windows-backup.json

.EXAMPLE
    .\windows\Test-BackupIntegrity.ps1 -ConfigPath .\config\windows-backup.json -BackupSet WINSRV01_2025-06-15_0200

.NOTES
    Requires: PowerShell 5.1 or later
    Requires: Read access to source paths and backup destination
    Exit code 0: Verification passed
    Exit code 1: Verification failed (one or more checks failed)
    Exit code 2: Fatal error (config invalid, backup set not found)

    Reference: docs\command-reference.md
               docs\troubleshooting.md
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config\windows-backup.json",

    [Parameter(Mandatory = $false)]
    [string]$BackupSet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# REGION: Constants
# =============================================================================

$SCRIPT_VERSION  = "1.0.0"
$SCRIPT_NAME     = "Test-BackupIntegrity"
$EXIT_PASS       = 0
$EXIT_FAIL       = 1
$EXIT_FATAL      = 2
$RunTimestamp    = Get-Date -Format "yyyy-MM-dd_HHmm"
$ScriptStartTime = Get-Date

$Script:HasFailures = $false

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Logging
# =============================================================================

function Write-LogEntry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [hashtable]$Data = @{}
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

    if ($Script:LogFile) {
        Add-Content -Path $Script:LogFile -Value $json -Encoding UTF8
    }

    $colour = switch ($Level) {
        "DEBUG" { "Gray" }; "INFO" { "Cyan" }; "WARN" { "Yellow" }; "ERROR" { "Red" }
    }
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
    if (-not $resolved) {
        throw "Configuration file not found: $Path"
    }

    try {
        $config = Get-Content -Path $resolved.Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse configuration file: $($_.Exception.Message)"
    }

    $required = @(
        "backup.source_paths",
        "backup.destination_root",
        "integrity.verify_file_count",
        "integrity.verify_size",
        "integrity.spot_check_enabled",
        "logging.log_directory"
    )
    foreach ($field in $required) {
        $parts = $field -split "\."
        $value = $config
        foreach ($part in $parts) { $value = $value.$part }
        if ($null -eq $value -and $value -ne $false) {
            throw "Required configuration field is missing: $field"
        }
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
    <#
    .SYNOPSIS
        Resolves the full path of the backup set to verify.
        If -BackupSet was not specified, selects the most recent set
        under destination_root based on directory name (which embeds a
        sortable timestamp).
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$RequestedSet)

    $destRoot = $Script:Config.backup.destination_root

    if ($RequestedSet) {
        $path = Join-Path -Path $destRoot -ChildPath $RequestedSet
        if (-not (Test-Path -Path $path)) {
            throw "Specified backup set not found: $path"
        }
        return $path
    }

    $prefix = $Script:Config.backup.backup_set_prefix
    $sets = Get-ChildItem -Path $destRoot -Directory |
            Where-Object { $_.Name -like "${prefix}_*" } |
            Sort-Object Name -Descending

    if ($sets.Count -eq 0) {
        throw "No backup sets found under destination root: $destRoot"
    }

    Write-LogEntry -Level "INFO" -Message "No backup set specified — using most recent" -Data @{ selected = $sets[0].Name }
    return $sets[0].FullName
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Verification Checks
# =============================================================================

function Test-FileCount {
    <#
    .SYNOPSIS
        Compares file count between each source path and its corresponding
        subdirectory within the backup set.
    .OUTPUTS
        Hashtable with pass/fail status and per-source detail.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$BackupSetPath
    )

    $results = @()
    $overallPass = $true

    foreach ($sourcePath in $Script:Config.backup.source_paths) {

        if (-not (Test-Path -Path $sourcePath)) {
            Write-LogEntry -Level "WARN" -Message "Source path no longer exists — skipping count check" -Data @{ source = $sourcePath }
            continue
        }

        $safeSubDir  = ($sourcePath -replace '[:\\\/]', '_').Trim('_')
        $destSubPath = Join-Path -Path $BackupSetPath -ChildPath $safeSubDir

        if (-not (Test-Path -Path $destSubPath)) {
            Write-LogEntry -Level "ERROR" -Message "Backup destination subdirectory missing for source" -Data @{ source = $sourcePath; expected = $destSubPath }
            $results += @{ source = $sourcePath; source_count = $null; dest_count = 0; pass = $false }
            $overallPass = $false
            continue
        }

        $sourceCount = (Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        $destCount   = (Get-ChildItem -Path $destSubPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count

        $pass = ($sourceCount -eq $destCount)
        if (-not $pass) { $overallPass = $false }

        $results += @{
            source       = $sourcePath
            source_count = $sourceCount
            dest_count   = $destCount
            pass         = $pass
        }

        $level = if ($pass) { "INFO" } else { "ERROR" }
        Write-LogEntry -Level $level -Message "File count check" -Data @{
            source       = $sourcePath
            source_count = $sourceCount
            dest_count   = $destCount
            pass         = $pass
        }
    }

    return @{ check = "file_count"; pass = $overallPass; details = $results }
}

function Test-TotalSize {
    <#
    .SYNOPSIS
        Compares total byte size between each source path and its
        corresponding backup destination subdirectory, within the
        configured tolerance percentage.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$BackupSetPath
    )

    $tolerance   = $Script:Config.integrity.fail_on_size_delta_percent
    $results     = @()
    $overallPass = $true

    foreach ($sourcePath in $Script:Config.backup.source_paths) {

        if (-not (Test-Path -Path $sourcePath)) { continue }

        $safeSubDir  = ($sourcePath -replace '[:\\\/]', '_').Trim('_')
        $destSubPath = Join-Path -Path $BackupSetPath -ChildPath $safeSubDir

        if (-not (Test-Path -Path $destSubPath)) {
            $results += @{ source = $sourcePath; source_bytes = $null; dest_bytes = 0; delta_percent = 100; pass = $false }
            $overallPass = $false
            continue
        }

        $sourceBytes = (Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum
        $destBytes   = (Get-ChildItem -Path $destSubPath -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum

        if (-not $sourceBytes) { $sourceBytes = 0 }
        if (-not $destBytes)   { $destBytes   = 0 }

        $deltaPercent = if ($sourceBytes -gt 0) {
            [math]::Round([math]::Abs($sourceBytes - $destBytes) / $sourceBytes * 100, 2)
        } else { 0 }

        $pass = ($deltaPercent -le $tolerance)
        if (-not $pass) { $overallPass = $false }

        $results += @{
            source        = $sourcePath
            source_bytes  = $sourceBytes
            dest_bytes    = $destBytes
            delta_percent = $deltaPercent
            pass          = $pass
        }

        $level = if ($pass) { "INFO" } else { "ERROR" }
        Write-LogEntry -Level $level -Message "Size comparison check" -Data @{
            source        = $sourcePath
            source_bytes  = $sourceBytes
            dest_bytes    = $destBytes
            delta_percent = $deltaPercent
            tolerance     = $tolerance
            pass          = $pass
        }
    }

    return @{ check = "total_size"; pass = $overallPass; details = $results }
}

function Test-SpotCheckHashes {
    <#
    .SYNOPSIS
        Selects a random sample of files from the backup set manifest and
        re-hashes them against the recorded SHA256 value.
        Detects silent corruption that file count and size checks cannot.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$BackupSetPath
    )

    $manifestPath = Join-Path -Path $BackupSetPath -ChildPath "backup.manifest"

    if (-not (Test-Path -Path $manifestPath)) {
        Write-LogEntry -Level "WARN" -Message "No manifest found — spot-check skipped" -Data @{ expected = $manifestPath }
        return @{ check = "spot_check_hash"; pass = $true; details = @(); skipped = $true; reason = "manifest_not_found" }
    }

    $manifestLines = Get-Content -Path $manifestPath -Encoding UTF8
    if ($manifestLines.Count -eq 0) {
        Write-LogEntry -Level "WARN" -Message "Manifest is empty — spot-check skipped"
        return @{ check = "spot_check_hash"; pass = $true; details = @(); skipped = $true; reason = "manifest_empty" }
    }

    $sampleSize = [math]::Min($Script:Config.integrity.spot_check_sample_size, $manifestLines.Count)
    $sample     = $manifestLines | Get-Random -Count $sampleSize

    $results     = @()
    $overallPass = $true

    foreach ($line in $sample) {
        # Manifest format: "<SHA256HASH>  <relative_path>"
        $parts = $line -split "  ", 2
        if ($parts.Count -ne 2) {
            Write-LogEntry -Level "WARN" -Message "Skipping malformed manifest line" -Data @{ line = $line }
            continue
        }
        $expectedHash = $parts[0]
        $relativePath = $parts[1]
        $fullPath     = Join-Path -Path $BackupSetPath -ChildPath $relativePath

        if (-not (Test-Path -Path $fullPath)) {
            $results += @{ file = $relativePath; expected_hash = $expectedHash; actual_hash = $null; pass = $false; reason = "file_missing" }
            $overallPass = $false
            Write-LogEntry -Level "ERROR" -Message "Spot-check file missing from backup set" -Data @{ file = $relativePath }
            continue
        }

        $actualHash = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash
        $pass       = ($actualHash -eq $expectedHash)
        if (-not $pass) { $overallPass = $false }

        $results += @{
            file          = $relativePath
            expected_hash = $expectedHash
            actual_hash   = $actualHash
            pass          = $pass
        }

        $level = if ($pass) { "DEBUG" } else { "ERROR" }
        Write-LogEntry -Level $level -Message "Spot-check hash comparison" -Data @{
            file = $relativePath
            pass = $pass
        }
    }

    return @{ check = "spot_check_hash"; pass = $overallPass; sample_size = $sampleSize; details = $results }
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

    Write-LogEntry -Level "INFO" -Message "Integrity verification started" -Data @{ config_path = $ConfigPath }

    $backupSetPath = Resolve-BackupSetPath -RequestedSet $BackupSet
    $backupSetName = Split-Path -Path $backupSetPath -Leaf

    Write-LogEntry -Level "INFO" -Message "Verifying backup set" -Data @{ backup_set = $backupSetName; path = $backupSetPath }

    $checks = @()

    if ($Script:Config.integrity.verify_file_count) {
        $checks += Test-FileCount -BackupSetPath $backupSetPath
    }

    if ($Script:Config.integrity.verify_size) {
        $checks += Test-TotalSize -BackupSetPath $backupSetPath
    }

    if ($Script:Config.integrity.spot_check_enabled) {
        $checks += Test-SpotCheckHashes -BackupSetPath $backupSetPath
    }

    $overallPass = -not ($checks | Where-Object { $_.pass -eq $false })
    $duration    = [math]::Round(((Get-Date) - $ScriptStartTime).TotalSeconds, 1)

    $summary = @{
        status           = if ($overallPass) { "PASS" } else { "FAIL" }
        backup_set       = $backupSetName
        backup_set_path  = $backupSetPath
        checks_performed = $checks.Count
        checks_passed    = ($checks | Where-Object { $_.pass }).Count
        checks_failed    = ($checks | Where-Object { -not $_.pass }).Count
        duration_seconds = $duration
        log_file         = $Script:LogFile
    }

    Write-LogEntry -Level "INFO" -Message "Integrity verification complete" -Data $summary

    Write-Host "`n--- Verification Summary ---" -ForegroundColor White
    Write-Host "Status         : $($summary.status)" -ForegroundColor $(if ($overallPass) { "Green" } else { "Red" })
    Write-Host "Backup Set     : $backupSetName"
    Write-Host "Checks Passed  : $($summary.checks_passed) / $($summary.checks_performed)"
    Write-Host "Duration       : ${duration}s"
    Write-Host "Log File       : $($Script:LogFile)`n"

    # Write full structured result (including per-check detail) for report consumption
    $fullResult = @{ summary = $summary; checks = $checks }
    $resultPath = Join-Path -Path $logDir -ChildPath "${SCRIPT_NAME}_result_${RunTimestamp}.json"
    $fullResult | ConvertTo-Json -Depth 6 | Set-Content -Path $resultPath -Encoding UTF8
    Write-LogEntry -Level "DEBUG" -Message "Full verification result written" -Data @{ path = $resultPath }

    exit $(if ($overallPass) { $EXIT_PASS } else { $EXIT_FAIL })

}
catch {
    $errMsg = $_.Exception.Message
    if ($Script:LogFile) {
        Write-LogEntry -Level "ERROR" -Message "Fatal error during verification" -Data @{ error = $errMsg }
    } else {
        Write-Host "[ERROR] Fatal error during verification: $errMsg" -ForegroundColor Red
    }
    exit $EXIT_FATAL
}

# =============================================================================
# END REGION
# =============================================================================