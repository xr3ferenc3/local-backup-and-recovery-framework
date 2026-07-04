#!/usr/bin/env bash
#
# =============================================================================
# generate-report.sh
# =============================================================================
#
# SYNOPSIS
#   Generates a structured, audit-ready report from backup and verification
#   log data for a specified snapshot.
#
# DESCRIPTION
#   generate-report.sh aggregates the JSON log output produced by backup.sh
#   and verify-backup.sh into a single coherent report, suitable for
#   attachment to tickets, inclusion in audit records, or routine
#   management review.
#
#   The script locates the most relevant log entries for the specified
#   snapshot, extracts backup execution results, integrity verification
#   results, and retention context, and renders them into the configured
#   output format (markdown or json).
#
#   This script does not perform any backup operations itself. It is a
#   read-only reporting layer over existing log and result data.
#
# USAGE
#   ./linux/generate-report.sh --config <path> [--snapshot <name>] [--output <path>]
#
# OPTIONS
#   --config <path>     Path to the populated configuration file (required)
#   --snapshot <name>   Snapshot to report on. Defaults to most recent.
#   --output <path>     Overrides the configured report output directory
#                        for this run.
#   --help                Display this usage information
#
# EXIT CODES
#   0   Report generated successfully
#   1   Report generated with missing data (partial report)
#   2   Fatal error — no log data found for the snapshot
#
# REQUIRES
#   bash 4.0+, grep, sed, find (findutils)
#
# REFERENCE
#   docs/command-reference.md
# =============================================================================

set -u
set -o pipefail

# =============================================================================
# REGION: Constants
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="generate-report"
readonly EXIT_SUCCESS=0
readonly EXIT_PARTIAL=1
readonly EXIT_FATAL=2

RUN_TIMESTAMP="$(date '+%Y-%m-%d_%H%M')"

CONFIG_PATH=""
REQUESTED_SNAPSHOT=""
OUTPUT_OVERRIDE=""
IS_PARTIAL=0

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Argument Parsing
# =============================================================================

print_usage() {
    cat <<EOF
Usage: $0 --config <path> [--snapshot <name>] [--output <path>]

Options:
  --config <path>     Path to the populated configuration file (required)
  --snapshot <name>   Snapshot to report on. Defaults to most recent.
  --output <path>     Overrides the configured report output directory
  --help                Display this usage information
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_PATH="$2"; shift 2 ;;
        --snapshot) REQUESTED_SNAPSHOT="$2"; shift 2 ;;
        --output) OUTPUT_OVERRIDE="$2"; shift 2 ;;
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
        "DESTINATION_ROOT" "BACKUP_HOST_LABEL" "LOG_DIRECTORY"
        "REPORT_OUTPUT_DIRECTORY" "REPORT_FORMAT"
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

resolve_snapshot_path() {
    if [[ -n "$REQUESTED_SNAPSHOT" ]]; then
        local path="${DESTINATION_ROOT}/${REQUESTED_SNAPSHOT}"
        if [[ ! -d "$path" ]]; then
            echo "ERROR: Specified snapshot not found: $path" >&2
            exit "$EXIT_FATAL"
        fi
        echo "$REQUESTED_SNAPSHOT"
        return
    fi

    local latest
    latest="$(find "$DESTINATION_ROOT" -maxdepth 1 -type d -name "${BACKUP_HOST_LABEL}_*" 2>/dev/null | sort -r | head -n 1)"

    if [[ -z "$latest" ]]; then
        echo "ERROR: No snapshots found under destination root: $DESTINATION_ROOT" >&2
        exit "$EXIT_FATAL"
    fi

    basename "$latest"
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Log Data Extraction
# =============================================================================

# extract_json_value JSON_LINE KEY
# Extracts a scalar value for KEY from a single-line JSON object using
# grep/sed. Avoids a jq dependency. Handles both quoted (string) and
# unquoted (numeric/boolean) values.
extract_json_value() {
    local json_line="$1"
    local key="$2"

    echo "$json_line" | grep -o "\"${key}\":\"[^\"]*\"" | sed "s/\"${key}\":\"//;s/\"$//" \
        || echo "$json_line" | grep -o "\"${key}\":[^,}]*" | sed "s/\"${key}\"://"
}

# get_backup_run_data SNAPSHOT_NAME
# Searches backup.sh log files for the "Backup run complete" entry matching
# the given snapshot. Echoes the matching JSON line, or empty if not found.
get_backup_run_data() {
    local snapshot_name="$1"

    local log_files
    log_files="$(find "$LOG_DIRECTORY" -maxdepth 1 -name "backup_*.json" -type f 2>/dev/null | sort -r)"

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local match
        match="$(grep "\"message\":\"Backup run complete\"" "$file" 2>/dev/null | grep "\"snapshot\":\"${snapshot_name}\"")"
        if [[ -n "$match" ]]; then
            echo "$match"
            return
        fi
    done <<< "$log_files"

    echo ""
}

# get_integrity_result_file SNAPSHOT_NAME
# Locates the verify-backup.sh result JSON file matching the given snapshot.
# Echoes the file path, or empty if not found.
get_integrity_result_file() {
    local snapshot_name="$1"

    local result_files
    result_files="$(find "$LOG_DIRECTORY" -maxdepth 1 -name "verify-backup_result_*.json" -type f 2>/dev/null | sort -r)"

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if grep -q "\"snapshot\": \"${snapshot_name}\"" "$file" 2>/dev/null; then
            echo "$file"
            return
        fi
    done <<< "$result_files"

    echo ""
}

# get_retention_context
# Counts total snapshots present and reports configured retention policy.
get_retention_context() {
    local total_snapshots
    total_snapshots="$(find "$DESTINATION_ROOT" -maxdepth 1 -type d -name "${BACKUP_HOST_LABEL}_*" 2>/dev/null | wc -l)"
    echo "${total_snapshots}|${RETAIN_DAYS}|${MINIMUM_SNAPSHOTS_TO_KEEP}"
}

# =============================================================================
# END REGION
# =============================================================================


# =============================================================================
# REGION: Report Rendering
# =============================================================================

# render_markdown_report SNAPSHOT_NAME BACKUP_DATA_LINE INTEGRITY_RESULT_FILE RETENTION_CONTEXT
render_markdown_report() {
    local snapshot_name="$1"
    local backup_data_line="$2"
    local integrity_result_file="$3"
    local retention_context="$4"

    local generated_at
    generated_at="$(date '+%Y-%m-%d %H:%M:%S')"

    local total_snapshots retain_days min_keep
    total_snapshots="$(echo "$retention_context" | cut -d'|' -f1)"
    retain_days="$(echo "$retention_context" | cut -d'|' -f2)"
    min_keep="$(echo "$retention_context" | cut -d'|' -f3)"

    {
        echo "# Backup Report — ${snapshot_name}"
        echo ""
        echo "**Generated:** ${generated_at}"
        echo "**Host Label:** ${BACKUP_HOST_LABEL}"
        echo "**Report Tool:** ${SCRIPT_NAME} v${SCRIPT_VERSION}"
        echo ""
        echo "---"
        echo ""
        echo "## Backup Execution"
        echo ""

        if [[ -n "$backup_data_line" ]]; then
            local b_status b_total b_success b_failed b_duration b_dry_run
            b_status="$(extract_json_value "$backup_data_line" "status")"
            b_total="$(extract_json_value "$backup_data_line" "sources_total")"
            b_success="$(extract_json_value "$backup_data_line" "sources_success")"
            b_failed="$(extract_json_value "$backup_data_line" "sources_failed")"
            b_duration="$(extract_json_value "$backup_data_line" "duration_seconds")"
            b_dry_run="$(extract_json_value "$backup_data_line" "dry_run")"

            local status_label="PASS"
            [[ "$b_status" != "SUCCESS" ]] && status_label="ATTENTION REQUIRED"

            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Status | ${status_label} (${b_status}) |"
            echo "| Sources Total | ${b_total} |"
            echo "| Sources Succeeded | ${b_success} |"
            echo "| Sources Failed | ${b_failed} |"
            echo "| Duration | ${b_duration}s |"
            echo "| Dry Run | ${b_dry_run} |"
            echo ""
        else
            echo "**No backup execution log data found for this snapshot.**"
            echo ""
            echo "This report may have been generated against a snapshot whose logs have"
            echo "since rotated out, or the snapshot was created outside this framework."
            echo ""
            IS_PARTIAL=1
        fi

        echo "## Integrity Verification"
        echo ""

        if [[ -n "$integrity_result_file" ]]; then
            local i_status i_performed i_passed i_failed
            i_status="$(grep '"status"' "$integrity_result_file" | head -1 | sed 's/.*"status": "\([^"]*\)".*/\1/')"
            i_performed="$(grep '"checks_performed"' "$integrity_result_file" | sed 's/[^0-9]*\([0-9]*\).*/\1/')"
            i_passed="$(grep '"checks_passed"' "$integrity_result_file" | sed 's/[^0-9]*\([0-9]*\).*/\1/')"
            i_failed="$(grep '"checks_failed"' "$integrity_result_file" | sed 's/[^0-9]*\([0-9]*\).*/\1/')"

            local i_status_label="PASS"
            [[ "$i_status" != "PASS" ]] && i_status_label="FAIL"

            echo "| Field | Value |"
            echo "|---|---|"
            echo "| Status | ${i_status_label} (${i_status}) |"
            echo "| Checks Performed | ${i_performed} |"
            echo "| Checks Passed | ${i_passed} |"
            echo "| Checks Failed | ${i_failed} |"
            echo ""
        else
            echo "**No integrity verification data found for this snapshot.**"
            echo ""
            echo "Run verify-backup.sh against this snapshot before relying on it for"
            echo "restoration. An unverified backup is an unconfirmed assumption."
            echo ""
            IS_PARTIAL=1
        fi

        echo "## Retention Context"
        echo ""
        echo "| Field | Value |"
        echo "|---|---|"
        echo "| Total Snapshots Present | ${total_snapshots} |"
        echo "| Retention Window | ${retain_days} days |"
        echo "| Minimum Snapshots Protected | ${min_keep} |"
        echo ""
        echo "---"
        echo ""
        echo "*This report was generated automatically from structured log data. It is*"
        echo "*suitable for attachment to change tickets, incident records, and audit logs.*"
    }
}

# render_json_report SNAPSHOT_NAME BACKUP_DATA_LINE INTEGRITY_RESULT_FILE RETENTION_CONTEXT
render_json_report() {
    local snapshot_name="$1"
    local backup_data_line="$2"
    local integrity_result_file="$3"
    local retention_context="$4"

    local total_snapshots retain_days min_keep
    total_snapshots="$(echo "$retention_context" | cut -d'|' -f1)"
    retain_days="$(echo "$retention_context" | cut -d'|' -f2)"
    min_keep="$(echo "$retention_context" | cut -d'|' -f3)"

    local backup_json="null"
    [[ -n "$backup_data_line" ]] && backup_json="$backup_data_line"

    local integrity_json="null"
    if [[ -n "$integrity_result_file" ]]; then
        integrity_json="$(cat "$integrity_result_file")"
    fi

    cat <<EOF
{
  "report_generated_at": "$(date '+%Y-%m-%dT%H:%M:%S')",
  "snapshot": "${snapshot_name}",
  "host_label": "${BACKUP_HOST_LABEL}",
  "backup_execution": ${backup_json},
  "integrity_verification": ${integrity_json},
  "retention_context": {
    "total_snapshots_present": ${total_snapshots},
    "retain_days": ${retain_days},
    "minimum_snapshots_to_keep": ${min_keep}
  },
  "is_partial_report": $( [[ "$IS_PARTIAL" -eq 1 ]] && echo "true" || echo "false" )
}
EOF
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

    echo "Resolving snapshot..."
    local snapshot_name
    snapshot_name="$(resolve_snapshot_path)"
    echo "Reporting on: ${snapshot_name}"
    echo ""

    local backup_data_line
    backup_data_line="$(get_backup_run_data "$snapshot_name")"

    local integrity_result_file
    integrity_result_file="$(get_integrity_result_file "$snapshot_name")"

    local retention_context
    retention_context="$(get_retention_context)"

    if [[ -z "$backup_data_line" && -z "$integrity_result_file" ]]; then
        echo "ERROR: No backup execution or integrity verification log data found for snapshot '${snapshot_name}'. Cannot generate a meaningful report." >&2
        exit "$EXIT_FATAL"
    fi

    local output_dir="${OUTPUT_OVERRIDE:-$REPORT_OUTPUT_DIRECTORY}"
    if [[ ! -d "$output_dir" ]]; then
        mkdir -p "$output_dir"
    fi

    local report_file
    if [[ "$REPORT_FORMAT" == "json" ]]; then
        report_file="${output_dir}/report_${snapshot_name}_${RUN_TIMESTAMP}.json"
        render_json_report "$snapshot_name" "$backup_data_line" "$integrity_result_file" "$retention_context" > "$report_file"
    else
        report_file="${output_dir}/report_${snapshot_name}_${RUN_TIMESTAMP}.md"
        render_markdown_report "$snapshot_name" "$backup_data_line" "$integrity_result_file" "$retention_context" > "$report_file"
    fi

    echo "--- Report Summary ---"
    echo "Snapshot        : ${snapshot_name}"
    echo "Format          : ${REPORT_FORMAT}"
    echo "Partial Report  : $( [[ "$IS_PARTIAL" -eq 1 ]] && echo true || echo false )"
    echo "Output File     : ${report_file}"
    echo ""

    if [[ "$IS_PARTIAL" -eq 1 ]]; then
        exit "$EXIT_PARTIAL"
    else
        exit "$EXIT_SUCCESS"
    fi
}

main "$@"

# =============================================================================
# END REGION
# =============================================================================