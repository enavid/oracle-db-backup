
# Oracle Backup Shuttle

> Automated Oracle database schema backup, secure transfer, and retention management with Mattermost notifications.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://claude.ai/chat/LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://claude.ai/chat/6a680616-3598-4e33-93cf-113a13de21e2)

## Overview

Oracle Backup Shuttle automates the complete lifecycle of Oracle database backups across two servers. The source server (Oracle Linux 7.9) exports schemas using Data Pump, compresses them, generates SHA-256 checksums, and transfers the files securely to the destination server (Ubuntu 24.04 LTS) via rsync over SSH. The destination server manages retention, monitors disk usage, and sends heartbeat notifications through Mattermost.

The pipeline runs in four stages:

1. **Export** — Oracle schemas are dumped using `expdp` with compression enabled.
2. **Transfer** — Files are synced to the Ubuntu server via `rsync` over an Ed25519 SSH key restricted to `rrsync`.
3. **Verify** — SHA-256 checksums are validated on the destination after each transfer.
4. **Retain** — Only the N most recent backups per schema are kept; older files are deleted automatically.

```
┌─────────────────────────┐         SSH/rsync           ┌──────────────────────────┐
│   Oracle Linux 7.9      │ ───────────────────────►    │   Ubuntu 24.04 LTS       │
│                         │                             │                          │
│  ┌─────────────────┐    │    Ed25519 key + rrsync     │  ┌────────────────────┐  │
│  │ oracle_backup.sh│    │                             │  │ retention_manager  │  │
│  │ (03:00 daily)   │    │                             │  │ (06:00 daily)      │  │
│  └────────┬────────┘    │                             │  └────────────────────┘  │
│           │             │                             │                          │
│  ┌────────▼────────┐    │                             │  Users:                  │
│  │ sync_to_dest.sh │    │                             │  - backuprecv (rsync)    │
│  │ (04:00 daily)   │    │                             │  - backupmgr (retention) │
│  └─────────────────┘    │                             │                          │
│                         │                             │  /data/backups/oracle/   │
│  Users:                 │       Mattermost            │                          │
│  - oracle (expdp)       │ ◄──── Notifications ──────► │                          │
│  - backupsync (rsync)   │                             │                          │
└─────────────────────────┘                             └──────────────────────────┘
```

## Architecture

### Security Principles

The system is designed around least privilege: each operating system user has access only to the resources required for its specific task. The sync user cannot manage retention; the retention user cannot initiate transfers. All authentication is key-based — no passwords appear in scripts or configuration files. SSH keys on the destination are locked to a single `rrsync` command, preventing any other remote operations. Checksum verification after every transfer ensures that data corruption is detected before a backup is considered successful.

### User Model

| Server       | User           | Purpose                       | Access                                  |
| ------------ | -------------- | ----------------------------- | --------------------------------------- |
| Oracle Linux | `oracle`     | Runs `expdp`                | Database access, writes to backup dir   |
| Oracle Linux | `backupsync` | Runs `rsync`to destination  | Read-only on backup dir, SSH key        |
| Ubuntu       | `backuprecv` | Receives `rsync`data        | Write-only to backup dir via `rrsync` |
| Ubuntu       | `backupmgr`  | Retention, monitoring, alerts | Read/write/delete on backup dir         |

### Schedule

| Time  | Action                               | Server       | Script                     |
| ----- | ------------------------------------ | ------------ | -------------------------- |
| 03:00 | Export schemas + compress + checksum | Oracle Linux | `oracle_backup.sh`       |
| 04:00 | rsync to Ubuntu + verify checksums   | Oracle Linux | `sync_to_destination.sh` |
| 06:00 | Retention + disk check + heartbeat   | Ubuntu       | `retention_manager.sh`   |

## Project Structure

```
oracle-backup-shuttle/
├── README.md
├── LICENSE
├── scripts/
│   ├── source-server/
│   │   ├── oracle_backup.sh
│   │   ├── sync_to_destination.sh
│   │   └── setup_source.sh
│   └── destination-server/
│       ├── retention_manager.sh
│       └── setup_destination.sh
├── systemd/
│   ├── oracle-backup.service
│   ├── oracle-backup.timer
│   ├── backup-sync.service
│   ├── backup-sync.timer
│   ├── retention-manager.service
│   └── retention-manager.timer
└── docs/
    └── CIS_HARDENING.md
```

## Installation

### Prerequisites

| Component          | Requirement                                             |
| ------------------ | ------------------------------------------------------- |
| Source Server      | Oracle Linux 7.9, Oracle DB,`rsync`,`gzip`,`curl` |
| Destination Server | Ubuntu 24.04 LTS,`rsync`,`curl`                     |
| Network            | SSH access from source to destination                   |
| Mattermost         | Incoming webhook URL                                    |

### Step 1 — Setup Destination Server (Ubuntu)

```bash
scp -r scripts/destination-server/ root@ubuntu-server:/opt/backup/
scp systemd/retention-manager.* root@ubuntu-server:/etc/systemd/system/

ssh root@ubuntu-server
chmod +x /opt/backup/*.sh
/opt/backup/setup_destination.sh

# Create log file with correct ownership
touch /var/log/backup_retention.log
chown backupmgr:backupgrp /var/log/backup_retention.log
chmod 640 /var/log/backup_retention.log

systemctl daemon-reload
systemctl enable --now retention-manager.timer
```

### Step 2 — Setup Source Server (Oracle Linux)

```bash
scp -r scripts/source-server/ root@oracle-server:/opt/backup/
scp systemd/oracle-backup.* systemd/backup-sync.* root@oracle-server:/etc/systemd/system/

ssh root@oracle-server
chmod +x /opt/backup/*.sh
/opt/backup/setup_source.sh
```

Create the Oracle directory object as DBA:

```sql
CREATE OR REPLACE DIRECTORY BACKUP_DIR AS '/opt/oracle_backups';
GRANT READ, WRITE ON DIRECTORY BACKUP_DIR TO SYSTEM;
```

> **Note:** Oracle Linux 7.9 ships with systemd 219 which does not support the `append:` output specifier. The service units use `StandardOutput=syslog` instead. Logs are readable via `journalctl -u oracle-backup.service`.

### Step 3 — Configure SSH Key on Destination

Copy the public key printed by `setup_source.sh` and add it to `/home/backuprecv/.ssh/authorized_keys`:

```
command="/usr/local/bin/rrsync /data/backups/oracle/",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA... backup-sync-key
```

### Step 4 — Configure Script Variables

Edit the `CONFIGURATION` section at the top of each script:

| Script                     | Key Variables                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| `oracle_backup.sh`       | `ORACLE_HOME`,`ORACLE_SID`,`DB_USER`,`DB_PASS`,`SCHEMAS`,`MATTERMOST_WEBHOOK_URL` |
| `sync_to_destination.sh` | `DEST_HOST`,`DEST_USER`,`DEST_SSH_KEY`,`MATTERMOST_WEBHOOK_URL`                       |
| `retention_manager.sh`   | `KNOWN_SCHEMAS`,`KEEP_COUNT`, disk thresholds,`MATTERMOST_WEBHOOK_URL`                  |

### Step 5 — Enable Systemd Timers

```bash
# Oracle Linux (source server)
systemctl daemon-reload
systemctl enable --now oracle-backup.timer
systemctl enable --now backup-sync.timer

# Ubuntu (destination server)
systemctl daemon-reload
systemctl enable --now retention-manager.timer

# Verify
systemctl list-timers --all | grep -E "oracle|backup|retention"
```

### Step 6 — Test Everything

```bash
# Test backup manually (source)
sudo -u oracle /opt/backup/oracle_backup.sh

# Test sync manually (source)
sudo -u backupsync /opt/backup/sync_to_destination.sh

# Test retention manually (destination)
sudo -u backupmgr /opt/backup/retention_manager.sh
```

## Monitoring and Alerts

### Mattermost Notifications

| Event                                | Severity |
| ------------------------------------ | -------- |
| All schemas exported successfully    | Info     |
| Sync completed, checksums verified   | Info     |
| Heartbeat OK — all backups received | Info     |
| Disk usage above warning threshold   | Warning  |
| No backup files found for today      | Warning  |
| Partial backup failure               | Warning  |
| Schema export failed                 | Critical |
| Sync / rsync failed                  | Critical |
| Checksum mismatch after transfer     | Critical |
| Disk usage above critical threshold  | Critical |
| Heartbeat failed — backups missing  | Critical |

### Log Files

| File                              | Server      | Content                              |
| --------------------------------- | ----------- | ------------------------------------ |
| `/var/log/oracle_backup.log`    | Source      | expdp output, compression, checksums |
| `/var/log/oracle_sync.log`      | Source      | rsync transfer, remote verification  |
| `/var/log/backup_retention.log` | Destination | Retention, disk checks, heartbeat    |

### Useful Commands

```bash
# List all timers
systemctl list-timers --all | grep -E "oracle|backup|retention"

# Check last run status
systemctl status oracle-backup.service
journalctl -u oracle-backup.service --since today

# Watch logs in real time
tail -f /var/log/oracle_backup.log
tail -f /var/log/oracle_sync.log
```

## Troubleshooting

This section documents issues encountered during deployment and their resolutions.

---

### Service fails with exit code 203/EXEC

Exit code 203/EXEC means systemd found the unit file but could not execute the script specified in `ExecStart`. This is almost always a path or permission problem.

First confirm the script exists and has the executable bit set:

```bash
ls -la /opt/backup/oracle_backup.sh
chmod +x /opt/backup/oracle_backup.sh
```

If the script lives inside another user's home directory, the service user will be denied access entirely:

```bash
sudo -u oracle ls /home/someuser/script/
# Permission denied
```

Move all scripts to a shared system path and update the unit file:

```bash
cp /home/someuser/script/oracle_backup.sh /opt/backup/oracle_backup.sh
chown oracle:backupgrp /opt/backup/oracle_backup.sh
chmod +x /opt/backup/oracle_backup.sh
```

Then update `ExecStart` in the unit file, reload, and restart.

---

### Service blocked by missing oracle-database.service dependency

If `oracle-backup.service` contains `After=oracle-database.service` and `Wants=oracle-database.service`, it will fail on systems where Oracle is not managed by a systemd unit — which is typical for Oracle Linux 7.9. Remove these lines entirely:

```ini
[Unit]
Description=Oracle Schema Backup
After=network.target
```

---

### StandardOutput=append: not supported on Oracle Linux 7.9

The `append:` specifier was introduced in systemd 240. Oracle Linux 7.9 ships with systemd 219 and silently ignores it, so no log file is ever written. The journal will show:

```
Failed to parse output specifier, ignoring: append:/var/log/oracle_backup.log
```

Replace with `syslog` and add a `SyslogIdentifier`:

```ini
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=oracle-backup
```

Logs are then readable via `journalctl -u oracle-backup.service --since today`.

Ubuntu 24.04 ships with systemd 245 and supports `append:` natively, so this change is only required on the Oracle Linux source server.

---

### Timer fires but service never runs

Always specify `Unit=` explicitly in the timer to avoid relying on naming convention, and add `Requires=` in the `[Unit]` section:

```ini
[Unit]
Description=Run Oracle Backup daily at 03:00
Requires=oracle-backup.service

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=oracle-backup.service
```

After editing any unit file:

```bash
systemctl daemon-reload
systemctl enable --now oracle-backup.timer
```

---

### Log file permission denied for backupmgr

The retention service runs as `backupmgr` and cannot write to `/var/log/backup_retention.log` if the file was created as root or does not exist. Create it with the correct ownership before starting the service:

```bash
touch /var/log/backup_retention.log
chown backupmgr:backupgrp /var/log/backup_retention.log
chmod 640 /var/log/backup_retention.log
```

---

### Verifying timers are scheduled correctly

After enabling timers, confirm that `NEXT` and `LAST` columns are populated correctly. A timer that has never fired will show `n/a` in `LAST`, which is normal on first install.

```bash
systemctl list-timers --all | grep -E "oracle|backup|retention"
```

Expected output after a successful run:

```
NEXT                           LEFT    LAST                           PASSED
Sat 2026-04-11 03:01:29 +0330  11h     Fri 2026-04-10 03:00:34 +0330  12h ago  oracle-backup.timer
Sat 2026-04-11 04:00:48 +0330  12h     Fri 2026-04-10 04:00:40 +0330  11h ago  backup-sync.timer
Sat 2026-04-11 06:00:00 +0330  13h     Fri 2026-04-10 06:00:00 +0330  9h ago   retention-manager.timer
```

To test a service immediately without waiting for the scheduled time:

```bash
systemctl start oracle-backup.service
journalctl -u oracle-backup.service -f
```

---

### expdp fails with ORA-39002 or ORA-39070

The Oracle directory object does not exist or the database user lacks the required privileges:

```sql
SELECT directory_name, directory_path FROM dba_directories;
CREATE OR REPLACE DIRECTORY BACKUP_DIR AS '/opt/oracle_backups';
GRANT READ, WRITE ON DIRECTORY BACKUP_DIR TO SYSTEM;
```

---

### rsync connection refused or SSH authentication failure

Work through these checks in order.

Test the SSH connection directly:

```bash
ssh -i /home/backupsync/.ssh/id_ed25519 backuprecv@dest-ip echo ok
```

If the connection is refused, check the firewall and sshd status on the destination:

```bash
sudo ufw status
systemctl status sshd
```

If authentication fails, verify that `rrsync` is installed and that the `authorized_keys` entry is formatted correctly — the `command=` prefix must be present and exact:

```
command="/usr/local/bin/rrsync /data/backups/oracle/",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA... backup-sync-key
```

---

### Checksum mismatch after transfer

A mismatch indicates data corruption during transfer. Delete the affected file on the destination and re-run the sync:

```bash
cd /data/backups/oracle
sha256sum -c SCHEMA_2026-04-10.dmp.gz.sha256

# If the check fails:
rm SCHEMA_2026-04-10.dmp.gz
sudo -u backupsync /opt/backup/sync_to_destination.sh
```

---

### Disk full on destination

```bash
df -h /data/backups/oracle
sudo -u backupmgr /opt/backup/retention_manager.sh
```

If disk usage remains critical after running retention, temporarily reduce `KEEP_COUNT` in `retention_manager.sh` and run again. Restore the original value once space is recovered.

---

## CIS Hardening

See [`docs/CIS_HARDENING.md`](https://claude.ai/chat/docs/CIS_HARDENING.md) for a comprehensive guide on hardening Ubuntu 24.04 based on CIS Benchmarks.

## License

MIT — see [LICENSE](https://claude.ai/chat/LICENSE) for details.
