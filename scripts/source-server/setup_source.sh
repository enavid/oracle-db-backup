#!/usr/bin/env bash
# =============================================================================
# setup_source.sh — Initial setup for the Oracle Linux source server
# =============================================================================
# Creates required users, directories, Oracle directory object, and permissions.
# Run this script ONCE as root (or with sudo) during initial setup.
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

BACKUP_DIR="/opt/oracle_backups"              # Local backup directory
LOG_DIR="/var/log"                             # Log directory
SYNC_USER="backupsync"                        # User for rsync operations
ORACLE_USER="oracle"                          # OS user that owns Oracle installation
BACKUP_GROUP="backupgrp"                       # Shared group

# Oracle directory object (must match EXPDP_DIR_NAME in oracle_backup.sh)
ORACLE_DIR_NAME="BACKUP_DIR"

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

echo "=== Oracle Backup Shuttle — Source Server Setup ==="
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or with sudo)"
    exit 1
fi

# Create shared group
if ! getent group "${BACKUP_GROUP}" &>/dev/null; then
    echo "[+] Creating group: ${BACKUP_GROUP}"
    groupadd "${BACKUP_GROUP}"
else
    echo "[=] Group already exists: ${BACKUP_GROUP}"
fi

# Add oracle user to backup group
echo "[+] Adding ${ORACLE_USER} to ${BACKUP_GROUP}"
usermod -aG "${BACKUP_GROUP}" "${ORACLE_USER}"

# Create backupsync user
if ! id "${SYNC_USER}" &>/dev/null; then
    echo "[+] Creating user: ${SYNC_USER}"
    useradd -m -g "${BACKUP_GROUP}" -s /bin/bash "${SYNC_USER}"
else
    echo "[=] User already exists: ${SYNC_USER}"
fi

# Create backup directory
echo "[+] Creating backup directory: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
chown "${ORACLE_USER}:${BACKUP_GROUP}" "${BACKUP_DIR}"
chmod 2750 "${BACKUP_DIR}"

# Create log files
for logfile in "oracle_backup.log" "oracle_sync.log"; do
    touch "${LOG_DIR}/${logfile}"
    chown "${ORACLE_USER}:${BACKUP_GROUP}" "${LOG_DIR}/${logfile}"
    chmod 660 "${LOG_DIR}/${logfile}"
done

# Generate SSH key for backupsync
SYNC_SSH_DIR="/home/${SYNC_USER}/.ssh"
if [[ ! -f "${SYNC_SSH_DIR}/id_ed25519" ]]; then
    echo "[+] Generating SSH key for ${SYNC_USER}"
    mkdir -p "${SYNC_SSH_DIR}"
    ssh-keygen -t ed25519 -C "backup-sync-key-$(hostname -s)" -f "${SYNC_SSH_DIR}/id_ed25519" -N ""
    chown -R "${SYNC_USER}:${BACKUP_GROUP}" "${SYNC_SSH_DIR}"
    chmod 700 "${SYNC_SSH_DIR}"
    chmod 600 "${SYNC_SSH_DIR}/id_ed25519"
    echo ""
    echo "PUBLIC KEY (add this to destination server's authorized_keys):"
    echo "---"
    cat "${SYNC_SSH_DIR}/id_ed25519.pub"
    echo "---"
else
    echo "[=] SSH key already exists for ${SYNC_USER}"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "NEXT STEPS:"
echo "1. Create Oracle directory object (run as SYS/SYSTEM in SQL*Plus):"
echo "   CREATE OR REPLACE DIRECTORY ${ORACLE_DIR_NAME} AS '${BACKUP_DIR}';"
echo "   GRANT READ, WRITE ON DIRECTORY ${ORACLE_DIR_NAME} TO SYSTEM;"
echo ""
echo "2. Copy the public key above to the destination server."
echo "3. Install the systemd timers (see README.md)."
