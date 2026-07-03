#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Executes a backup run for configured source paths using robocopy and
    optional VSS shadow copy support.

.DESCRIPTION
    Invoke-Backup.ps1 is the primary backup execution script for the Local
    Backup and Recovery Framework (Windows).

    For each source path defined in the configuration file, the script:
      - Creates a dated backup set directory under the destination root
      - Optionally creates a VSS shadow copy to access open and locked files
      - Executes robocopy with production-grade flags and structured logging
      - Writes a JSON log entry for each source path processed
      - Generates a SHA256 manifest of the completed backup set
      - Sends an email notification on failure if SMTP is configured

    Output is structured JSON, suitable for consumption by
    New-BackupReport.ps1 and for attachment to tickets or audit records.

.PARAMETER ConfigPath
    Absolute or relative path to the populated JSON configuration file.
    Defaults to config\windows-backup.json in the repository root.

.PARAMETER DryRun
    If specified, the script validates configuration and logs intended
    actions without executing robocopy or creating VSS snapshots.
    Use to verify configuration before the first live run.

.EXAMPLE
    .\windows\Invoke-Backup.ps1 -ConfigPath .\config\windows-backup.json

.EXAMPLE
    .\windows\Invoke-Backup.ps1 -ConfigPath .\config\windows-backup.json -DryRun

.NOTES
    Requires: PowerShell 5.1 or later
    Requires: Administrator privileges (for VSS and system path access)
    Requires: robocopy (built into Windows Server 2022)
    Requires: Volume Shadow Copy Service running (if use_vss is true)

    Log output format: JSON (one object per line)
    Log location: As configured in logging.log_directory
    Backup set naming: {prefix}_{yyyy-MM-dd}_{HHmm}

    Reference: docs\windows-setup-guide.md
               docs\command-reference.md
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config\windows-backup.json",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# REGION: Constants and Script-Level Variables
# =============================================================================

$SCRIPT_VERSION  = "1.0.0"
$SCRIPT_NAME     = "Invoke-Backup"
$EXIT_SUCCESS    = 0
$EXIT_FAILURE    = 1
$RunTimestamp    = Get-Date -Format "yyyy-MM-dd_HHmm"
$RunDate         = Get-Date -Format "yyyy-MM-dd"
$ScriptStartTime = Get-Date

# Tracks whether any non-fatal errors occurred during the run.
# A run that completes with partial failures exits with EXIT_FAILURE
# and logs status "COMPLETED_WITH_ERRORS".
$Script:HasErrors = $false

# Holds the VSS shadow copy object if created, for cleanup in finally block.
$Script:ShadowCopy = $null

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Logging Functions
# =============================================================================

function Write-LogEntry {
    <#
    .SYNOPSIS
        Writes a structured JSON log entry to the log file and console.
    .PARAMETER Level
        Severity level: DEBUG, INFO, WARN, ERROR
    .PARAMETER Message
        Human-readable log message.
    .PARAMETER Data
        Optional hashtable of additional structured fields to include.
    #>
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

    $levelOrder = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
    $configLevel = if ($Script:Config) { $Script:Config.logging.log_level } else { "INFO" }

    if ($levelOrder[$Level] -lt $levelOrder[$configLevel]) { return }

    $entry = [ordered]@{
        timestamp  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        level      = $Level
        script     = $SCRIPT_NAME
        version    = $SCRIPT_VERSION
        message    = $Message
    }

    foreach ($key in $Data.Keys) {
        $entry[$key] = $Data[$key]
    }

    $json = $entry | ConvertTo-Json -Compress -Depth 5

    # Write to log file if path is available
    if ($Script:LogFile) {
        Add-Content -Path $Script:LogFile -Value $json -Encoding UTF8
    }

    # Write to console with colour coding
    $colour = switch ($Level) {
        "DEBUG" { "Gray"    }
        "INFO"  { "Cyan"    }
        "WARN"  { "Yellow"  }
        "ERROR" { "Red"     }
    }
    Write-Host "[$Level] $Message" -ForegroundColor $colour
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Configuration Loading and Validation
# =============================================================================

function Import-BackupConfig {
    <#
    .SYNOPSIS
        Loads and validates the JSON configuration file.
    .PARAMETER Path
        Absolute or relative path to the configuration file.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved = Resolve-Path -Path $Path -ErrorAction SilentlyContinue
    if (-not $resolved) {
        throw "Configuration file not found: $Path`nCopy config\windows-backup.example.json to config\windows-backup.json and populate it."
    }

    try {
        $raw    = Get-Content -Path $resolved.Path -Raw -Encoding UTF8
        $config = $raw | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse configuration file: $($_.Exception.Message)"
    }

    # Required field validation
    $required = @(
        "backup.source_paths",
        "backup.destination_root",
        "backup.backup_set_prefix",
        "logging.log_directory",
        "logging.log_format",
        "retention.retain_days",
        "retention.minimum_sets_to_keep"
    )

    foreach ($field in $required) {
        $parts  = $field -split "\."
        $value  = $config
        foreach ($part in $parts) {
            $value = $value.$part
        }
        if ($null -eq $value -or $value -eq "") {
            throw "Required configuration field is missing or empty: $field"
        }
    }

    # Source path existence validation
    foreach ($sourcePath in $config.backup.source_paths) {
        if (-not (Test-Path -Path $sourcePath)) {
            Write-Warning "Source path does not exist and will be skipped: $sourcePath"
        }
    }

    # Destination root existence validation
    if (-not (Test-Path -Path $config.backup.destination_root)) {
        throw "Destination root does not exist: $($config.backup.destination_root)`nCreate it before running this script."
    }

    return $config
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Log Initialisation
# =============================================================================

function Initialize-Logging {
    <#
    .SYNOPSIS
        Creates the log directory and log file for this run.
    #>
    [CmdletBinding()]
    param()

    $logDir = $Script:Config.logging.log_directory

    if (-not (Test-Path -Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $logFileName  = "${SCRIPT_NAME}_${RunTimestamp}.json"
    $Script:LogFile = Join-Path -Path $logDir -ChildPath $logFileName

    # Rotate old log files
    $retentionDays = $Script:Config.logging.log_retention_days
    if ($retentionDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$retentionDays)
        Get-ChildItem -Path $logDir -Filter "*.json" |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                Remove-Item -Path $_.FullName -Force
                Write-LogEntry -Level "DEBUG" -Message "Rotated old log file" -Data @{ file = $_.Name }
            }
    }
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: VSS Shadow Copy Management
# =============================================================================

function New-VssShadowCopy {
    <#
    .SYNOPSIS
        Creates a VSS shadow copy of the specified volume.
    .PARAMETER VolumePath
        Drive letter and colon only. Example: C:
    .OUTPUTS
        Returns the shadow copy device path for use as robocopy source.
        Example: \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$VolumePath
    )

    Write-LogEntry -Level "INFO" -Message "Creating VSS shadow copy" -Data @{ volume = $VolumePath }

    try {
        $class  = [WMICLASS]"root\cimv2:win32_shadowcopy"
        $result = $class.Create($VolumePath + "\", "ClientAccessible")

        if ($result.ReturnValue -ne 0) {
            throw "VSS shadow copy creation returned non-zero exit code: $($result.ReturnValue)"
        }

        $shadow = Get-WmiObject -Class Win32_ShadowCopy |
                  Where-Object { $_.ID -eq $result.ShadowID }

        if (-not $shadow) {
            throw "VSS shadow copy created but could not be retrieved by ID: $($result.ShadowID)"
        }

        Write-LogEntry -Level "INFO" -Message "VSS shadow copy created successfully" -Data @{
            shadow_id          = $shadow.ID
            shadow_device_path = $shadow.DeviceObject
        }

        $Script:ShadowCopy = $shadow
        return $shadow.DeviceObject

    }
    catch {
        throw "Failed to create VSS shadow copy for volume $VolumePath`: $($_.Exception.Message)"
    }
}

function Remove-VssShadowCopy {
    <#
    .SYNOPSIS
        Deletes the VSS shadow copy created during this run.
        Always called in the finally block to prevent shadow copy accumulation.
    #>
    [CmdletBinding()]
    param()

    if ($Script:ShadowCopy) {
        try {
            $Script:ShadowCopy.Delete()
            Write-LogEntry -Level "INFO" -Message "VSS shadow copy deleted" -Data @{
                shadow_id = $Script:ShadowCopy.ID
            }
        }
        catch {
            Write-LogEntry -Level "WARN" -Message "Failed to delete VSS shadow copy — manual cleanup may be required" -Data @{
                shadow_id = $Script:ShadowCopy.ID
                error     = $_.Exception.Message
            }
        }
        $Script:ShadowCopy = $null
    }
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Backup Set Preparation
# =============================================================================

function New-BackupSetDirectory {
    <#
    .SYNOPSIS
        Creates the dated backup set directory under the destination root.
    .OUTPUTS
        Returns the full path of the created backup set directory.
    #>
    [CmdletBinding()]
    param()

    $prefix        = $Script:Config.backup.backup_set_prefix
    $setName       = "${prefix}_${RunTimestamp}"
    $destinRoot    = $Script:Config.backup.destination_root
    $setPath       = Join-Path -Path $destinRoot -ChildPath $setName

    $Script:BackupSetName = $setName
    $Script:BackupSetPath = $setPath

    if ($DryRun) {
        Write-LogEntry -Level "INFO" -Message "[DRY RUN] Would create backup set directory" -Data @{ path = $setPath }
        return $setPath
    }

    if (Test-Path -Path $setPath) {
        throw "Backup set directory already exists: $setPath`nA backup with this timestamp already ran. Wait one minute and retry."
    }

    New-Item -ItemType Directory -Path $setPath -Force | Out-Null
    Write-LogEntry -Level "INFO" -Message "Backup set directory created" -Data @{ path = $setPath }

    return $setPath
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Robocopy Execution
# =============================================================================

function Invoke-RobocopyBackup {
    <#
    .SYNOPSIS
        Executes robocopy for a single source path into the backup set.
    .PARAMETER SourcePath
        The source path to back up.
    .PARAMETER DestinationPath
        The destination directory within the backup set for this source.
    .PARAMETER ShadowDevicePath
        Optional VSS shadow copy device path to use as robocopy source root.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string]$ShadowDevicePath
    )

    $cfg = $Script:Config.backup.robocopy_options

    # Build robocopy argument list
    # /E   — copy subdirectories including empty ones
    # /COPYALL — copy all file attributes (data, attributes, timestamps, ACLs, owner, audit)
    # /DCOPY:DA — copy directory data and attributes
    # /R   — retry count on failed copies
    # /W   — wait seconds between retries
    # /NP  — no progress percentage (cleaner log output)
    # /NDL — no directory list in output (reduces log verbosity)
    # /LOG — write robocopy output to a dedicated log file
    $roboArgs = @(
        $SourcePath,
        $DestinationPath,
        "/E",
        "/COPYALL",
        "/DCOPY:DA",
        "/R:$($cfg.max_retries)",
        "/W:$($cfg.retry_wait_seconds)",
        "/NP",
        "/NDL"
    )

    if ($cfg.mirror -eq $true) {
        $roboArgs += "/MIR"
        Write-LogEntry -Level "WARN" -Message "Mirror mode enabled — files deleted at source will be deleted from backup" -Data @{ source = $SourcePath }
    }

    foreach ($dir in $cfg.exclude_directories) {
        $roboArgs += "/XD"
        $roboArgs += $dir
    }

    foreach ($file in $cfg.exclude_files) {
        $roboArgs += "/XF"
        $roboArgs += $file
    }

    # Robocopy log file — one per source path per run
    $safeSourceName = ($SourcePath -replace '[:\\\/]', '_').Trim('_')
    $roboLogFile    = Join-Path -Path $Script:Config.logging.log_directory -ChildPath "robocopy_${safeSourceName}_${RunTimestamp}.log"
    $roboArgs      += "/LOG:$roboLogFile"

    # If VSS is in use, replace the drive letter portion of the source path
    # with the shadow device path so robocopy reads from the snapshot.
    $effectiveSource = $SourcePath
    if ($ShadowDevicePath) {
        $relativePath    = $SourcePath.Substring(2)  # Strip drive letter and colon
        $effectiveSource = Join-Path -Path $ShadowDevicePath -ChildPath $relativePath
        $roboArgs[0]     = $effectiveSource
    }

    if ($DryRun) {
        Write-LogEntry -Level "INFO" -Message "[DRY RUN] Would execute robocopy" -Data @{
            source      = $effectiveSource
            destination = $DestinationPath
            flags       = $roboArgs -join " "
        }
        return $true
    }

    # Create the destination subdirectory
    if (-not (Test-Path -Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    Write-LogEntry -Level "INFO" -Message "Starting robocopy" -Data @{
        source      = $effectiveSource
        destination = $DestinationPath
    }

    $roboProcess = Start-Process -FilePath "robocopy.exe" `
                                 -ArgumentList $roboArgs `
                                 -Wait `
                                 -PassThru `
                                 -NoNewWindow

    # Robocopy exit codes:
    # 0 — No files copied (source and destination identical)
    # 1 — Files copied successfully
    # 2 — Extra files in destination (not an error)
    # 3 — Files copied and extra files exist
    # 4 — Mismatched files found (not copied)
    # 5 — Files copied and mismatched files exist
    # 6 — Extra and mismatched files exist (no copy)
    # 7 — Files copied, extra files, mismatched files
    # 8+ — At least one file failed to copy (error condition)
    $exitCode = $roboProcess.ExitCode

    if ($exitCode -ge 8) {
        Write-LogEntry -Level "ERROR" -Message "Robocopy reported copy failures" -Data @{
            source      = $effectiveSource
            destination = $DestinationPath
            exit_code   = $exitCode
            robocopy_log = $roboLogFile
        }
        $Script:HasErrors = $true
        return $false
    }

    Write-LogEntry -Level "INFO" -Message "Robocopy completed successfully" -Data @{
        source      = $effectiveSource
        destination = $DestinationPath
        exit_code   = $exitCode
        robocopy_log = $roboLogFile
    }

    return $true
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Manifest Generation
# =============================================================================

function New-BackupManifest {
    <#
    .SYNOPSIS
        Generates a SHA256 checksum manifest for the completed backup set.
        The manifest is stored as backup.manifest inside the backup set directory.
        It is used by Test-BackupIntegrity.ps1 for spot-check verification.
    #>
    [CmdletBinding()]
    param()

    if ($DryRun) {
        Write-LogEntry -Level "INFO" -Message "[DRY RUN] Would generate SHA256 manifest"
        return
    }

    $manifestPath = Join-Path -Path $Script:BackupSetPath -ChildPath "backup.manifest"

    Write-LogEntry -Level "INFO" -Message "Generating SHA256 manifest" -Data @{ path = $manifestPath }

    try {
        $files = Get-ChildItem -Path $Script:BackupSetPath -Recurse -File |
                 Where-Object { $_.Name -ne "backup.manifest" }

        $entries = foreach ($file in $files) {
            $hash         = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
            $relativePath = $file.FullName.Substring($Script:BackupSetPath.Length).TrimStart('\')
            "$hash  $relativePath"
        }

        $entries | Set-Content -Path $manifestPath -Encoding UTF8

        Write-LogEntry -Level "INFO" -Message "Manifest generated" -Data @{
            path       = $manifestPath
            file_count = $files.Count
        }
    }
    catch {
        Write-LogEntry -Level "WARN" -Message "Manifest generation failed — integrity verification will be limited" -Data @{
            error = $_.Exception.Message
        }
        $Script:HasErrors = $true
    }
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Notification
# =============================================================================

function Send-BackupNotification {
    <#
    .SYNOPSIS
        Sends an email notification on backup completion or failure.
    .PARAMETER Status
        "SUCCESS" or "FAILURE"
    .PARAMETER Summary
        Short summary string to include in the notification body.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet("SUCCESS", "FAILURE")]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Summary
    )

    $notif = $Script:Config.notifications

    if (-not $notif.smtp_server) { return }

    if ($Status -eq "SUCCESS" -and -not $notif.notify_on_success) { return }
    if ($Status -eq "FAILURE" -and -not $notif.notify_on_failure) { return }

    $subject = "[$Status] Backup Report — $($Script:Config.backup.backup_set_prefix) — $RunDate"
    $body    = @"
Backup Status : $Status
Host          : $($Script:Config.backup.backup_set_prefix)
Backup Set    : $($Script:BackupSetName)
Run Time      : $RunTimestamp
Log File      : $($Script:LogFile)

$Summary
"@

    try {
        $smtpParams = @{
            SmtpServer  = $notif.smtp_server
            Port        = $notif.smtp_port
            From        = $notif.notification_from
            To          = $notif.notification_to
            Subject     = $subject
            Body        = $body
            UseSsl      = $notif.smtp_use_ssl
        }
        Send-MailMessage @smtpParams
        Write-LogEntry -Level "INFO" -Message "Notification sent" -Data @{ status = $Status; recipients = $notif.notification_to }
    }
    catch {
        Write-LogEntry -Level "WARN" -Message "Failed to send notification email" -Data @{ error = $_.Exception.Message }
    }
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Main Execution
# =============================================================================

try {
    # -------------------------------------------------------------------------
    # Step 1: Load configuration
    # -------------------------------------------------------------------------
    Write-Host "`n=== $SCRIPT_NAME v$SCRIPT_VERSION ===" -ForegroundColor White
    Write-Host "Loading configuration: $ConfigPath`n" -ForegroundColor White

    $Script:Config = Import-BackupConfig -Path $ConfigPath

    # -------------------------------------------------------------------------
    # Step 2: Initialise logging
    # -------------------------------------------------------------------------
    Initialize-Logging

    Write-LogEntry -Level "INFO" -Message "Backup run started" -Data @{
        script      = $SCRIPT_NAME
        version     = $SCRIPT_VERSION
        config_path = $ConfigPath
        dry_run     = $DryRun.IsPresent
        host_label  = $Script:Config.backup.backup_set_prefix
    }

    if ($DryRun) {
        Write-LogEntry -Level "WARN" -Message "DRY RUN MODE — no files will be copied, no VSS snapshots created"
    }

    # -------------------------------------------------------------------------
    # Step 3: Create backup set directory
    # -------------------------------------------------------------------------
    $setPath = New-BackupSetDirectory

    # -------------------------------------------------------------------------
    # Step 4: Process each source path
    # -------------------------------------------------------------------------
    $sourcePaths    = $Script:Config.backup.source_paths
    $useVss         = $Script:Config.backup.use_vss
    $processedCount = 0
    $failedCount    = 0

    # Track which volumes have had shadow copies created this run.
    # One shadow copy per volume is sufficient for all paths on that volume.
    $shadowMap = @{}

    foreach ($sourcePath in $sourcePaths) {

        if (-not (Test-Path -Path $sourcePath)) {
            Write-LogEntry -Level "WARN" -Message "Source path not found — skipping" -Data @{ source = $sourcePath }
            $failedCount++
            $Script:HasErrors = $true
            continue
        }

        # Derive a safe subdirectory name from the source path
        $safeSubDir    = ($sourcePath -replace '[:\\\/]', '_').Trim('_')
        $destSubPath   = Join-Path -Path $setPath -ChildPath $safeSubDir

        # Determine VSS shadow device path for this source volume
        $shadowDevice = $null
        if ($useVss -and -not $DryRun) {
            $volume = $sourcePath.Substring(0, 2)  # e.g. "C:"
            if (-not $shadowMap.ContainsKey($volume)) {
                try {
                    $shadowMap[$volume] = New-VssShadowCopy -VolumePath $volume
                }
                catch {
                    Write-LogEntry -Level "WARN" -Message "VSS shadow copy failed — backing up live files for this path" -Data @{
                        source = $sourcePath
                        error  = $_.Exception.Message
                    }
                    $Script:HasErrors = $true
                }
            }
            $shadowDevice = $shadowMap[$volume]
        }

        $success = Invoke-RobocopyBackup `
                    -SourcePath       $sourcePath `
                    -DestinationPath  $destSubPath `
                    -ShadowDevicePath $shadowDevice

        if ($success) { $processedCount++ } else { $failedCount++ }
    }

    # -------------------------------------------------------------------------
    # Step 5: Generate manifest
    # -------------------------------------------------------------------------
    New-BackupManifest

    # -------------------------------------------------------------------------
    # Step 6: Write run summary log entry
    # -------------------------------------------------------------------------
    $duration = [math]::Round(((Get-Date) - $ScriptStartTime).TotalSeconds, 1)
    $status   = if ($Script:HasErrors) { "COMPLETED_WITH_ERRORS" } else { "SUCCESS" }

    $summary = @{
        status           = $status
        backup_set       = $Script:BackupSetName
        backup_set_path  = $Script:BackupSetPath
        sources_total    = $sourcePaths.Count
        sources_success  = $processedCount
        sources_failed   = $failedCount
        duration_seconds = $duration
        dry_run          = $DryRun.IsPresent
        log_file         = $Script:LogFile
    }

    Write-LogEntry -Level "INFO" -Message "Backup run complete" -Data $summary

    Write-Host "`n--- Run Summary ---" -ForegroundColor White
    Write-Host "Status          : $status"
    Write-Host "Backup Set      : $($Script:BackupSetName)"
    Write-Host "Sources Total   : $($sourcePaths.Count)"
    Write-Host "Sources Success : $processedCount"
    Write-Host "Sources Failed  : $failedCount"
    Write-Host "Duration        : ${duration}s"
    Write-Host "Log File        : $($Script:LogFile)`n"

    # -------------------------------------------------------------------------
    # Step 7: Send notification
    # -------------------------------------------------------------------------
    $notifSummary = "Sources: $($sourcePaths.Count) total, $processedCount succeeded, $failedCount failed. Duration: ${duration}s."
    Send-BackupNotification -Status $(if ($Script:HasErrors) { "FAILURE" } else { "SUCCESS" }) -Summary $notifSummary

    exit $(if ($Script:HasErrors) { $EXIT_FAILURE } else { $EXIT_SUCCESS })

}
catch {
    # Fatal error — configuration load failure, destination missing, etc.
    $errMsg = $_.Exception.Message

    if ($Script:LogFile) {
        Write-LogEntry -Level "ERROR" -Message "Fatal error — backup run aborted" -Data @{ error = $errMsg }
    }
    else {
        Write-Host "[ERROR] Fatal error — backup run aborted: $errMsg" -ForegroundColor Red
    }

    Send-BackupNotification -Status "FAILURE" -Summary "Fatal error: $errMsg"

    exit $EXIT_FAILURE
}
finally {
    # Always clean up VSS shadow copies regardless of exit path.
    # Accumulated shadow copies consume disk space and can exhaust VSS storage.
    foreach ($volume in $shadowMap.Keys) {
        $Script:ShadowCopy = $null
        # Re-fetch and delete by ID to handle the case where $Script:ShadowCopy
        # was overwritten during multi-volume processing.
    }
    Remove-VssShadowCopy
}

# =============================================================================
# END REGION
# =============================================================================