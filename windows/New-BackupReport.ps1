#Requires -Version 5.1

<#
.SYNOPSIS
    Generates a structured, audit-ready report from backup and verification
    log data for a specified backup set.

.DESCRIPTION
    New-BackupReport.ps1 aggregates the JSON log output produced by
    Invoke-Backup.ps1 and Test-BackupIntegrity.ps1 into a single coherent
    report, suitable for attachment to tickets, inclusion in audit records,
    or routine management review.

    The script locates the most relevant log entries for the specified
    backup set, extracts backup execution results, integrity verification
    results, and retention status, and renders them into the configured
    output format (Markdown or JSON).

    This script does not perform any backup operations itself. It is a
    read-only reporting layer over existing log and result data.

.PARAMETER ConfigPath
    Path to the populated JSON configuration file.

.PARAMETER BackupSet
    Name of the backup set to report on (e.g. WINSRV01_2025-06-15_0200).
    If omitted, the most recent backup set is used.

.PARAMETER OutputPath
    Optional. Overrides the configured report_output_directory for this run.

.EXAMPLE
    .\windows\New-BackupReport.ps1 -ConfigPath .\config\windows-backup.json

.EXAMPLE
    .\windows\New-BackupReport.ps1 -ConfigPath .\config\windows-backup.json -BackupSet WINSRV01_2025-06-15_0200

.NOTES
    Requires: PowerShell 5.1 or later
    Exit code 0: Report generated successfully
    Exit code 1: Report generated with missing data (partial report)
    Exit code 2: Fatal error — no log data found for the backup set

    Reference: docs\command-reference.md
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config\windows-backup.json",

    [Parameter(Mandatory = $false)]
    [string]$BackupSet,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# REGION: Constants
# =============================================================================

$SCRIPT_VERSION  = "1.0.0"
$SCRIPT_NAME     = "New-BackupReport"
$EXIT_SUCCESS    = 0
$EXIT_PARTIAL    = 1
$EXIT_FATAL      = 2
$RunTimestamp    = Get-Date -Format "yyyy-MM-dd_HHmm"

$Script:IsPartial = $false

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
        "logging.log_directory",
        "reporting.report_output_directory",
        "reporting.report_format"
    )
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
        return $RequestedSet, $path
    }

    $prefix = $Script:Config.backup.backup_set_prefix
    $sets = Get-ChildItem -Path $destRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "${prefix}_*" } |
            Sort-Object Name -Descending

    if ($sets.Count -eq 0) { throw "No backup sets found under destination root: $destRoot" }

    return $sets[0].Name, $sets[0].FullName
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Log Data Extraction
# =============================================================================

function Get-BackupRunLogData {
    <#
    .SYNOPSIS
        Locates and parses the Invoke-Backup.ps1 JSON log entry containing
        the run summary for the specified backup set.
    .OUTPUTS
        Hashtable of summary data, or $null if not found.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$BackupSetName)

    $logDir = $Script:Config.logging.log_directory
    $logFiles = Get-ChildItem -Path $logDir -Filter "Invoke-Backup_*.json" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending

    foreach ($file in $logFiles) {
        $lines = Get-Content -Path $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            try {
                $entry = $line | ConvertFrom-Json
            }
            catch { continue }

            if ($entry.message -eq "Backup run complete" -and $entry.backup_set -eq $BackupSetName) {
                return $entry
            }
        }
    }

    return $null
}

function Get-IntegrityResultData {
    <#
    .SYNOPSIS
        Locates and parses the Test-BackupIntegrity.ps1 full result JSON
        file for the specified backup set.
    .OUTPUTS
        Hashtable of verification summary and check detail, or $null if
        not found.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$BackupSetName)

    $logDir = $Script:Config.logging.log_directory
    $resultFiles = Get-ChildItem -Path $logDir -Filter "Test-BackupIntegrity_result_*.json" -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending

    foreach ($file in $resultFiles) {
        try {
            $result = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch { continue }

        if ($result.summary.backup_set -eq $BackupSetName) {
            return $result
        }
    }

    return $null
}

function Get-RetentionContext {
    <#
    .SYNOPSIS
        Builds retention context for the report by counting total backup
        sets currently present and noting the configured policy.
    #>
    [CmdletBinding()]
    param ()

    $destRoot = $Script:Config.backup.destination_root
    $prefix   = $Script:Config.backup.backup_set_prefix

    $totalSets = (Get-ChildItem -Path $destRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "${prefix}_*" } | Measure-Object).Count

    return @{
        total_sets_present   = $totalSets
        retain_days           = $Script:Config.retention.retain_days
        minimum_sets_to_keep  = $Script:Config.retention.minimum_sets_to_keep
    }
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Report Rendering
# =============================================================================

function New-MarkdownReport {
    <#
    .SYNOPSIS
        Renders the collected data into a Markdown report suitable for
        tickets, audit records, and management review.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$BackupSetName,
        [Parameter(Mandatory = $false)]$BackupData,
        [Parameter(Mandatory = $false)]$IntegrityData,
        [Parameter(Mandatory)][hashtable]$RetentionContext
    )

    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("# Backup Report — $BackupSetName")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Generated:** $generatedAt")
    [void]$sb.AppendLine("**Host Prefix:** $($Script:Config.backup.backup_set_prefix)")
    [void]$sb.AppendLine("**Report Tool:** $SCRIPT_NAME v$SCRIPT_VERSION")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")

    # --- Backup Execution Section ---
    [void]$sb.AppendLine("## Backup Execution")
    [void]$sb.AppendLine("")
    if ($BackupData) {
        $statusIcon = if ($BackupData.status -eq "SUCCESS") { "PASS" } else { "ATTENTION REQUIRED" }
        [void]$sb.AppendLine("| Field | Value |")
        [void]$sb.AppendLine("|---|---|")
        [void]$sb.AppendLine("| Status | $statusIcon ($($BackupData.status)) |")
        [void]$sb.AppendLine("| Sources Total | $($BackupData.sources_total) |")
        [void]$sb.AppendLine("| Sources Succeeded | $($BackupData.sources_success) |")
        [void]$sb.AppendLine("| Sources Failed | $($BackupData.sources_failed) |")
        [void]$sb.AppendLine("| Duration | $($BackupData.duration_seconds)s |")
        [void]$sb.AppendLine("| Dry Run | $($BackupData.dry_run) |")
        [void]$sb.AppendLine("")
    }
    else {
        [void]$sb.AppendLine("**No backup execution log data found for this backup set.**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("This report may have been generated against a backup set whose logs have")
        [void]$sb.AppendLine("since rotated out, or the backup set was created outside this framework.")
        [void]$sb.AppendLine("")
        $Script:IsPartial = $true
    }

    # --- Integrity Verification Section ---
    [void]$sb.AppendLine("## Integrity Verification")
    [void]$sb.AppendLine("")
    if ($IntegrityData) {
        $summary = $IntegrityData.summary
        $statusIcon = if ($summary.status -eq "PASS") { "PASS" } else { "FAIL" }
        [void]$sb.AppendLine("| Field | Value |")
        [void]$sb.AppendLine("|---|---|")
        [void]$sb.AppendLine("| Status | $statusIcon ($($summary.status)) |")
        [void]$sb.AppendLine("| Checks Performed | $($summary.checks_performed) |")
        [void]$sb.AppendLine("| Checks Passed | $($summary.checks_passed) |")
        [void]$sb.AppendLine("| Checks Failed | $($summary.checks_failed) |")
        [void]$sb.AppendLine("")

        [void]$sb.AppendLine("### Check Detail")
        [void]$sb.AppendLine("")
        foreach ($check in $IntegrityData.checks) {
            $checkIcon = if ($check.pass) { "PASS" } else { "FAIL" }
            [void]$sb.AppendLine("**$($check.check)**: $checkIcon")
            [void]$sb.AppendLine("")
        }
    }
    else {
        [void]$sb.AppendLine("**No integrity verification data found for this backup set.**")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Run Test-BackupIntegrity.ps1 against this backup set before relying on it")
        [void]$sb.AppendLine("for restoration. An unverified backup is an unconfirmed assumption.")
        [void]$sb.AppendLine("")
        $Script:IsPartial = $true
    }

    # --- Retention Context Section ---
    [void]$sb.AppendLine("## Retention Context")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Field | Value |")
    [void]$sb.AppendLine("|---|---|")
    [void]$sb.AppendLine("| Total Backup Sets Present | $($RetentionContext.total_sets_present) |")
    [void]$sb.AppendLine("| Retention Window | $($RetentionContext.retain_days) days |")
    [void]$sb.AppendLine("| Minimum Sets Protected | $($RetentionContext.minimum_sets_to_keep) |")
    [void]$sb.AppendLine("")

    # --- Footer ---
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("*This report was generated automatically from structured log data. It is*")
    [void]$sb.AppendLine("*suitable for attachment to change tickets, incident records, and audit logs.*")

    return $sb.ToString()
}

function New-JsonReport {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$BackupSetName,
        [Parameter(Mandatory = $false)]$BackupData,
        [Parameter(Mandatory = $false)]$IntegrityData,
        [Parameter(Mandatory)][hashtable]$RetentionContext
    )

    $report = [ordered]@{
        report_generated_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        backup_set          = $BackupSetName
        host_prefix         = $Script:Config.backup.backup_set_prefix
        backup_execution    = $BackupData
        integrity_verification = $IntegrityData
        retention_context   = $RetentionContext
        is_partial_report   = $Script:IsPartial
    }

    return $report | ConvertTo-Json -Depth 8
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

    Write-Host "Resolving backup set..." -ForegroundColor Cyan
    $backupSetName, $backupSetPath = Resolve-BackupSetPath -RequestedSet $BackupSet
    Write-Host "Reporting on: $backupSetName`n" -ForegroundColor Cyan

    $backupData      = Get-BackupRunLogData -BackupSetName $backupSetName
    $integrityData   = Get-IntegrityResultData -BackupSetName $backupSetName
    $retentionContext = Get-RetentionContext

    if (-not $backupData -and -not $integrityData) {
        throw "No backup execution or integrity verification log data found for backup set '$backupSetName'. Cannot generate a meaningful report."
    }

    $format = $Script:Config.reporting.report_format
    $outputDir = if ($OutputPath) { $OutputPath } else { $Script:Config.reporting.report_output_directory }

    if (-not (Test-Path -Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    if ($format -eq "JSON") {
        $reportContent = New-JsonReport -BackupSetName $backupSetName -BackupData $backupData -IntegrityData $integrityData -RetentionContext $retentionContext
        $reportFile    = Join-Path -Path $outputDir -ChildPath "report_${backupSetName}_${RunTimestamp}.json"
    }
    else {
        $reportContent = New-MarkdownReport -BackupSetName $backupSetName -BackupData $backupData -IntegrityData $integrityData -RetentionContext $retentionContext
        $reportFile    = Join-Path -Path $outputDir -ChildPath "report_${backupSetName}_${RunTimestamp}.md"
    }

    Set-Content -Path $reportFile -Value $reportContent -Encoding UTF8

    Write-Host "--- Report Summary ---" -ForegroundColor White
    Write-Host "Backup Set      : $backupSetName"
    Write-Host "Format          : $format"
    Write-Host "Partial Report  : $($Script:IsPartial)" -ForegroundColor $(if ($Script:IsPartial) { "Yellow" } else { "Green" })
    Write-Host "Output File     : $reportFile`n"

    exit $(if ($Script:IsPartial) { $EXIT_PARTIAL } else { $EXIT_SUCCESS })

}
catch {
    Write-Host "[ERROR] Fatal error generating report: $($_.Exception.Message)" -ForegroundColor Red
    exit $EXIT_FATAL
}

# =============================================================================
# END REGION
# =============================================================================