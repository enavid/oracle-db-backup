#!/usr/bin/env bash
# =============================================================================
# oracle_backup.sh — Oracle Schema Export & Compress
# =============================================================================
# Exports specified Oracle schemas using Data Pump (expdp), compresses them,
# generates SHA-256 checksums, and sends status notifications to Mattermost.
#
# Exit Codes:
#   0 — All schemas exported successfully
#   1 — One or more schemas failed (partial success)
#   2 — Fatal error (env setup, directory creation, etc.)
# =============================================================================

set -o pipefail

# =============================================================================
# CONFIGURATION — Adjust all values below to match your environment
# =============================================================================

# Oracle environment variables (required for expdp to function)
export ORACLE_HOME="/u01/app/oracle/product/19.0.0/dbhome_1"   # Path to Oracle home directory
export ORACLE_SID="ORCL"                                        # Oracle System Identifier
export ORACLE_BASE="/u01/app/oracle"                             # Oracle base directory
export PATH="${ORACLE_HOME}/bin:${PATH}"                         # Ensure expdp is in PATH
export NLS_LANG="AMERICAN_AMERICA.AL32UTF8"                      # Character set for export

# Database connection string (use Oracle Wallet for passwordless auth if possible)
# Option A: Wallet-based (recommended) — set DB_USER="" and DB_PASS="" and use DB_CONN="/@WALLET_ALIAS"
# Option B: Username/password — fill in all three
DB_USER="system"                          # Database username with DATAPUMP_EXP_FULL_DATABASE or schema-level access
DB_PASS="changeme"                        # Database password (prefer Oracle Wallet instead)
DB_CONN=""                                # TNS alias or connection string (leave empty for local SID connection)

# Schemas to export (space-separated list)
SCHEMAS="HR FINANCE INVENTORY APP_DATA"

# Directory paths
BACKUP_DIR="/opt/oracle_backups"          # Local directory to store .dmp and .gz files
EXPDP_DIR_NAME="dump"              # Oracle directory object name pointing to BACKUP_DIR
LOG_FILE="/var/log/oracle_backup.log"     # Log file path
PARALLEL=8

# Retention policy
KEEP_LOCAL_DAYS=7                         # Number of days to keep local backups before cleanup

# Mattermost webhook for notifications
MATTERMOST_WEBHOOK_URL=""                 # Full incoming webhook URL (e.g., https://mattermost.example.com/hooks/xxx)
MATTERMOST_CHANNEL=""                     # Optional: override channel (leave empty for webhook default)
MATTERMOST_USERNAME="Oracle Backup Bot"   # Display name in Mattermost

# Notification levels: "all" = success+failure, "failure" = only failures
NOTIFY_LEVEL="all"

# =============================================================================
# END OF CONFIGURATION — Do not modify below unless you know what you're doing
# =============================================================================

TIMESTAMP=$(date +"%Y-%m-%d")
TIMESTAMP_FULL=$(date +"%Y-%m-%d_%H-%M-%S")
HOSTNAME=$(hostname -s)
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_SCHEMAS=""

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${LOG_FILE}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# -----------------------------------------------------------------------------
# Mattermost notification
# -----------------------------------------------------------------------------
notify_mattermost() {
    local message="$1"
    local icon="$2"

    if [[ -z "${MATTERMOST_WEBHOOK_URL}" ]]; then
        log_warn "Mattermost webhook URL is not configured — skipping notification"
        return 0
    fi

    local payload
    if [[ -n "${MATTERMOST_CHANNEL}" ]]; then
        payload="{\"channel\": \"${MATTERMOST_CHANNEL}\", \"username\": \"${MATTERMOST_USERNAME}\", \"text\": \"${icon} **[${HOSTNAME}]** ${message}\"}"
    else
        payload="{\"username\": \"${MATTERMOST_USERNAME}\", \"text\": \"${icon} **[${HOSTNAME}]** ${message}\"}"
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${MATTERMOST_WEBHOOK_URL}" 2>>"${LOG_FILE}")

    if [[ "${http_code}" != "200" ]]; then
        log_warn "Mattermost notification failed with HTTP ${http_code}"
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
preflight() {
    log_info "========== Oracle Backup Started (${TIMESTAMP_FULL}) =========="

    if [[ ! -d "${ORACLE_HOME}" ]]; then
        log_error "ORACLE_HOME does not exist: ${ORACLE_HOME}"
        notify_mattermost "Oracle backup ABORTED — ORACLE_HOME not found: ${ORACLE_HOME}" "🔴"
        exit 2
    fi

    if ! command -v expdp &>/dev/null; then
        log_error "expdp binary not found in PATH"
        notify_mattermost "Oracle backup ABORTED — expdp not found in PATH" "🔴"
        exit 2
    fi

    if [[ ! -d "${BACKUP_DIR}" ]]; then
        log_info "Creating backup directory: ${BACKUP_DIR}"
        mkdir -p "${BACKUP_DIR}" || {
            log_error "Failed to create backup directory: ${BACKUP_DIR}"
            notify_mattermost "Oracle backup ABORTED — cannot create ${BACKUP_DIR}" "🔴"
            exit 2
        }
    fi

    local free_kb
    free_kb=$(df -k "${BACKUP_DIR}" | awk 'NR==2 {print $4}')
    local free_gb=$(( free_kb / 1024 / 1024 ))
    if (( free_gb < 10 )); then
        log_warn "Low disk space on ${BACKUP_DIR}: ${free_gb}GB free"
        notify_mattermost "Low disk space warning on backup volume: ${free_gb}GB free" "⚠️"
    fi

    log_info "Schemas to export: ${SCHEMAS}"
    log_info "Backup directory: ${BACKUP_DIR}"
}

# -----------------------------------------------------------------------------
# Build expdp connection string
# -----------------------------------------------------------------------------
get_connect_string() {
    if [[ -n "${DB_CONN}" ]]; then
        if [[ -n "${DB_USER}" && -n "${DB_PASS}" ]]; then
            echo "${DB_USER}/${DB_PASS}@${DB_CONN}"
        else
            echo "${DB_CONN}"
        fi
    else
        echo "${DB_USER}/${DB_PASS}"
    fi
}

# -----------------------------------------------------------------------------
# Export a single schema
# -----------------------------------------------------------------------------
export_schema() {
    local schema="$1"
    local dump_file="${schema}_${TIMESTAMP}.dmp"
    local log_name="${schema}_${TIMESTAMP}.expdp.log"
    local connect_str
    connect_str=$(get_connect_string)

    log_info "Exporting schema: ${schema} → ${dump_file}"

    expdp "'${DB_USER}/${DB_PASS} as sysdba'" SCHEMAS="${schema}" DIRECTORY="${EXPDP_DIR_NAME}" DUMPFILE="${dump_file}" PARALLEL=$"{PARALLEL}" FLASHBACK_TIME=SYSTIMESTAMP COMPRESSION=ALL 2>>"${LOG_FILE}" 

    local expdp_exit=$?

    if [[ ${expdp_exit} -ne 0 ]]; then
        log_error "expdp FAILED for schema ${schema} (exit code: ${expdp_exit})"
        if [[ -f "${BACKUP_DIR}/${log_name}" ]]; then
            local ora_errors
            ora_errors=$(grep -c "ORA-" "${BACKUP_DIR}/${log_name}" 2>/dev/null || echo "0")
            log_error "Found ${ora_errors} ORA- errors in ${log_name}"
        fi
        return 1
    fi

    if [[ ! -s "${BACKUP_DIR}/${dump_file}" ]]; then
        log_error "Dump file is missing or empty: ${BACKUP_DIR}/${dump_file}"
        return 1
    fi

    local dump_size
    dump_size=$(du -h "${BACKUP_DIR}/${dump_file}" | cut -f1)
    log_info "Export complete: ${dump_file} (${dump_size})"

    log_info "Compressing ${dump_file} ..."
    if gzip -f "${BACKUP_DIR}/${dump_file}"; then
        local gz_size
        gz_size=$(du -h "${BACKUP_DIR}/${dump_file}.gz" | cut -f1)
        log_info "Compressed: ${dump_file}.gz (${gz_size})"
    else
        log_error "gzip failed for ${dump_file}"
        return 1
    fi

    log_info "Generating SHA-256 checksum for ${dump_file}.gz"
    if ! (cd "${BACKUP_DIR}" && sha256sum "${dump_file}.gz" > "${dump_file}.gz.sha256"); then
        log_error "Checksum generation failed for ${dump_file}.gz"
        return 1
    fi

    log_info "Checksum saved: ${dump_file}.gz.sha256"
    return 0
}

# -----------------------------------------------------------------------------
# Cleanup old local backups
# -----------------------------------------------------------------------------
cleanup_local() {
    log_info "Cleaning up local backups older than ${KEEP_LOCAL_DAYS} days"
    local deleted
    deleted=$(find "${BACKUP_DIR}" -name "*.dmp.gz" -mtime "+${KEEP_LOCAL_DAYS}" -delete -print 2>/dev/null | wc -l)
    find "${BACKUP_DIR}" -name "*.sha256" -mtime "+${KEEP_LOCAL_DAYS}" -delete 2>/dev/null
    find "${BACKUP_DIR}" -name "*.expdp.log" -mtime "+${KEEP_LOCAL_DAYS}" -delete 2>/dev/null
    log_info "Removed ${deleted} old backup file(s)"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    preflight

    for schema in ${SCHEMAS}; do
        if export_schema "${schema}"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            if [[ "${NOTIFY_LEVEL}" == "all" ]]; then
                notify_mattermost "Schema **${schema}** exported successfully (${TIMESTAMP})" "✅"
            fi
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_SCHEMAS="${FAILED_SCHEMAS} ${schema}"
            notify_mattermost "Schema **${schema}** export FAILED (${TIMESTAMP}) — check logs" "🔴"
        fi
    done

    cleanup_local

    log_info "========== Backup Summary =========="
    log_info "Successful: ${SUCCESS_COUNT} | Failed: ${FAIL_COUNT}"

    if [[ ${FAIL_COUNT} -gt 0 ]]; then
        log_error "Failed schemas:${FAILED_SCHEMAS}"
        notify_mattermost "Backup summary: ${SUCCESS_COUNT} OK, ${FAIL_COUNT} FAILED (${FAILED_SCHEMAS})" "🟡"
        exit 1
    else
        log_info "All schemas exported successfully"
        if [[ "${NOTIFY_LEVEL}" == "all" ]]; then
            notify_mattermost "All ${SUCCESS_COUNT} schemas exported successfully (${TIMESTAMP})" "🟢"
        fi
        exit 0
    fi
}

main "$@"
