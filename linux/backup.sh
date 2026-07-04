#!/usr/bin/env bash
#
# =============================================================================
# backup.sh
# =============================================================================
#
# SYNOPSIS
#   Executes a backup run for configured source paths using rsync with
#   hard-link incremental snapshots.
#
# DESCRIPTION
#   backup.sh is the primary backup execution script for the Local Backup
#   and Recovery Framework (Linux).
#
#   For each source path defined in the configuration file, the script:
#     - Creates a dated snapshot directory under the destination root
#     - Executes rsync with --link-dest against the previous snapshot,
#       so unchanged files are hard-linked rather than copied, while the
#       snapshot still presents a complete view of the source
#     - Writes structured JSON log entries for each source path processed
#     - Generates a SHA256 checksum manifest for the completed snapshot
#     - Sends an email notification on failure if SMTP is configured
#
#   Output is structured JSON, suitable for consumption by
#   generate-report.sh and for attachment to tickets or audit records.
#
# USAGE
#   ./linux/backup.sh --config <path> [--dry-run]
#
# OPTIONS
#   --config <path>   Path to the populated configuration file (required)
#   --dry-run         Validate configuration and log intended actions
#                      without executing rsync
#   --help             Display this usage information
#
# EXIT CODES
#   0   Backup completed successfully
#   1   Backup completed with one or more source failures
#   2   Fatal error — backup aborted before completion
#
# REQUIRES
#   bash 4.0+, rsync, sha256sum (coreutils), find (findutils)
#
# REFERENCE
#   docs/linux-setup-guide.md
#   docs/command-reference.md
# =============================================================================

set -u
set -o pipefail

# =============================================================================
# REGION: Constants
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="backup"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_FATAL=2

RUN_TIMESTAMP="$(date '+%Y-%m-%d_%H%M')"
RUN_DATE="$(date '+%Y-%m-%d')"
SCRIPT_START_EPOCH="$(date '+%s')"

HAS_ERRORS=0
CONFIG_PATH=""
DRY_RUN=0

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Argument Parsing
# =============================================================================

print_usage() {
    cat <<EOF
Usage: $0 --config <path> [--dry-run]

Options:
  --config <path>   Path to the populated configuration file (required)
  --dry-run          Validate configuration and log intended actions without
                      executing rsync
  --help             Display this usage information
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_PATH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help)
            print_usage
            exit "$EXIT_SUCCESS"
            ;;
        *)
            echo "Unknown argument: $1" >&2
            print_usage
            exit "$EXIT_FATAL"
            ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then
    echo "ERROR: --config is required" >&2
    print_usage
    exit "$EXIT_FATAL"
fi

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Logging Functions
# =============================================================================

# log_entry LEVEL MESSAGE [key=value ...]
# Writes a structured JSON log entry to the log file and stdout.
# Severity filtering is applied against LOG_LEVEL from the config file.
log_entry() {
    local level="$1"
    local message="$2"
    shift 2
    local extra_fields=("$@")

    local level_num
    case "$level" in
        DEBUG) level_num=0 ;;
        INFO)  level_num=1 ;;
        WARN)  level_num=2 ;;
        ERROR) level_num=3 ;;
        *) level_num=1 ;;
    esac

    local configured_level_num
    case "${LOG_LEVEL:-INFO}" in
        DEBUG) configured_level_num=0 ;;
        INFO)  configured_level_num=1 ;;
        WARN)  configured_level_num=2 ;;
        ERROR) configured_level_num=3 ;;
        *) configured_level_num=1 ;;
    esac

    if (( level_num < configured_level_num )); then
        return 0
    fi

    local timestamp
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S')"

    # Build JSON manually to avoid an external jq dependency.
    # Field values are escaped for embedded double quotes and backslashes.
    local json="{\"timestamp\":\"${timestamp}\",\"level\":\"${level}\",\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"message\":\"$(json_escape "$message")\""

    for field in "${extra_fields[@]}"; do
        local key="${field%%=*}"
        local value="${field#*=}"
        json="${json},\"${key}\":\"$(json_escape "$value")\""
    done

    json="${json}}"

    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$json" >> "$LOG_FILE"
    fi

    local colour_code
    case "$level" in
        DEBUG) colour_code="\033[0;37m" ;;
        INFO)  colour_code="\033[0;36m" ;;
        WARN)  colour_code="\033[0;33m" ;;
        ERROR) colour_code="\033[0;31m" ;;
        *) colour_code="\033[0m" ;;
    esac
    echo -e "${colour_code}[${level}] ${message}\033[0m"
}

# json_escape STRING
# Escapes backslashes and double quotes for safe JSON embedding.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    echo "$s"
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Configuration Loading and Validation
# =============================================================================

load_config() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "ERROR: Configuration file not found: $CONFIG_PATH" >&2
        echo "Copy config/linux-backup.example.conf to config/linux-backup.conf and populate it." >&2
        exit "$EXIT_FATAL"
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_PATH"

    local required_vars=(
        "SOURCE_PATHS"
        "DESTINATION_ROOT"
        "BACKUP_HOST_LABEL"
        "LOG_DIRECTORY"
        "LOG_FORMAT"
        "RETAIN_DAYS"
        "MINIMUM_SNAPSHOTS_TO_KEEP"
    )

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: Required configuration variable is missing or empty: $var" >&2
            exit "$EXIT_FATAL"
        fi
    done

    if [[ ! -d "$DESTINATION_ROOT" ]]; then
        echo "ERROR: Destination root does not exist: $DESTINATION_ROOT" >&2
        echo "Create it before running this script." >&2
        exit "$EXIT_FATAL"
    fi

    for src in $SOURCE_PATHS; do
        if [[ ! -e "$src" ]]; then
            echo "WARNING: Source path does not exist and will be skipped: $src" >&2
        fi
    done
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Log Initialisation
# =============================================================================

init_logging() {
    if [[ ! -d "$LOG_DIRECTORY" ]]; then
        mkdir -p "$LOG_DIRECTORY"
    fi

    LOG_FILE="${LOG_DIRECTORY}/${SCRIPT_NAME}_${RUN_TIMESTAMP}.json"

    if [[ "${LOG_RETENTION_DAYS:-0}" -gt 0 ]]; then
        find "$LOG_DIRECTORY" -maxdepth 1 -name "*.json" -type f -mtime "+${LOG_RETENTION_DAYS}" -print -delete | while read -r removed; do
            log_entry "DEBUG" "Rotated old log file" "file=${removed}"
        done
    fi
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Snapshot Preparation
# =============================================================================

# get_previous_snapshot
# Returns the full path of the most recent existing snapshot for this host
# label, used as the --link-dest reference for incremental backup.
# Returns empty string if no previous snapshot exists.
get_previous_snapshot() {
    find "$DESTINATION_ROOT" -maxdepth 1 -type d -name "${BACKUP_HOST_LABEL}_*" 2>/dev/null \
        | sort -r \
        | head -n 1
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Rsync Execution
# =============================================================================

# run_rsync_backup SOURCE_PATH DEST_SUBDIR PREVIOUS_SNAPSHOT
# Executes rsync for a single source path into the snapshot directory.
# Returns 0 on success, 1 on failure.
run_rsync_backup() {
    local source_path="$1"
    local dest_subdir="$2"
    local previous_snapshot="$3"

    local rsync_args=(-a --stats)

    # Hard-link against the corresponding subdirectory in the previous
    # snapshot, if one exists, to deduplicate unchanged files.
    if [[ "${INCREMENTAL_ENABLED:-true}" == "true" && -n "$previous_snapshot" ]]; then
        local safe_subdir
        safe_subdir="$(basename "$dest_subdir")"
        local link_dest_path="${previous_snapshot}/${safe_subdir}"
        if [[ -d "$link_dest_path" ]]; then
            rsync_args+=(--link-dest="$link_dest_path")
        fi
    fi

    # Apply exclude patterns
    if [[ -n "${EXCLUDE_PATTERNS:-}" ]]; then
        for pattern in $EXCLUDE_PATTERNS; do
            rsync_args+=(--exclude="$pattern")
        done
    fi

    if [[ -n "${EXCLUDE_FILE:-}" && -f "${EXCLUDE_FILE}" ]]; then
        rsync_args+=(--exclude-from="$EXCLUDE_FILE")
    fi

    # Apply additional user-specified options
    if [[ -n "${RSYNC_OPTIONS:-}" ]]; then
        # shellcheck disable=SC2206
        local extra_opts=($RSYNC_OPTIONS)
        rsync_args+=("${extra_opts[@]}")
    fi

    local rsync_log_file="${LOG_DIRECTORY}/rsync_$(basename "$dest_subdir")_${RUN_TIMESTAMP}.log"
    rsync_args+=(--log-file="$rsync_log_file")

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_entry "INFO" "[DRY RUN] Would execute rsync" \
            "source=${source_path}" "destination=${dest_subdir}" "link_dest=${previous_snapshot:-none}"
        return 0
    fi

    mkdir -p "$dest_subdir"

    log_entry "INFO" "Starting rsync" "source=${source_path}" "destination=${dest_subdir}"

    # Trailing slash on source ensures contents are copied into dest_subdir
    # rather than creating a nested directory named after the source.
    if rsync "${rsync_args[@]}" "${source_path}/" "${dest_subdir}/" >> "$rsync_log_file" 2>&1; then
        log_entry "INFO" "rsync completed successfully" \
            "source=${source_path}" "destination=${dest_subdir}" "rsync_log=${rsync_log_file}"
        return 0
    else
        local exit_code=$?
        log_entry "ERROR" "rsync reported failure" \
            "source=${source_path}" "destination=${dest_subdir}" "exit_code=${exit_code}" "rsync_log=${rsync_log_file}"
        return 1
    fi
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Manifest Generation
# =============================================================================

# generate_manifest SNAPSHOT_PATH
# Generates a SHA256 checksum manifest for every regular file in the
# completed snapshot. Used by verify-backup.sh and restore.sh for
# integrity verification.
generate_manifest() {
    local snapshot_path="$1"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_entry "INFO" "[DRY RUN] Would generate SHA256 manifest"
        return 0
    fi

    local manifest_path="${snapshot_path}/backup.manifest"

    log_entry "INFO" "Generating SHA256 manifest" "path=${manifest_path}"

    local file_count=0
    : > "$manifest_path"

    while IFS= read -r -d '' file; do
        local rel_path="${file#"$snapshot_path"/}"
        local hash
        hash="$(sha256sum "$file" | awk '{print $1}')"
        echo "${hash}  ${rel_path}" >> "$manifest_path"
        ((file_count++))
    done < <(find "$snapshot_path" -type f ! -name "backup.manifest" -print0)

    log_entry "INFO" "Manifest generated" "path=${manifest_path}" "file_count=${file_count}"
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Notification
# =============================================================================

# send_notification STATUS SUMMARY
# Sends an email notification using mailx/s-nail if SMTP_SERVER is configured.
send_notification() {
    local status="$1"
    local summary="$2"

    if [[ -z "${SMTP_SERVER:-}" ]]; then
        return 0
    fi

    if [[ "$status" == "SUCCESS" && "${NOTIFY_ON_SUCCESS:-false}" != "true" ]]; then
        return 0
    fi
    if [[ "$status" == "FAILURE" && "${NOTIFY_ON_FAILURE:-true}" != "true" ]]; then
        return 0
    fi

    if ! command -v mailx >/dev/null 2>&1 && ! command -v mail >/dev/null 2>&1; then
        log_entry "WARN" "Notification requested but no mail command found (install s-nail)" "status=${status}"
        return 1
    fi

    local mail_cmd
    mail_cmd="$(command -v mailx || command -v mail)"

    local subject="[${status}] Backup Report — ${BACKUP_HOST_LABEL} — ${RUN_DATE}"
    local body
    body="Backup Status : ${status}
Host          : ${BACKUP_HOST_LABEL}
Snapshot      : ${SNAPSHOT_NAME:-unknown}
Run Time      : ${RUN_TIMESTAMP}
Log File      : ${LOG_FILE:-unknown}

${summary}"

    if echo "$body" | "$mail_cmd" -s "$subject" -S smtp="$SMTP_SERVER:${SMTP_PORT:-25}" -r "${NOTIFICATION_FROM}" $NOTIFICATION_TO 2>/dev/null; then
        log_entry "INFO" "Notification sent" "status=${status}" "recipients=${NOTIFICATION_TO}"
    else
        log_entry "WARN" "Failed to send notification email" "status=${status}"
    fi
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Main Execution
# =============================================================================

main() {
    echo ""
    echo "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} ==="
    echo "Loading configuration: ${CONFIG_PATH}"
    echo ""

    load_config
    init_logging

    log_entry "INFO" "Backup run started" \
        "script=${SCRIPT_NAME}" "version=${SCRIPT_VERSION}" "config_path=${CONFIG_PATH}" \
        "dry_run=${DRY_RUN}" "host_label=${BACKUP_HOST_LABEL}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_entry "WARN" "DRY RUN MODE — no files will be copied"
    fi

    # -------------------------------------------------------------------------
    # Resolve previous snapshot for hard-link deduplication
    # -------------------------------------------------------------------------
    local previous_snapshot
    previous_snapshot="$(get_previous_snapshot)"
    if [[ -n "$previous_snapshot" ]]; then
        log_entry "INFO" "Previous snapshot found for incremental linking" "previous_snapshot=${previous_snapshot}"
    else
        log_entry "INFO" "No previous snapshot found — this will be a full baseline snapshot"
    fi

    # -------------------------------------------------------------------------
    # Create snapshot directory
    # -------------------------------------------------------------------------
    SNAPSHOT_NAME="${BACKUP_HOST_LABEL}_${RUN_TIMESTAMP}"
    SNAPSHOT_PATH="${DESTINATION_ROOT}/${SNAPSHOT_NAME}"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        if [[ -d "$SNAPSHOT_PATH" ]]; then
            log_entry "ERROR" "Snapshot directory already exists — a backup with this timestamp already ran" "path=${SNAPSHOT_PATH}"
            exit "$EXIT_FATAL"
        fi
        mkdir -p "$SNAPSHOT_PATH"
        log_entry "INFO" "Snapshot directory created" "path=${SNAPSHOT_PATH}"
    fi

    # -------------------------------------------------------------------------
    # Process each source path
    # -------------------------------------------------------------------------
    local processed_count=0
    local failed_count=0
    local source_total=0

    for source_path in $SOURCE_PATHS; do
        ((source_total++))

        if [[ ! -e "$source_path" ]]; then
            log_entry "WARN" "Source path not found — skipping" "source=${source_path}"
            ((failed_count++))
            HAS_ERRORS=1
            continue
        fi

        local safe_subdir
        safe_subdir="$(echo "$source_path" | sed 's/[\/:]/_/g' | sed 's/^_//')"
        local dest_subdir="${SNAPSHOT_PATH}/${safe_subdir}"

        if run_rsync_backup "$source_path" "$dest_subdir" "$previous_snapshot"; then
            ((processed_count++))
        else
            ((failed_count++))
            HAS_ERRORS=1
        fi
    done

    # -------------------------------------------------------------------------
    # Generate manifest
    # -------------------------------------------------------------------------
    if [[ "${MANIFEST_ENABLED:-true}" == "true" ]]; then
        generate_manifest "$SNAPSHOT_PATH"
    fi

    # -------------------------------------------------------------------------
    # Run summary
    # -------------------------------------------------------------------------
    local duration=$(( $(date '+%s') - SCRIPT_START_EPOCH ))
    local status="SUCCESS"
    [[ "$HAS_ERRORS" -eq 1 ]] && status="COMPLETED_WITH_ERRORS"

    log_entry "INFO" "Backup run complete" \
        "status=${status}" "snapshot=${SNAPSHOT_NAME}" "snapshot_path=${SNAPSHOT_PATH}" \
        "sources_total=${source_total}" "sources_success=${processed_count}" "sources_failed=${failed_count}" \
        "duration_seconds=${duration}" "dry_run=${DRY_RUN}" "log_file=${LOG_FILE}"

    echo ""
    echo "--- Run Summary ---"
    echo "Status          : ${status}"
    echo "Snapshot        : ${SNAPSHOT_NAME}"
    echo "Sources Total   : ${source_total}"
    echo "Sources Success : ${processed_count}"
    echo "Sources Failed  : ${failed_count}"
    echo "Duration        : ${duration}s"
    echo "Log File        : ${LOG_FILE}"
    echo ""

    local notif_summary="Sources: ${source_total} total, ${processed_count} succeeded, ${failed_count} failed. Duration: ${duration}s."
    if [[ "$HAS_ERRORS" -eq 1 ]]; then
        send_notification "FAILURE" "$notif_summary"
        exit "$EXIT_FAILURE"
    else
        send_notification "SUCCESS" "$notif_summary"
        exit "$EXIT_SUCCESS"
    fi
}

main "$@"

# =============================================================================
# END REGION
# =============================================================================