#!/usr/bin/env bash
#
# =============================================================================
# verify-backup.sh
# =============================================================================
#
# SYNOPSIS
#   Verifies the integrity of a completed backup snapshot against its
#   source paths.
#
# DESCRIPTION
#   verify-backup.sh performs post-backup verification using three
#   independent checks:
#
#     - File count comparison between source and snapshot
#     - Total apparent size comparison between source and snapshot
#     - SHA256 hash spot-check against the manifest generated at backup time
#
#   A backup is only as trustworthy as its verification. A completed rsync
#   run with exit code 0 does not guarantee that every file is present,
#   complete, and uncorrupted at the destination — only that rsync did not
#   encounter an error during transfer.
#
#   Output is structured JSON, written to the log directory and to stdout,
#   and is consumed by generate-report.sh.
#
# USAGE
#   ./linux/verify-backup.sh --config <path> [--snapshot <name>]
#
# OPTIONS
#   --config <path>     Path to the populated configuration file (required)
#   --snapshot <name>   Snapshot directory name to verify
#                        (e.g. RHEL9-SRV01_2025-06-15_0200)
#                        If omitted, the most recent snapshot is used
#   --help               Display this usage information
#
# EXIT CODES
#   0   Verification passed
#   1   Verification failed — one or more checks failed
#   2   Fatal error — configuration invalid or snapshot not found
#
# REQUIRES
#   bash 4.0+, sha256sum (coreutils), find (findutils), du (coreutils)
#
# REFERENCE
#   docs/command-reference.md
#   docs/troubleshooting.md
# =============================================================================

set -u
set -o pipefail

# =============================================================================
# REGION: Constants
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="verify-backup"
readonly EXIT_PASS=0
readonly EXIT_FAIL=1
readonly EXIT_FATAL=2

RUN_TIMESTAMP="$(date '+%Y-%m-%d_%H%M')"
SCRIPT_START_EPOCH="$(date '+%s')"

CONFIG_PATH=""
REQUESTED_SNAPSHOT=""
HAS_FAILURES=0

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Argument Parsing
# =============================================================================

print_usage() {
    cat <<EOF
Usage: $0 --config <path> [--snapshot <name>]

Options:
  --config <path>      Path to the populated configuration file (required)
  --snapshot <name>    Snapshot name to verify. Defaults to most recent.
  --help                Display this usage information
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_PATH="$2"
            shift 2
            ;;
        --snapshot)
            REQUESTED_SNAPSHOT="$2"
            shift 2
            ;;
        --help)
            print_usage
            exit "$EXIT_PASS"
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

log_entry() {
    local level="$1"
    local message="$2"
    shift 2
    local extra_fields=("$@")

    local level_num
    case "$level" in
        DEBUG) level_num=0 ;; INFO) level_num=1 ;; WARN) level_num=2 ;; ERROR) level_num=3 ;; *) level_num=1 ;;
    esac
    local configured_level_num
    case "${LOG_LEVEL:-INFO}" in
        DEBUG) configured_level_num=0 ;; INFO) configured_level_num=1 ;; WARN) configured_level_num=2 ;; ERROR) configured_level_num=3 ;; *) configured_level_num=1 ;;
    esac
    if (( level_num < configured_level_num )); then return 0; fi

    local timestamp
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S')"
    local json="{\"timestamp\":\"${timestamp}\",\"level\":\"${level}\",\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"message\":\"$(json_escape "$message")\""

    for field in "${extra_fields[@]}"; do
        local key="${field%%=*}"
        local value="${field#*=}"
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
        "SOURCE_PATHS" "DESTINATION_ROOT" "BACKUP_HOST_LABEL"
        "LOG_DIRECTORY" "VERIFY_FILE_COUNT" "VERIFY_SIZE" "SPOT_CHECK_ENABLED"
    )
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

# resolve_snapshot_path
# Determines the full path of the snapshot to verify. Echoes the path.
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
# REGION: Verification Checks
# =============================================================================

# check_file_count SNAPSHOT_PATH
# Compares file count between each source path and its corresponding
# subdirectory within the snapshot. Sets FILE_COUNT_PASS to 0 or 1.
FILE_COUNT_PASS=1
check_file_count() {
    local snapshot_path="$1"

    for source_path in $SOURCE_PATHS; do
        if [[ ! -e "$source_path" ]]; then
            log_entry "WARN" "Source path no longer exists — skipping count check" "source=${source_path}"
            continue
        fi

        local safe_subdir
        safe_subdir="$(echo "$source_path" | sed 's/[\/:]/_/g' | sed 's/^_//')"
        local dest_subdir="${snapshot_path}/${safe_subdir}"

        if [[ ! -d "$dest_subdir" ]]; then
            log_entry "ERROR" "Snapshot destination subdirectory missing for source" "source=${source_path}" "expected=${dest_subdir}"
            FILE_COUNT_PASS=0
            continue
        fi

        local source_count dest_count
        source_count="$(find "$source_path" -type f 2>/dev/null | wc -l)"
        dest_count="$(find "$dest_subdir" -type f 2>/dev/null | wc -l)"

        local pass="true"
        if [[ "$source_count" -ne "$dest_count" ]]; then
            pass="false"
            FILE_COUNT_PASS=0
        fi

        local level="INFO"
        [[ "$pass" == "false" ]] && level="ERROR"
        log_entry "$level" "File count check" \
            "source=${source_path}" "source_count=${source_count}" "dest_count=${dest_count}" "pass=${pass}"
    done
}

# check_total_size SNAPSHOT_PATH
# Compares total apparent byte size between each source path and its
# corresponding snapshot subdirectory, within the configured tolerance.
SIZE_PASS=1
check_total_size() {
    local snapshot_path="$1"
    local tolerance="${FAIL_ON_SIZE_DELTA_PERCENT:-5}"

    for source_path in $SOURCE_PATHS; do
        if [[ ! -e "$source_path" ]]; then continue; fi

        local safe_subdir
        safe_subdir="$(echo "$source_path" | sed 's/[\/:]/_/g' | sed 's/^_//')"
        local dest_subdir="${snapshot_path}/${safe_subdir}"

        if [[ ! -d "$dest_subdir" ]]; then
            SIZE_PASS=0
            continue
        fi

        # --apparent-size reflects logical file size, consistent regardless
        # of filesystem block size or hard-link sharing between snapshots.
        local source_bytes dest_bytes
        source_bytes="$(du -sb --apparent-size "$source_path" 2>/dev/null | awk '{print $1}')"
        dest_bytes="$(du -sb --apparent-size "$dest_subdir" 2>/dev/null | awk '{print $1}')"

        source_bytes="${source_bytes:-0}"
        dest_bytes="${dest_bytes:-0}"

        local delta_percent=0
        if [[ "$source_bytes" -gt 0 ]]; then
            delta_percent=$(awk -v s="$source_bytes" -v d="$dest_bytes" 'BEGIN { delta = (s > d) ? s - d : d - s; printf "%.2f", (delta / s) * 100 }')
        fi

        local pass="true"
        if (( $(awk -v dp="$delta_percent" -v t="$tolerance" 'BEGIN { print (dp > t) }') )); then
            pass="false"
            SIZE_PASS=0
        fi

        local level="INFO"
        [[ "$pass" == "false" ]] && level="ERROR"
        log_entry "$level" "Size comparison check" \
            "source=${source_path}" "source_bytes=${source_bytes}" "dest_bytes=${dest_bytes}" \
            "delta_percent=${delta_percent}" "tolerance=${tolerance}" "pass=${pass}"
    done
}

# check_spot_hash SNAPSHOT_PATH
# Selects a random sample of files from the manifest and re-hashes them
# against the recorded SHA256 value.
SPOT_CHECK_PASS=1
SPOT_CHECK_SKIPPED=0
check_spot_hash() {
    local snapshot_path="$1"
    local manifest_path="${snapshot_path}/backup.manifest"
    local sample_size="${SPOT_CHECK_SAMPLE_SIZE:-10}"

    if [[ ! -f "$manifest_path" ]]; then
        log_entry "WARN" "No manifest found — spot-check skipped" "expected=${manifest_path}"
        SPOT_CHECK_SKIPPED=1
        return
    fi

    local manifest_line_count
    manifest_line_count="$(wc -l < "$manifest_path")"

    if [[ "$manifest_line_count" -eq 0 ]]; then
        log_entry "WARN" "Manifest is empty — spot-check skipped"
        SPOT_CHECK_SKIPPED=1
        return
    fi

    if [[ "$sample_size" -gt "$manifest_line_count" ]]; then
        sample_size="$manifest_line_count"
    fi

    local sample
    sample="$(shuf -n "$sample_size" "$manifest_path")"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local expected_hash="${line%%  *}"
        local rel_path="${line#*  }"
        local full_path="${snapshot_path}/${rel_path}"

        if [[ ! -f "$full_path" ]]; then
            log_entry "ERROR" "Spot-check file missing from snapshot" "file=${rel_path}"
            SPOT_CHECK_PASS=0
            continue
        fi

        local actual_hash
        actual_hash="$(sha256sum "$full_path" | awk '{print $1}')"

        local pass="true"
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            pass="false"
            SPOT_CHECK_PASS=0
        fi

        local level="DEBUG"
        [[ "$pass" == "false" ]] && level="ERROR"
        log_entry "$level" "Spot-check hash comparison" "file=${rel_path}" "pass=${pass}"
    done <<< "$sample"
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

    log_entry "INFO" "Integrity verification started" "config_path=${CONFIG_PATH}"

    local snapshot_path
    snapshot_path="$(resolve_snapshot_path)"
    local snapshot_name
    snapshot_name="$(basename "$snapshot_path")"

    log_entry "INFO" "Verifying snapshot" "snapshot=${snapshot_name}" "path=${snapshot_path}"

    local checks_performed=0
    local checks_passed=0

    if [[ "${VERIFY_FILE_COUNT}" == "true" ]]; then
        ((checks_performed++))
        check_file_count "$snapshot_path"
        [[ "$FILE_COUNT_PASS" -eq 1 ]] && ((checks_passed++))
    fi

    if [[ "${VERIFY_SIZE}" == "true" ]]; then
        ((checks_performed++))
        check_total_size "$snapshot_path"
        [[ "$SIZE_PASS" -eq 1 ]] && ((checks_passed++))
    fi

    if [[ "${SPOT_CHECK_ENABLED}" == "true" ]]; then
        ((checks_performed++))
        check_spot_hash "$snapshot_path"
        [[ "$SPOT_CHECK_PASS" -eq 1 ]] && ((checks_passed++))
    fi

    local overall_pass="PASS"
    if [[ "$FILE_COUNT_PASS" -eq 0 || "$SIZE_PASS" -eq 0 || "$SPOT_CHECK_PASS" -eq 0 ]]; then
        overall_pass="FAIL"
        HAS_FAILURES=1
    fi

    local duration=$(( $(date '+%s') - SCRIPT_START_EPOCH ))
    local checks_failed=$(( checks_performed - checks_passed ))

    # Write full structured result for report consumption
    local result_path="${LOG_DIRECTORY}/${SCRIPT_NAME}_result_${RUN_TIMESTAMP}.json"
    cat > "$result_path" <<EOF
{
  "summary": {
    "status": "${overall_pass}",
    "snapshot": "${snapshot_name}",
    "snapshot_path": "${snapshot_path}",
    "checks_performed": ${checks_performed},
    "checks_passed": ${checks_passed},
    "checks_failed": ${checks_failed},
    "duration_seconds": ${duration},
    "log_file": "${LOG_FILE}"
  },
  "checks": {
    "file_count_pass": $( [[ "$FILE_COUNT_PASS" -eq 1 ]] && echo "true" || echo "false" ),
    "size_pass": $( [[ "$SIZE_PASS" -eq 1 ]] && echo "true" || echo "false" ),
    "spot_check_pass": $( [[ "$SPOT_CHECK_PASS" -eq 1 ]] && echo "true" || echo "false" ),
    "spot_check_skipped": $( [[ "$SPOT_CHECK_SKIPPED" -eq 1 ]] && echo "true" || echo "false" )
  }
}
EOF

    log_entry "INFO" "Integrity verification complete" \
        "status=${overall_pass}" "snapshot=${snapshot_name}" \
        "checks_performed=${checks_performed}" "checks_passed=${checks_passed}" "checks_failed=${checks_failed}" \
        "duration_seconds=${duration}"

    echo ""
    echo "--- Verification Summary ---"
    echo "Status         : ${overall_pass}"
    echo "Snapshot       : ${snapshot_name}"
    echo "Checks Passed  : ${checks_passed} / ${checks_performed}"
    echo "Duration       : ${duration}s"
    echo "Log File       : ${LOG_FILE}"
    echo "Result File    : ${result_path}"
    echo ""

    if [[ "$HAS_FAILURES" -eq 1 ]]; then
        exit "$EXIT_FAIL"
    else
        exit "$EXIT_PASS"
    fi
}

main "$@"

# =============================================================================
# END REGION
# =============================================================================