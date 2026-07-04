#!/usr/bin/env bash
#
# =============================================================================
# enforce-retention.sh
# =============================================================================
#
# SYNOPSIS
#   Enforces backup retention policy by purging snapshots older than the
#   configured retention window, while always preserving a minimum number
#   of recent snapshots.
#
# DESCRIPTION
#   enforce-retention.sh prevents uncontrolled disk consumption from
#   accumulated snapshots. It identifies snapshots older than RETAIN_DAYS
#   and removes them, subject to a hard floor of MINIMUM_SNAPSHOTS_TO_KEEP —
#   regardless of age, that many of the most recent snapshots are never
#   deleted.
#
#   This script defaults to dry-run behaviour unless --force is explicitly
#   passed, governed by DRY_RUN_RETENTION_BY_DEFAULT in the configuration
#   file. Deletion is destructive and irreversible. The safety default
#   exists to prevent accidental data loss during initial deployment and
#   routine operation.
#
#   Every deletion is logged individually with the snapshot name, age, and
#   size, producing a complete audit trail of what was removed and why.
#
# USAGE
#   ./linux/enforce-retention.sh --config <path> [--force]
#
# OPTIONS
#   --config <path>   Path to the populated configuration file (required)
#   --force            Required to perform actual deletions. Without this
#                      flag, the script runs as a dry run unless
#                      DRY_RUN_RETENTION_BY_DEFAULT is explicitly false
#                      in the configuration file.
#   --help              Display this usage information
#
# EXIT CODES
#   0   Retention enforcement completed (including dry runs)
#   1   One or more deletions failed
#   2   Fatal error — configuration or destination invalid
#
# REQUIRES
#   bash 4.0+, find (findutils), du (coreutils)
#
# REFERENCE
#   docs/retention-policy.md
#   docs/command-reference.md
# =============================================================================

set -u
set -o pipefail

# =============================================================================
# REGION: Constants
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="enforce-retention"
readonly EXIT_SUCCESS=0
readonly EXIT_FAILURE=1
readonly EXIT_FATAL=2

RUN_TIMESTAMP="$(date '+%Y-%m-%d_%H%M')"
SCRIPT_START_EPOCH="$(date '+%s')"

CONFIG_PATH=""
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
Usage: $0 --config <path> [--force]

Options:
  --config <path>   Path to the populated configuration file (required)
  --force            Required to perform actual deletions
  --help              Display this usage information
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_PATH="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --help) print_usage; exit "$EXIT_SUCCESS" ;;
        *) echo "Unknown argument: $1" >&2; print_usage; exit "$EXIT_FATAL" ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then
    echo "ERROR: --config is required" >&2; print_usage; exit "$EXIT_FATAL"
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

    local required_vars=(
        "DESTINATION_ROOT" "BACKUP_HOST_LABEL"
        "RETAIN_DAYS" "MINIMUM_SNAPSHOTS_TO_KEEP" "LOG_DIRECTORY"
    )
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: Required configuration variable is missing: $var" >&2
            exit "$EXIT_FATAL"
        fi
    done

    if [[ "$RETAIN_DAYS" -lt 1 ]]; then
        echo "ERROR: RETAIN_DAYS must be at least 1. Current value: ${RETAIN_DAYS}" >&2
        exit "$EXIT_FATAL"
    fi

    if [[ "$MINIMUM_SNAPSHOTS_TO_KEEP" -lt 1 ]]; then
        echo "ERROR: MINIMUM_SNAPSHOTS_TO_KEEP must be at least 1. A value of 0 would allow deletion of all backups. Current value: ${MINIMUM_SNAPSHOTS_TO_KEEP}" >&2
        exit "$EXIT_FATAL"
    fi
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Snapshot Inventory and Eligibility
# =============================================================================

# build_inventory
# Discovers all snapshots under DESTINATION_ROOT matching BACKUP_HOST_LABEL,
# parses the embedded timestamp from the directory name, and calculates
# age. Writes results to the INVENTORY array as "epoch|age_days|size_kb|path"
# sorted newest-first.
declare -a INVENTORY=()

build_inventory() {
    local now_epoch
    now_epoch="$(date '+%s')"

    local candidates
    candidates="$(find "$DESTINATION_ROOT" -maxdepth 1 -type d -name "${BACKUP_HOST_LABEL}_*" 2>/dev/null)"

    local entries=()

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local dir_name
        dir_name="$(basename "$dir")"

        # Snapshot name format: {label}_{yyyy-MM-dd}_{HHmm}
        # Extract and parse the timestamp for reliable age calculation,
        # independent of filesystem metadata which can be altered by
        # copy operations or filesystem migrations.
        if [[ "$dir_name" =~ ^${BACKUP_HOST_LABEL}_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{4})$ ]]; then
            local date_part="${BASH_REMATCH[1]}"
            local time_part="${BASH_REMATCH[2]}"
            local hour="${time_part:0:2}"
            local minute="${time_part:2:2}"

            local snapshot_epoch
            snapshot_epoch="$(date -d "${date_part} ${hour}:${minute}" '+%s' 2>/dev/null)"

            if [[ -z "$snapshot_epoch" ]]; then
                log_entry "WARN" "Failed to parse timestamp from snapshot name — skipping from retention consideration" "directory=${dir_name}"
                continue
            fi

            local age_days
            age_days="$(awk -v now="$now_epoch" -v then="$snapshot_epoch" 'BEGIN { printf "%.1f", (now - then) / 86400 }')"

            local size_kb
            size_kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')"
            size_kb="${size_kb:-0}"

            entries+=("${snapshot_epoch}|${age_days}|${size_kb}|${dir}")
        else
            log_entry "WARN" "Directory does not match expected snapshot naming pattern — skipping from retention consideration" "directory=${dir_name}"
        fi
    done <<< "$candidates"

    # Sort newest-first by epoch (numeric, descending)
    IFS=$'\n' INVENTORY=($(printf '%s\n' "${entries[@]}" | sort -t'|' -k1,1 -rn))
    unset IFS
}

# determine_purge_candidates
# Applies the age threshold and minimum-snapshots floor to INVENTORY.
# Populates PURGE_LIST and RETAIN_LIST arrays.
declare -a PURGE_LIST=()
declare -a RETAIN_LIST=()

determine_purge_candidates() {
    local total="${#INVENTORY[@]}"

    if [[ "$total" -le "$MINIMUM_SNAPSHOTS_TO_KEEP" ]]; then
        log_entry "INFO" "Total snapshot count does not exceed minimum retention floor — no purge candidates" \
            "total_snapshots=${total}" "minimum_to_keep=${MINIMUM_SNAPSHOTS_TO_KEEP}"
        RETAIN_LIST=("${INVENTORY[@]}")
        return
    fi

    local index=0
    for entry in "${INVENTORY[@]}"; do
        if [[ "$index" -lt "$MINIMUM_SNAPSHOTS_TO_KEEP" ]]; then
            # Protected by the minimum-snapshots floor regardless of age
            RETAIN_LIST+=("$entry")
        else
            local age_days
            age_days="$(echo "$entry" | cut -d'|' -f2)"
            local is_old
            is_old="$(awk -v a="$age_days" -v r="$RETAIN_DAYS" 'BEGIN { print (a > r) }')"
            if [[ "$is_old" -eq 1 ]]; then
                PURGE_LIST+=("$entry")
            else
                RETAIN_LIST+=("$entry")
            fi
        fi
        ((index++))
    done
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Purge Execution
# =============================================================================

# remove_snapshot ENTRY IS_DRY_RUN
# ENTRY format: epoch|age_days|size_kb|path
remove_snapshot() {
    local entry="$1"
    local is_dry_run="$2"

    local age_days size_kb path name
    age_days="$(echo "$entry" | cut -d'|' -f2)"
    size_kb="$(echo "$entry" | cut -d'|' -f3)"
    path="$(echo "$entry" | cut -d'|' -f4)"
    name="$(basename "$path")"

    local size_gb
    size_gb="$(awk -v kb="$size_kb" 'BEGIN { printf "%.3f", kb / 1048576 }')"

    if [[ "$is_dry_run" -eq 1 ]]; then
        log_entry "INFO" "[DRY RUN] Would delete snapshot" \
            "snapshot=${name}" "age_days=${age_days}" "size_gb=${size_gb}" "path=${path}"
        return 0
    fi

    # Safety check: refuse to operate on a path outside DESTINATION_ROOT.
    # Prevents catastrophic deletion in the event of a path construction bug.
    case "$path" in
        "${DESTINATION_ROOT}"/*) ;;
        *)
            log_entry "ERROR" "Refusing to delete path outside configured destination root" "path=${path}" "destination_root=${DESTINATION_ROOT}"
            return 1
            ;;
    esac

    if rm -rf "$path"; then
        log_entry "INFO" "Snapshot deleted" \
            "snapshot=${name}" "age_days=${age_days}" "size_gb=${size_gb}" "path=${path}"
        return 0
    else
        log_entry "ERROR" "Failed to delete snapshot" "snapshot=${name}" "path=${path}"
        return 1
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

    # Determine effective dry-run state.
    # --force overrides the config default. Absent --force, the config default applies.
    local config_default_dry_run="${DRY_RUN_RETENTION_BY_DEFAULT:-true}"
    local is_dry_run=1
    if [[ "$FORCE" -eq 1 ]]; then
        is_dry_run=0
    elif [[ "$config_default_dry_run" == "false" ]]; then
        is_dry_run=0
    fi

    log_entry "INFO" "Retention enforcement started" \
        "config_path=${CONFIG_PATH}" "retain_days=${RETAIN_DAYS}" \
        "minimum_snapshots_to_keep=${MINIMUM_SNAPSHOTS_TO_KEEP}" \
        "force_specified=${FORCE}" "effective_dry_run=${is_dry_run}"

    if [[ "$is_dry_run" -eq 1 ]]; then
        log_entry "WARN" "DRY RUN MODE — no snapshots will be deleted. Pass --force to perform actual deletions."
    fi

    # -------------------------------------------------------------------------
    # Build inventory and determine purge candidates
    # -------------------------------------------------------------------------
    build_inventory

    log_entry "INFO" "Snapshot inventory built" "total_snapshots=${#INVENTORY[@]}"

    if [[ "${#INVENTORY[@]}" -eq 0 ]]; then
        log_entry "WARN" "No snapshots found matching configured host label — nothing to do" \
            "destination_root=${DESTINATION_ROOT}" "host_label=${BACKUP_HOST_LABEL}"
        exit "$EXIT_SUCCESS"
    fi

    determine_purge_candidates

    log_entry "INFO" "Retention evaluation complete" \
        "total_snapshots=${#INVENTORY[@]}" "purge_count=${#PURGE_LIST[@]}" "retain_count=${#RETAIN_LIST[@]}"

    # -------------------------------------------------------------------------
    # Execute purge
    # -------------------------------------------------------------------------
    local deleted_count=0
    local failed_count=0
    local deleted_size_gb=0

    for entry in "${PURGE_LIST[@]}"; do
        local size_kb
        size_kb="$(echo "$entry" | cut -d'|' -f3)"

        if remove_snapshot "$entry" "$is_dry_run"; then
            ((deleted_count++))
            deleted_size_gb="$(awk -v total="$deleted_size_gb" -v kb="$size_kb" 'BEGIN { printf "%.3f", total + (kb / 1048576) }')"
        else
            ((failed_count++))
            HAS_ERRORS=1
        fi
    done

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------
    local duration=$(( $(date '+%s') - SCRIPT_START_EPOCH ))
    local status="SUCCESS"
    [[ "$HAS_ERRORS" -eq 1 ]] && status="COMPLETED_WITH_ERRORS"

    log_entry "INFO" "Retention enforcement complete" \
        "status=${status}" "dry_run=${is_dry_run}" "total_snapshots_evaluated=${#INVENTORY[@]}" \
        "snapshots_purged=${deleted_count}" "snapshots_purge_failed=${failed_count}" \
        "snapshots_retained=${#RETAIN_LIST[@]}" "space_reclaimed_gb=${deleted_size_gb}" "duration_seconds=${duration}"

    echo ""
    echo "--- Retention Summary ---"
    echo "Status              : ${status}"
    echo "Mode                : $( [[ "$is_dry_run" -eq 1 ]] && echo 'DRY RUN' || echo 'LIVE' )"
    echo "Total Snapshots     : ${#INVENTORY[@]}"
    echo "Purged              : ${deleted_count}"
    echo "Purge Failed        : ${failed_count}"
    echo "Retained            : ${#RETAIN_LIST[@]}"
    echo "Space Reclaimed     : ${deleted_size_gb} GB $( [[ "$is_dry_run" -eq 1 ]] && echo '(estimated)' )"
    echo "Duration            : ${duration}s"
    echo "Log File            : ${LOG_FILE}"
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