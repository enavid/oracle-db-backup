#!/usr/bin/env bash
# =============================================================================
# setup_destination.sh — Initial setup for the Ubuntu destination server
# =============================================================================
# Creates required users, directories, and permissions on the Ubuntu server.
# Run this script ONCE as root (or with sudo) during initial setup.
#
# Creates:
#   - backuprecv  : receives rsync data (restricted via rrsync)
#   - backupmgr   : manages retention, monitoring, alerts
#   - Required directories with correct ownership and permissions
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

BACKUP_BASE_DIR="/data/backups/oracle"        # Where backups are stored
LOG_DIR="/var/log"                             # Log directory
RECV_USER="backuprecv"                        # User that receives rsync transfers
MGR_USER="backupmgr"                          # User that manages retention/monitoring
BACKUP_GROUP="backupgrp"                       # Shared group for backup directory access

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

echo "=== Oracle Backup Shuttle — Destination Server Setup ==="
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

# Create backuprecv user
if ! id "${RECV_USER}" &>/dev/null; then
    echo "[+] Creating user: ${RECV_USER} (restricted rsync receiver)"
    useradd -m -g "${BACKUP_GROUP}" -s /bin/bash "${RECV_USER}"
else
    echo "[=] User already exists: ${RECV_USER}"
fi

# Create backupmgr user
if ! id "${MGR_USER}" &>/dev/null; then
    echo "[+] Creating user: ${MGR_USER} (retention manager)"
    useradd -m -g "${BACKUP_GROUP}" -s /bin/bash "${MGR_USER}"
else
    echo "[=] User already exists: ${MGR_USER}"
fi

# Create backup directory
echo "[+] Creating backup directory: ${BACKUP_BASE_DIR}"
mkdir -p "${BACKUP_BASE_DIR}"
chown "${RECV_USER}:${BACKUP_GROUP}" "${BACKUP_BASE_DIR}"
chmod 2770 "${BACKUP_BASE_DIR}"

# Create log files
for logfile in "backup_retention.log" "backup_heartbeat.log"; do
    touch "${LOG_DIR}/${logfile}"
    chown "${MGR_USER}:${BACKUP_GROUP}" "${LOG_DIR}/${logfile}"
    chmod 640 "${LOG_DIR}/${logfile}"
done

# Setup SSH directory for backuprecv
RECV_SSH_DIR="/home/${RECV_USER}/.ssh"
mkdir -p "${RECV_SSH_DIR}"
chmod 700 "${RECV_SSH_DIR}"
touch "${RECV_SSH_DIR}/authorized_keys"
chmod 600 "${RECV_SSH_DIR}/authorized_keys"
chown -R "${RECV_USER}:${BACKUP_GROUP}" "${RECV_SSH_DIR}"

# Install rrsync if not present
if [[ ! -f /usr/local/bin/rrsync ]]; then
    echo "[+] Installing rrsync (restricted rsync wrapper)"
    RRSYNC_SRC=$(find /usr -name "rrsync" -type f 2>/dev/null | head -1)
    if [[ -n "${RRSYNC_SRC}" ]]; then
        cp "${RRSYNC_SRC}" /usr/local/bin/rrsync
        chmod 755 /usr/local/bin/rrsync
        echo "    Installed from: ${RRSYNC_SRC}"
    else
        # Try extracting from gzip
        RRSYNC_GZ=$(find /usr -name "rrsync.gz" -type f 2>/dev/null | head -1)
        if [[ -n "${RRSYNC_GZ}" ]]; then
            gunzip -c "${RRSYNC_GZ}" > /usr/local/bin/rrsync
            chmod 755 /usr/local/bin/rrsync
            echo "    Installed from: ${RRSYNC_GZ}"
        else
            echo "    WARNING: rrsync not found. Install manually:"
            echo "    apt install rsync && cp /usr/share/doc/rsync/scripts/rrsync /usr/local/bin/"
        fi
    fi
else
    echo "[=] rrsync already installed"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. On the SOURCE server, generate an SSH key for backupsync user:"
echo "   sudo -u backupsync ssh-keygen -t ed25519 -C 'backup-sync-key' -N ''"
echo ""
echo "2. Add the public key to ${RECV_SSH_DIR}/authorized_keys:"
echo "   command=\"/usr/local/bin/rrsync ${BACKUP_BASE_DIR}\",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA..."
echo ""
echo "3. Test: sudo -u backupsync ssh -i ~/.ssh/id_ed25519 ${RECV_USER}@<dest-ip> ls"
echo ""
echo "4. Install systemd timer for retention_manager.sh (see README.md)."
