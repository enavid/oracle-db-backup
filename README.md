# Oracle Backup Shuttle 🚀

> Automated Oracle database schema backup, secure transfer, and retention management with Mattermost notifications.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)]()

## Overview

Oracle Backup Shuttle automates the complete lifecycle of Oracle database backups:

1. **Export** — Dumps Oracle schemas using Data Pump (`expdp`) with compression
2. **Checksum** — Generates SHA-256 checksums for integrity verification
3. **Transfer** — Securely syncs backups to a remote Ubuntu server via `rsync` over SSH
4. **Verify** — Validates file integrity on the destination using checksums
5. **Retain** — Keeps only the N most recent backups per schema
6. **Monitor** — Tracks disk usage, heartbeat, and alerts via Mattermost

```
┌─────────────────────────┐         SSH/rsync           ┌──────────────────────────┐
│   Oracle Linux 7.9      │ ───────────────────────►    │   Ubuntu 24.04 LTS       │
│                         │                             │                          │
│  ┌─────────────────┐    │    Ed25519 key + rrsync     │  ┌────────────────────┐  │
│  │ oracle_backup.sh│    │                             │  │ retention_manager  │  │
│  │ (03:00 daily)   │    │                             │  │ (hourly)           │  │
│  └────────┬────────┘    │                             │  └────────────────────┘  │
│           │             │                             │                          │
│  ┌────────▼────────┐    │                             │  Users:                  │
│  │ sync_to_dest.sh │    │                             │  - backuprecv (rsync)    │
│  │ (04:00 daily)   │    │                             │  - backupmgr (retention) │
│  └─────────────────┘    │                             │                          │
│                         │                             │  /data/backups/oracle/   │
│  Users:                 │       Mattermost            │  ├── HR_2026-04-08.dmp.gz│
│  - oracle (expdp)       │ ◄──── Notifications ──────► │  ├── HR_2026-04-08...sha │
│  - backupsync (rsync)   │                             │  └── ...                 │
└─────────────────────────┘                             └──────────────────────────┘
```

## Architecture

### Security Principles

- **Least Privilege** — Each user has only the permissions needed for its specific task
- **Separation of Duties** — Sync user ≠ management user; no shared credentials
- **Defense in Depth** — SSH key restriction + `rrsync` + checksum verification + monitoring
- **No Passwords in Scripts** — Uses Oracle Wallet or dedicated DB user; SSH key-based auth

### User Model

| Server       | User           | Purpose                       | Access                                  |
| ------------ | -------------- | ----------------------------- | --------------------------------------- |
| Oracle Linux | `oracle`     | Runs `expdp`                | Database access, writes to backup dir   |
| Oracle Linux | `backupsync` | Runs `rsync` to destination | Read-only on backup dir, SSH key        |
| Ubuntu       | `backuprecv` | Receives `rsync` data       | Write-only to backup dir via `rrsync` |
| Ubuntu       | `backupmgr`  | Retention, monitoring, alerts | Read/write/delete on backup dir         |

### Schedule

| Time             | Action                               | Server       | Script                     |
| ---------------- | ------------------------------------ | ------------ | -------------------------- |
| 03:00            | Export schemas + compress + checksum | Oracle Linux | `oracle_backup.sh`       |
| 04:00            | rsync to Ubuntu + verify checksums   | Oracle Linux | `sync_to_destination.sh` |
| Every hour (:30) | Retention + disk check + heartbeat   | Ubuntu       | `retention_manager.sh`   |

## Project Structure

```
oracle-backup-shuttle/
├── README.md
├── LICENSE
├── .gitignore
├── scripts/
│   ├── source-server/                  # Deploy to Oracle Linux server
│   │   ├── oracle_backup.sh            # Schema export + compress + checksum
│   │   ├── sync_to_destination.sh      # rsync transfer + remote verification
│   │   └── setup_source.sh             # One-time setup (users, dirs, SSH key)
│   └── destination-server/             # Deploy to Ubuntu server
│       ├── retention_manager.sh        # Retention, disk monitoring, heartbeat
│       └── setup_destination.sh        # One-time setup (users, dirs, rrsync)
├── systemd/                            # Systemd service and timer units
│   ├── oracle-backup.service
│   ├── oracle-backup.timer
│   ├── backup-sync.service
│   ├── backup-sync.timer
│   ├── retention-manager.service
│   └── retention-manager.timer
└── docs/
    └── CIS_HARDENING.md               # CIS Benchmark hardening for Ubuntu 24.04
```

## Installation

### Prerequisites

| Component          | Requirement                                               |
| ------------------ | --------------------------------------------------------- |
| Source Server      | Oracle Linux 7.9, Oracle DB,`rsync`, `gzip`, `curl` |
| Destination Server | Ubuntu 24.04 LTS,`rsync`, `curl`                      |
| Network            | SSH access from source → destination                     |
| Mattermost         | Incoming webhook URL                                      |

### Step 1: Setup Destination Server (Ubuntu)

```bash
# Copy scripts to the server
scp -r scripts/destination-server/ root@ubuntu-server:/opt/backup/
scp systemd/retention-manager.* root@ubuntu-server:/etc/systemd/system/

# SSH into the destination server and run setup
ssh root@ubuntu-server
chmod +x /opt/backup/*.sh
/opt/backup/setup_destination.sh

# Enable the systemd timer
systemctl daemon-reload
systemctl enable --now retention-manager.timer
```

### Step 2: Setup Source Server (Oracle Linux)

```bash
# Copy scripts to the server
scp -r scripts/source-server/ root@oracle-server:/opt/backup/
scp systemd/oracle-backup.* systemd/backup-sync.* root@oracle-server:/etc/systemd/system/

# SSH into the source server and run setup
ssh root@oracle-server
chmod +x /opt/backup/*.sh
/opt/backup/setup_source.sh

# Create Oracle directory object (run as DBA)
sqlplus / as sysdba <<SQL
CREATE OR REPLACE DIRECTORY BACKUP_DIR AS '/opt/oracle_backups';
GRANT READ, WRITE ON DIRECTORY BACKUP_DIR TO SYSTEM;
SQL
```

### Step 3: Configure SSH Key on Destination

Copy the public key printed by `setup_source.sh` and add it to the destination:

```bash
# On the destination server
sudo vim /home/backuprecv/.ssh/authorized_keys

# Add this line (replace key with your actual public key):
command="/usr/local/bin/rrsync /data/backups/oracle/",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA... backup-sync-key
```

### Step 4: Configure Script Variables

Edit the `CONFIGURATION` section at the top of each script:

| Script                     | Key Variables                                                                                      |
| -------------------------- | -------------------------------------------------------------------------------------------------- |
| `oracle_backup.sh`       | `ORACLE_HOME`, `ORACLE_SID`, `DB_USER`, `DB_PASS`, `SCHEMAS`, `MATTERMOST_WEBHOOK_URL` |
| `sync_to_destination.sh` | `DEST_HOST`, `DEST_USER`, `DEST_SSH_KEY`, `MATTERMOST_WEBHOOK_URL`                         |
| `retention_manager.sh`   | `KNOWN_SCHEMAS`, `KEEP_COUNT`, disk thresholds, `MATTERMOST_WEBHOOK_URL`                     |

### Step 5: Enable Systemd Timers

```bash
# On SOURCE server (Oracle Linux):
systemctl daemon-reload
systemctl enable --now oracle-backup.timer
systemctl enable --now backup-sync.timer

# Verify timers:
systemctl list-timers --all | grep -E "oracle|backup"
```

### Step 6: Test Everything

```bash
# Test backup manually
sudo -u oracle /opt/backup/oracle_backup.sh

# Test sync manually
sudo -u backupsync /opt/backup/sync_to_destination.sh

# Test retention (on destination)
sudo -u backupmgr /opt/backup/retention_manager.sh
```

## Systemd vs Cron

This project uses **systemd timers** instead of cron for several advantages:

| Feature                      | systemd timer                   | cron          |
| ---------------------------- | ------------------------------- | ------------- |
| Missed runs (server was off) | `Persistent=true` catches up  | Lost forever  |
| Logging                      | `journalctl -u oracle-backup` | Manual config |
| Dependencies                 | `After=` ensures order        | No support    |
| Resource control             | CPU/IO priority via unit        | None          |
| Status monitoring            | `systemctl status`            | No built-in   |
| Random delay                 | `RandomizedDelaySec`          | Not available |

### Alternative: Using Cron

If you prefer cron, add these entries instead of installing systemd units:

```bash
# On SOURCE (oracle user crontab):
0 3 * * * /opt/backup/oracle_backup.sh >> /var/log/oracle_backup.log 2>&1

# On SOURCE (backupsync user crontab):
0 4 * * * /opt/backup/sync_to_destination.sh >> /var/log/oracle_sync.log 2>&1

# On DESTINATION (backupmgr user crontab):
30 * * * * /opt/backup/retention_manager.sh >> /var/log/backup_retention.log 2>&1
```

## Monitoring & Alerts

### Mattermost Notifications

| Icon | Event                                | Severity |
| ---- | ------------------------------------ | -------- |
| 🟢   | All schemas exported successfully    | Info     |
| ✅   | Individual schema export success     | Info     |
| 🟢   | Sync completed, checksums verified   | Info     |
| 💚   | Heartbeat OK — all backups received | Info     |
| ⚠️ | Disk usage above warning threshold   | Warning  |
| ⚠️ | No backup files found for today      | Warning  |
| 🟡   | Partial backup failure               | Warning  |
| 🔴   | Schema export failed                 | Critical |
| 🔴   | Sync/rsync failed                    | Critical |
| 🔴   | Checksum mismatch after transfer     | Critical |
| 🔴   | Disk usage above critical threshold  | Critical |
| 🔴   | Heartbeat failed — backups missing  | Critical |

### Log Files

| File                              | Server      | Content                              |
| --------------------------------- | ----------- | ------------------------------------ |
| `/var/log/oracle_backup.log`    | Source      | expdp output, compression, checksums |
| `/var/log/oracle_sync.log`      | Source      | rsync transfer, remote verification  |
| `/var/log/backup_retention.log` | Destination | Retention, disk checks, heartbeat    |

### Useful Commands

```bash
# List all backup-related timers
systemctl list-timers --all | grep -E "oracle|backup|retention"

# Check last run status
systemctl status oracle-backup.service
journalctl -u oracle-backup.service --since today

# Watch logs in real-time
tail -f /var/log/oracle_backup.log
tail -f /var/log/oracle_sync.log
```

## Troubleshooting

### expdp Fails with ORA-39002 / ORA-39070

The Oracle directory object doesn't exist or lacks permissions:

```sql
SELECT directory_name, directory_path FROM dba_directories;
CREATE OR REPLACE DIRECTORY BACKUP_DIR AS '/opt/oracle_backups';
GRANT READ, WRITE ON DIRECTORY BACKUP_DIR TO SYSTEM;
```

### rsync Connection Refused

1. Verify SSH: `ssh -i /home/backupsync/.ssh/id_ed25519 backuprecv@dest-ip echo ok`
2. Check firewall: `sudo ufw status`
3. Verify rrsync: `ls -la /usr/local/bin/rrsync`
4. Check `authorized_keys` format — the `command=` prefix must be exact

### Checksum Mismatch

Data corruption during transfer. Manually verify:

```bash
cd /data/backups/oracle
sha256sum -c HR_2026-04-08.dmp.gz.sha256
```

If it fails, delete the corrupted file and re-run sync.

### Disk Full

1. Check: `df -h /data/backups/oracle`
2. Run retention manually: `sudo -u backupmgr /opt/backup/retention_manager.sh`
3. Temporarily reduce `KEEP_COUNT` if needed

## CIS Hardening

See [`docs/CIS_HARDENING.md`](docs/CIS_HARDENING.md) for a comprehensive guide on hardening Ubuntu 24.04 based on CIS Benchmarks.

## License

MIT — see [LICENSE](LICENSE) for details.
