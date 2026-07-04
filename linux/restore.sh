#!/usr/bin/env bash
#
# =============================================================================
# restore.sh
# =============================================================================
#
# SYNOPSIS
#   Performs a guided restoration of a backup snapshot to a specified
#   destination.
#
# DESCRIPTION
#   restore.sh restores files from a completed snapshot back to a target
#   destination, with pre-restore validation, conflict detection, dry-run
#   support, and post-restore verification.
#
#   Restoration is the step most backup processes never test. This script
#   is designed to make restoration low-friction enough that it gets tested
#   regularly — not just during an actual incident.
#
#   The script will not restore into an existing non-empty destination
#   unless --force is explicitly specified, preventing accidental data
#   loss during restoration testing.
#
# USAGE
#   ./linux/restore.sh --config <path> --destination <path>
#                       [--snapshot <name>] [--source-subdir <name>]
#                       [--dry-run] [--force]
#
# OPTIONS
#   --config <path>         Path to the populated configuration file (required)
#   --destination <path>    Absolute path to restore files to (required)
#   --snapshot <name>       Snapshot to restore from. Defaults to most recent.
#   --source-subdir <name>  Restrict restoration to a specific subdirectory
#                            within the snapshot (the safe-name subdirectory
#                            created during backup, e.g. home_admin).
#                            If omitted, all subdirectories are restored.
#   --dry-run                Validate the restoration plan without copying files
#   --force                  Allow restoration into a non-empty destination,
#                            including the original source path. Required for
#                            actual disaster recovery restores.
#   --help                    Display this usage information
#
# EXIT CODES
#   0   Restoration completed successfully
#   1   Restoration completed with errors
#   2   Fatal error — restoration aborted before any files copied
#
# REQUIRES
#   bash 4.0+, rsync, sha256sum (coreutils), find (findutils), df (coreutils)
#
# REFERENCE
#   docs/restoration-runbook.md
#   checklists/restoration-checklist.md
# =============================================================================

set -u
set -o pipefail

# =============================================================================
# REGION: Constants
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="restore"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_FATAL=2

RUN_TIMESTAMP="$(date '+%Y-%m-%d_%H%M')"
SCRIPT_START_EPOCH="$(date '+%s')"

CONFIG_PATH=""
DESTINATION=""
REQUESTED_SNAPSHOT=""
SOURCE_SUBDIR=""
DRY_RUN=0
FORCE=0
HAS_ERRORS=0

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Argument Parsing
# =============================================================================

print_usage() {
    cat <<EOF
Usage: $0 --config <path> --destination <path> [options]

Required:
  --config <path>          Path to the populated configuration file
  --destination <path>     Absolute path to restore files to

Options:
  --snapshot <name>        Snapshot to restore from. Defaults to most recent.
  --source-subdir <name>   Restrict restoration to a specific subdirectory
  --dry-run                  Validate the restoration plan without copying files
  --force                    Allow restoration into a non-empty destination
  --help                      Display this usage information
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_PATH="$2"; shift 2 ;;
        --destination) DESTINATION="$2"; shift 2 ;;
        --snapshot) REQUESTED_SNAPSHOT="$2"; shift 2 ;;
        --source-subdir) SOURCE_SUBDIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        --help) print_usage; exit "$EXIT_SUCCESS" ;;
        *) echo "Unknown argument: $1" >&2; print_usage; exit "$EXIT_FATAL" ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then
    echo "ERROR: --config is required" >&2; print_usage; exit "$EXIT_FATAL"
fi
if [[ -z "$DESTINATION" ]]; then
    echo "ERROR: --destination is required" >&2; print_usage; exit "$EXIT_FATAL"
fi

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Logging Functions
# =============================================================================

log_entry() {
    local level="$1"; local message="$2"; shift 2
    local extra_fields=("$@")

    local level_num
    case "$level" in DEBUG) level_num=0 ;; INFO) level_num=1 ;; WARN) level_num=2 ;; ERROR) level_num=3 ;; *) level_num=1 ;; esac
    local configured_level_num
    case "${LOG_LEVEL:-INFO}" in DEBUG) configured_level_num=0 ;; INFO) configured_level_num=1 ;; WARN) configured_level_num=2 ;; ERROR) configured_level_num=3 ;; *) configured_level_num=1 ;; esac
    if (( level_num < configured_level_num )); then return 0; fi

    local timestamp
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S')"
    local json="{\"timestamp\":\"${timestamp}\",\"level\":\"${level}\",\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"message\":\"$(json_escape "$message")\""
    for field in "${extra_fields[@]}"; do
        local key="${field%%=*}"; local value="${field#*=}"
        json="${json},\"${key}\":\"$(json_escape "$value")\""
    done
    json="${json}}"

    if [[ -n "${LOG_FILE:-}" ]]; then echo "$json" >> "$LOG_FILE"; fi

    local colour_code
    case "$level" in
        DEBUG) colour_code="\033[0;37m" ;; INFO) colour_code="\033[0;36m" ;;
        WARN) colour_code="\033[0;33m" ;; ERROR) colour_code="\033[0;31m" ;; *) colour_code="\033[0m" ;;
    esac
    echo -e "${colour_code}[${level}] ${message}\033[0m"
}

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
# REGION: Configuration Loading
# =============================================================================

load_config() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "ERROR: Configuration file not found: $CONFIG_PATH" >&2
        exit "$EXIT_FATAL"
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_PATH"

    local required_vars=("DESTINATION_ROOT" "BACKUP_HOST_LABEL" "LOG_DIRECTORY")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: Required configuration variable is missing: $var" >&2
            exit "$EXIT_FATAL"
        fi
    done
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Snapshot Resolution
# =============================================================================

resolve_snapshot_path() {
    if [[ -n "$REQUESTED_SNAPSHOT" ]]; then
        local path="${DESTINATION_ROOT}/${REQUESTED_SNAPSHOT}"
        if [[ ! -d "$path" ]]; then
            log_entry "ERROR" "Specified snapshot not found" "path=${path}"
            exit "$EXIT_FATAL"
        fi
        echo "$path"
        return
    fi

    local latest
    latest="$(find "$DESTINATION_ROOT" -maxdepth 1 -type d -name "${BACKUP_HOST_LABEL}_*" 2>/dev/null | sort -r | head -n 1)"

    if [[ -z "$latest" ]]; then
        log_entry "ERROR" "No snapshots found under destination root" "destination_root=${DESTINATION_ROOT}"
        exit "$EXIT_FATAL"
    fi

    log_entry "INFO" "No snapshot specified — using most recent" "selected=$(basename "$latest")"
    echo "$latest"
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Pre-Restore Validation
# =============================================================================

# validate_pre_restore SNAPSHOT_PATH DESTINATION_PATH
# Checks destination conflict, manifest presence, and available disk space.
# Sets PRE_RESTORE_BLOCKED to 1 if restoration must not proceed.
PRE_RESTORE_BLOCKED=0
validate_pre_restore() {
    local snapshot_path="$1"
    local destination_path="$2"

    local manifest_path="${snapshot_path}/backup.manifest"
    if [[ ! -f "$manifest_path" ]]; then
        log_entry "WARN" "No manifest found in snapshot — post-restore verification will be limited to file count only" "manifest=${manifest_path}"
    fi

    if [[ -d "$destination_path" ]]; then
        local existing_count
        existing_count="$(find "$destination_path" -type f 2>/dev/null | wc -l)"
        if [[ "$existing_count" -gt 0 && "$FORCE" -eq 0 ]]; then
            log_entry "ERROR" "Destination is not empty — restoration blocked" \
                "destination=${destination_path}" "existing_file_count=${existing_count}"
            PRE_RESTORE_BLOCKED=1
        fi
    fi

    local snapshot_size_kb dest_avail_kb
    snapshot_size_kb="$(du -sk "$snapshot_path" 2>/dev/null | awk '{print $1}')"
    snapshot_size_kb="${snapshot_size_kb:-0}"

    local check_path="$destination_path"
    [[ ! -d "$check_path" ]] && check_path="$(dirname "$destination_path")"
    dest_avail_kb="$(df -k --output=avail "$check_path" 2>/dev/null | tail -n 1 | tr -d ' ')"
    dest_avail_kb="${dest_avail_kb:-0}"

    if [[ "$snapshot_size_kb" -gt "$dest_avail_kb" ]]; then
        log_entry "ERROR" "Insufficient free space at destination" \
            "required_kb=${snapshot_size_kb}" "available_kb=${dest_avail_kb}"
        PRE_RESTORE_BLOCKED=1
    fi
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Restoration Execution
# =============================================================================

# run_restore_copy SOURCE_PATH DEST_PATH
# Executes rsync to restore files. Always additive — never passes --delete,
# so restoration never removes pre-existing destination content beyond
# what --force has already authorised at the validation step.
run_restore_copy() {
    local source_path="$1"
    local dest_path="$2"

    local rsync_log_file="${LOG_DIRECTORY}/restore_rsync_${RUN_TIMESTAMP}.log"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_entry "INFO" "[DRY RUN] Would execute restore rsync" "source=${source_path}" "destination=${dest_path}"
        return 0
    fi

    mkdir -p "$dest_path"

    log_entry "INFO" "Starting restore copy" "source=${source_path}" "destination=${dest_path}"

    if rsync -a --stats "${source_path}/" "${dest_path}/" >> "$rsync_log_file" 2>&1; then
        log_entry "INFO" "Restore copy completed" "source=${source_path}" "destination=${dest_path}"
        return 0
    else
        local exit_code=$?
        log_entry "ERROR" "Restore copy reported failure" \
            "source=${source_path}" "destination=${dest_path}" "exit_code=${exit_code}" "rsync_log=${rsync_log_file}"
        return 1
    fi
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Post-Restore Verification
# =============================================================================

POST_RESTORE_COUNT_PASS=1
POST_RESTORE_HASH_PASS=1
POST_RESTORE_BACKUP_COUNT=0
POST_RESTORE_RESTORED_COUNT=0

# verify_post_restore SNAPSHOT_PATH DESTINATION_PATH
verify_post_restore() {
    local snapshot_path="$1"
    local destination_path="$2"

    local backup_count restored_count
    backup_count="$(find "$snapshot_path" -type f ! -name "backup.manifest" 2>/dev/null | wc -l)"
    restored_count="$(find "$destination_path" -type f 2>/dev/null | wc -l)"

    POST_RESTORE_BACKUP_COUNT="$backup_count"
    POST_RESTORE_RESTORED_COUNT="$restored_count"

    if [[ "$backup_count" -ne "$restored_count" ]]; then
        POST_RESTORE_COUNT_PASS=0
    fi

    log_entry "$( [[ "$POST_RESTORE_COUNT_PASS" -eq 1 ]] && echo INFO || echo ERROR )" \
        "Post-restore file count check" \
        "snapshot_count=${backup_count}" "restored_count=${restored_count}" "pass=$( [[ "$POST_RESTORE_COUNT_PASS" -eq 1 ]] && echo true || echo false )"

    local manifest_path="${snapshot_path}/backup.manifest"
    if [[ -f "$manifest_path" ]]; then
        local line_count
        line_count="$(wc -l < "$manifest_path")"
        local sample_size=5
        [[ "$sample_size" -gt "$line_count" ]] && sample_size="$line_count"

        if [[ "$sample_size" -gt 0 ]]; then
            local sample
            sample="$(shuf -n "$sample_size" "$manifest_path")"

            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local expected_hash="${line%%  *}"
                local rel_path="${line#*  }"
                local restored_file="${destination_path}/${rel_path}"

                if [[ ! -f "$restored_file" ]]; then
                    log_entry "ERROR" "Post-restore spot-check file missing" "file=${rel_path}"
                    POST_RESTORE_HASH_PASS=0
                    continue
                fi

                local actual_hash
                actual_hash="$(sha256sum "$restored_file" | awk '{print $1}')"
                if [[ "$actual_hash" != "$expected_hash" ]]; then
                    log_entry "ERROR" "Post-restore spot-check hash mismatch" "file=${rel_path}"
                    POST_RESTORE_HASH_PASS=0
                fi
            done <<< "$sample"
        fi
    else
        log_entry "WARN" "No manifest available — skipping post-restore hash spot-check"
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

    load_config

    if [[ ! -d "$LOG_DIRECTORY" ]]; then mkdir -p "$LOG_DIRECTORY"; fi
    LOG_FILE="${LOG_DIRECTORY}/${SCRIPT_NAME}_${RUN_TIMESTAMP}.json"

    log_entry "INFO" "Restoration run started" \
        "config_path=${CONFIG_PATH}" "destination=${DESTINATION}" "dry_run=${DRY_RUN}" "force=${FORCE}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_entry "WARN" "DRY RUN MODE — no files will be copied"
    fi

    local snapshot_path
    snapshot_path="$(resolve_snapshot_path)"
    local snapshot_name
    snapshot_name="$(basename "$snapshot_path")"

    log_entry "INFO" "Restoring from snapshot" "snapshot=${snapshot_name}" "path=${snapshot_path}"

    # -------------------------------------------------------------------------
    # Pre-restore validation — runs even in dry-run mode
    # -------------------------------------------------------------------------
    validate_pre_restore "$snapshot_path" "$DESTINATION"

    if [[ "$PRE_RESTORE_BLOCKED" -eq 1 ]]; then
        log_entry "ERROR" "Pre-restore validation failed — restoration aborted before any files were copied"
        exit "$EXIT_FATAL"
    fi

    # -------------------------------------------------------------------------
    # Determine which subdirectories to restore
    # -------------------------------------------------------------------------
    local subdirs=()
    if [[ -n "$SOURCE_SUBDIR" ]]; then
        local target_dir="${snapshot_path}/${SOURCE_SUBDIR}"
        if [[ ! -d "$target_dir" ]]; then
            log_entry "ERROR" "Specified source subdirectory not found in snapshot" "subdir=${SOURCE_SUBDIR}"
            exit "$EXIT_FATAL"
        fi
        subdirs=("$target_dir")
    else
        while IFS= read -r -d '' dir; do
            subdirs+=("$dir")
        done < <(find "$snapshot_path" -mindepth 1 -maxdepth 1 -type d -print0)
    fi

    if [[ "${#subdirs[@]}" -eq 0 ]]; then
        log_entry "ERROR" "No restorable content found in snapshot" "snapshot=${snapshot_path}"
        exit "$EXIT_FATAL"
    fi

    # -------------------------------------------------------------------------
    # Execute restoration
    # -------------------------------------------------------------------------
    local restored_count=0
    local failed_count=0

    for subdir in "${subdirs[@]}"; do
        if run_restore_copy "$subdir" "$DESTINATION"; then
            ((restored_count++))
        else
            ((failed_count++))
            HAS_ERRORS=1
        fi
    done

    # -------------------------------------------------------------------------
    # Post-restore verification
    # -------------------------------------------------------------------------
    if [[ "$DRY_RUN" -eq 0 ]]; then
        verify_post_restore "$snapshot_path" "$DESTINATION"
        if [[ "$POST_RESTORE_COUNT_PASS" -eq 0 || "$POST_RESTORE_HASH_PASS" -eq 0 ]]; then
            HAS_ERRORS=1
        fi
    fi

    local duration=$(( $(date '+%s') - SCRIPT_START_EPOCH ))
    local status="SUCCESS"
    [[ "$HAS_ERRORS" -eq 1 ]] && status="COMPLETED_WITH_ERRORS"

    log_entry "INFO" "Restoration run complete" \
        "status=${status}" "snapshot=${snapshot_name}" "destination=${DESTINATION}" \
        "subdirs_restored=${restored_count}" "subdirs_failed=${failed_count}" "duration_seconds=${duration}"

    echo ""
    echo "--- Restoration Summary ---"
    echo "Status            : ${status}"
    echo "Snapshot          : ${snapshot_name}"
    echo "Destination       : ${DESTINATION}"
    echo "Subdirs Restored  : ${restored_count}"
    echo "Subdirs Failed    : ${failed_count}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "File Count Match  : $( [[ "$POST_RESTORE_COUNT_PASS" -eq 1 ]] && echo true || echo false ) (${POST_RESTORE_RESTORED_COUNT}/${POST_RESTORE_BACKUP_COUNT})"
        echo "Hash Spot-Check   : $( [[ "$POST_RESTORE_HASH_PASS" -eq 1 ]] && echo true || echo false )"
    fi
    echo "Duration          : ${duration}s"
    echo "Log File          : ${LOG_FILE}"
    echo ""

    if [[ "$HAS_ERRORS" -eq 1 ]]; then
        exit "$EXIT_FAILURE"
    else
        exit "$EXIT_SUCCESS"
    fi
}

main "$@"

# =============================================================================
# END REGION
# =============================================================================