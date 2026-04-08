#!/usr/bin/env bash
# =============================================================================
# sync_to_destination.sh -- Transfer backups to destination server via rsync/SSH
# =============================================================================
# Transfers compressed Oracle backups and their checksums from the source
# (Oracle Linux) server to the destination (Ubuntu) server using rsync over SSH.
# After transfer, verifies integrity using SHA-256 checksums on the remote side.
#
# This script should run AFTER oracle_backup.sh completes (e.g., at 04:00).
#
# Exit Codes:
#   0 -- All files transferred and verified successfully
#   1 -- Transfer or verification failure
#   2 -- Fatal error (connectivity, SSH, etc.)
# =============================================================================


set -o pipefail


# =============================================================================
# CONFIGURATION
# =============================================================================


# Source paths
BACKUP_DIR="/home/oracle/dpdump"                     # Local backup directory (must match oracle_backup.sh)
LOG_FILE="/var/log/oracle_sync.log"                  # Log file for sync operations


# Destination server details
DEST_HOST="backupsync"                               # SSH config host alias 
DEST_DIR="/data/backups/oracle/"                      # Remote directory to store backups
SSH_CONFIG="/home/backupsync/.ssh/config"             # Path to SSH config file


# rsync options
RSYNC_BANDWIDTH_LIMIT="50000"                        # Bandwidth limit in KB/s (0 = unlimited)
RSYNC_TIMEOUT=300                                    # Timeout in seconds for rsync stall detection
RSYNC_RETRIES=3                                      # Number of retry attempts on failure
RSYNC_RETRY_DELAY=30                                 # Seconds to wait between retries

# Mattermost webhook for notifications
MATTERMOST_WEBHOOK_URL=""                            # Same webhook URL as oracle_backup.sh
MATTERMOST_CHANNEL=""                                # Optional: override channel
MATTERMOST_USERNAME="Sync Bot"


# Notification levels: "all" = success+failure, "failure" = only failures
NOTIFY_LEVEL="all"


# =============================================================================
# END OF CONFIGURATION
# =============================================================================


TIMESTAMP=$(date +"%Y-%m-%d")
TIMESTAMP_FULL=$(date +"%Y-%m-%d_%H-%M-%S")
HOSTNAME=$(hostname -s)


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
# Mattermost notification
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


    curl -s -o /dev/null -w "" \
        -X POST -H "Content-Type: application/json" \
        -d "${payload}" \
        "${MATTERMOST_WEBHOOK_URL}" 2>>"${LOG_FILE}" || true
}


# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
preflight() {
    log_info "========== Sync Started ${TIMESTAMP_FULL} =========="


    if [[ ! -d "${BACKUP_DIR}" ]]; then
        log_error "Backup directory does not exist: ${BACKUP_DIR}"
        notify_mattermost "Sync ABORTED -- backup directory missing: ${BACKUP_DIR}" "🔴"
        exit 2
    fi


    if [[ ! -f "${SSH_CONFIG}" ]]; then
        log_error "SSH config not found: ${SSH_CONFIG}"
        notify_mattermost "Sync ABORTED -- SSH config missing: ${SSH_CONFIG}" "🔴"
        exit 2
    fi


    log_info "Testing SSH connectivity to ${DEST_HOST}"
    if ! ssh -F "${SSH_CONFIG}" -o ConnectTimeout=10 -o BatchMode=yes \
        "${DEST_HOST}" "echo ok" &>/dev/null; then
        log_error "SSH connection failed to ${DEST_HOST}"
        notify_mattermost "Sync ABORTED -- cannot connect to destination server via SSH" "🔴"
        exit 2
    fi
    log_info "SSH connectivity OK"


    local today_files
    today_files=$(find "${BACKUP_DIR}" -name "*_${TIMESTAMP}.dmp.gz" -type f 2>/dev/null | wc -l)
    if [[ ${today_files} -eq 0 ]]; then
        log_warn "No backup files found for today ${TIMESTAMP}"
        notify_mattermost "Sync WARNING -- no backup files found for ${TIMESTAMP}" "⚠️"
    fi
    log_info "Found ${today_files} backup file(s) for today"
}


# -----------------------------------------------------------------------------
# rsync transfer with retry logic
# -----------------------------------------------------------------------------
do_rsync() {
    local attempt=0
    local rsync_exit=1
    local ssh_cmd="ssh -F ${SSH_CONFIG} -o StrictHostKeyChecking=no -o BatchMode=yes"


    while (( attempt < RSYNC_RETRIES )); do
        attempt=$((attempt + 1))
        log_info "rsync attempt ${attempt}/${RSYNC_RETRIES}"


        rsync -avz \
            --bwlimit="${RSYNC_BANDWIDTH_LIMIT}" \
            --timeout="${RSYNC_TIMEOUT}" \
            --include="*_${TIMESTAMP}.dmp.gz" \
            --include="*_${TIMESTAMP}.dmp.gz.sha256" \
            --exclude="*" \
            -e "${ssh_cmd}" \
            "${BACKUP_DIR}/" \
            "${DEST_HOST}:${DEST_DIR}" \
            2>>"${LOG_FILE}"


        rsync_exit=$?


        if [[ ${rsync_exit} -eq 0 ]]; then
            log_info "rsync completed successfully on attempt ${attempt}"
            return 0
        fi


        log_warn "rsync failed exit code: ${rsync_exit} -- attempt ${attempt}/${RSYNC_RETRIES}"


        if (( attempt < RSYNC_RETRIES )); then
            log_info "Waiting ${RSYNC_RETRY_DELAY}s before retry..."
            sleep "${RSYNC_RETRY_DELAY}"
        fi
    done


    log_error "rsync failed after ${RSYNC_RETRIES} attempts"
    return 1
}


# -----------------------------------------------------------------------------
# Remote checksum verification
# -----------------------------------------------------------------------------
verify_checksums() {
    log_info "Verifying checksums on destination server..."


    local verify_result
    verify_result=$(ssh -F "${SSH_CONFIG}" -o BatchMode=yes \
        "${DEST_HOST}" \
        "cd ${DEST_DIR} && find . -name '*_${TIMESTAMP}.dmp.gz.sha256' -exec sh -c 'sha256sum -c \"{}\" 2>&1' \;" \
        2>>"${LOG_FILE}")


    local verify_exit=$?


    if [[ ${verify_exit} -ne 0 ]]; then
        log_error "Remote checksum verification FAILED"
        log_error "Verification output: ${verify_result}"
        return 1
    fi


    if echo "${verify_result}" | grep -q "FAILED"; then
        log_error "One or more checksums did NOT match:"
        echo "${verify_result}" | grep "FAILED" | while read -r line; do
            log_error "  ${line}"
        done
        return 1
    fi


    local ok_count
    ok_count=$(echo "${verify_result}" | grep -c "OK" || echo "0")
    log_info "Checksum verification passed: ${ok_count} files verified"
    return 0
}


# -----------------------------------------------------------------------------
# Measure transfer duration
# -----------------------------------------------------------------------------
measure_transfer() {
    local start_time=$1
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - start_time ))
    local minutes=$(( duration / 60 ))
    local seconds=$(( duration % 60 ))
    echo "${minutes}m ${seconds}s"
}


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    preflight


    local start_time
    start_time=$(date +%s)


    if do_rsync; then
        local duration
        duration=$(measure_transfer "${start_time}")
        log_info "Transfer completed in ${duration}"


        if verify_checksums; then
            log_info "========== Sync Completed Successfully =========="
            if [[ "${NOTIFY_LEVEL}" == "all" ]]; then
                notify_mattermost "Backup sync completed in ${duration} -- all checksums verified" "🟢"
            fi
            exit 0
        else
            log_error "========== Sync Failed: Checksum Mismatch =========="
            notify_mattermost "Backup sync FAILED -- checksum verification error after transfer" "🔴"
            exit 1
        fi
    else
        log_error "========== Sync Failed: Transfer Error =========="
        notify_mattermost "Backup sync FAILED -- rsync could not complete after ${RSYNC_RETRIES} attempts" "🔴"
        exit 1
    fi
}


main "$@"