#!/usr/bin/env bash
# =============================================================================
# retention_manager.sh — Backup Retention & Disk Monitoring
# =============================================================================
# Manages backup retention on the Ubuntu destination server:
#   - Keeps only the most recent N backups per schema
#   - Monitors disk usage and alerts via Mattermost
#   - Checks that today's backup has arrived (heartbeat)
#
# Exit Codes:
#   0 — All checks passed
#   1 — Warning conditions detected
#   2 — Fatal error
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Backup storage
BACKUP_DIR="/data/backups/oracle"             # Directory where backups are stored
LOG_FILE="/var/log/backup_retention.log"       # Log file path

# Retention policy
KEEP_COUNT=100                                 # Number of most recent backups to keep PER SCHEMA

# Disk monitoring thresholds (percentage)
DISK_WARN_THRESHOLD=80                         # Send warning above this usage %
DISK_CRITICAL_THRESHOLD=90                     # Send critical alert above this usage %

# Maximum allowed size for backup directory in GB (0 = no limit)
MAX_BACKUP_DIR_SIZE_GB=500

# Heartbeat: expected backup arrival time
# If no new .gz file arrived today by this hour, send an alert
HEARTBEAT_EXPECTED_HOUR=5                      # Hour (24h format) by which backups should arrive

# Known schemas (space-separated) — must match SCHEMAS in oracle_backup.sh
KNOWN_SCHEMAS="HR FINANCE INVENTORY APP_DATA"

# Mattermost
MATTERMOST_WEBHOOK_URL=""
MATTERMOST_CHANNEL=""
MATTERMOST_USERNAME="Retention Bot"
NOTIFY_LEVEL="all"

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

TIMESTAMP=$(date +"%Y-%m-%d")
HOSTNAME=$(hostname -s)
EXIT_CODE=0

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${LOG_FILE}"
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# -----------------------------------------------------------------------------
# Mattermost
# -----------------------------------------------------------------------------
notify_mattermost() {
    local message="$1"
    local icon="$2"
    [[ -z "${MATTERMOST_WEBHOOK_URL}" ]] && return 0

    local payload
    if [[ -n "${MATTERMOST_CHANNEL}" ]]; then
        payload="{\"channel\": \"${MATTERMOST_CHANNEL}\", \"username\": \"${MATTERMOST_USERNAME}\", \"text\": \"${icon} **[${HOSTNAME}]** ${message}\"}"
    else
        payload="{\"username\": \"${MATTERMOST_USERNAME}\", \"text\": \"${icon} **[${HOSTNAME}]** ${message}\"}"
    fi

    curl -s -o /dev/null \
        -X POST -H "Content-Type: application/json" \
        -d "${payload}" \
        "${MATTERMOST_WEBHOOK_URL}" 2>>"${LOG_FILE}" || true
}

# -----------------------------------------------------------------------------
# Retention enforcement — keep only KEEP_COUNT most recent per schema
# -----------------------------------------------------------------------------
enforce_retention() {
    log_info "Enforcing retention: keeping ${KEEP_COUNT} most recent backups per schema"

    local total_deleted=0

    for schema in ${KNOWN_SCHEMAS}; do
        local file_list
        file_list=$(find "${BACKUP_DIR}" -maxdepth 1 -name "${schema}_*.dmp.gz" -type f -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | awk '{print $2}')

        local count=0
        local schema_deleted=0

        while IFS= read -r filepath; do
            [[ -z "${filepath}" ]] && continue
            count=$((count + 1))
            if (( count > KEEP_COUNT )); then
                log_info "Removing old backup: $(basename "${filepath}")"
                rm -f "${filepath}" "${filepath}.sha256" 2>/dev/null
                schema_deleted=$((schema_deleted + 1))
            fi
        done <<< "${file_list}"

        total_deleted=$((total_deleted + schema_deleted))

        if (( schema_deleted > 0 )); then
            log_info "Schema ${schema}: removed ${schema_deleted} old backup(s)"
        fi
    done

    # Clean orphaned .sha256 files
    local orphaned=0
    while IFS= read -r sha_file; do
        [[ -z "${sha_file}" ]] && continue
        local gz_file="${sha_file%.sha256}"
        if [[ ! -f "${gz_file}" ]]; then
            rm -f "${sha_file}"
            orphaned=$((orphaned + 1))
        fi
    done < <(find "${BACKUP_DIR}" -maxdepth 1 -name "*.sha256" -type f 2>/dev/null)

    log_info "Retention complete: ${total_deleted} backup(s) removed, ${orphaned} orphan(s) cleaned"
}

# -----------------------------------------------------------------------------
# Disk usage monitoring
# -----------------------------------------------------------------------------
check_disk_usage() {
    log_info "Checking disk usage for ${BACKUP_DIR}"

    local usage_pct
    usage_pct=$(df "${BACKUP_DIR}" | awk 'NR==2 {gsub(/%/,""); print $5}')

    local free_gb
    free_gb=$(df -BG "${BACKUP_DIR}" | awk 'NR==2 {gsub(/G/,""); print $4}')

    log_info "Disk usage: ${usage_pct}% (${free_gb}GB free)"

    if (( usage_pct >= DISK_CRITICAL_THRESHOLD )); then
        log_error "CRITICAL: Disk usage at ${usage_pct}% (${free_gb}GB free)"
        notify_mattermost "CRITICAL: Disk usage at ${usage_pct}% — only ${free_gb}GB free!" "🔴"
        EXIT_CODE=1
    elif (( usage_pct >= DISK_WARN_THRESHOLD )); then
        log_warn "WARNING: Disk usage at ${usage_pct}% (${free_gb}GB free)"
        notify_mattermost "WARNING: Disk usage at ${usage_pct}% — ${free_gb}GB free" "⚠️"
    fi

    if (( MAX_BACKUP_DIR_SIZE_GB > 0 )); then
        local dir_size_gb
        dir_size_gb=$(du -s --block-size=1G "${BACKUP_DIR}" 2>/dev/null | awk '{print $1}')
        log_info "Backup directory size: ${dir_size_gb}GB (limit: ${MAX_BACKUP_DIR_SIZE_GB}GB)"

        if (( dir_size_gb >= MAX_BACKUP_DIR_SIZE_GB )); then
            log_error "Backup directory exceeds size limit: ${dir_size_gb}GB >= ${MAX_BACKUP_DIR_SIZE_GB}GB"
            notify_mattermost "CRITICAL: Backup dir size (${dir_size_gb}GB) exceeds limit (${MAX_BACKUP_DIR_SIZE_GB}GB)!" "🔴"
            EXIT_CODE=1
        fi
    fi
}

# -----------------------------------------------------------------------------
# Heartbeat check — did today's backups arrive?
# -----------------------------------------------------------------------------
check_heartbeat() {
    local current_hour
    current_hour=$(date +%-H)

    if (( current_hour < HEARTBEAT_EXPECTED_HOUR )); then
        log_info "Heartbeat skipped — too early (now: ${current_hour}h, expected by: ${HEARTBEAT_EXPECTED_HOUR}h)"
        return 0
    fi

    log_info "Heartbeat check: verifying today's backups have arrived"

    local missing_schemas=""
    local missing_count=0

    for schema in ${KNOWN_SCHEMAS}; do
        local today_file="${BACKUP_DIR}/${schema}_${TIMESTAMP}.dmp.gz"
        if [[ ! -f "${today_file}" ]]; then
            missing_schemas="${missing_schemas} ${schema}"
            missing_count=$((missing_count + 1))
            log_warn "Missing today's backup for schema: ${schema}"
        fi
    done

    if (( missing_count > 0 )); then
        log_error "HEARTBEAT FAILED: ${missing_count} schema(s) missing:${missing_schemas}"
        notify_mattermost "HEARTBEAT: ${missing_count} backup(s) missing for ${TIMESTAMP}:${missing_schemas}" "🔴"
        EXIT_CODE=1
    else
        log_info "Heartbeat OK: all schema backups received for ${TIMESTAMP}"
        if [[ "${NOTIFY_LEVEL}" == "all" ]]; then
            notify_mattermost "Heartbeat OK: all backups received for ${TIMESTAMP}" "💚"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Generate status report
# -----------------------------------------------------------------------------
generate_report() {
    log_info "--- Backup Inventory Report ---"

    for schema in ${KNOWN_SCHEMAS}; do
        local count
        count=$(find "${BACKUP_DIR}" -maxdepth 1 -name "${schema}_*.dmp.gz" -type f 2>/dev/null | wc -l)
        local latest
        latest=$(find "${BACKUP_DIR}" -maxdepth 1 -name "${schema}_*.dmp.gz" -type f -printf '%T@ %f\n' 2>/dev/null \
            | sort -rn | head -1 | awk '{print $2}')
        local total_size
        total_size=$(find "${BACKUP_DIR}" -maxdepth 1 -name "${schema}_*.dmp.gz" -type f -exec du -ch {} + 2>/dev/null \
            | tail -1 | cut -f1)
        log_info "  ${schema}: ${count} backup(s), latest: ${latest:-none}, total: ${total_size:-0}"
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    log_info "========== Retention Manager Started =========="

    if [[ ! -d "${BACKUP_DIR}" ]]; then
        log_error "Backup directory does not exist: ${BACKUP_DIR}"
        notify_mattermost "Retention check FAILED — backup directory missing" "🔴"
        exit 2
    fi

    enforce_retention
    check_disk_usage
    check_heartbeat
    generate_report

    log_info "========== Retention Manager Completed (exit: ${EXIT_CODE}) =========="
    exit ${EXIT_CODE}
}

main "$@"
