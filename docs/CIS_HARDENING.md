# CIS Benchmark Hardening — Ubuntu 24.04 LTS

This guide covers essential security hardening for the Ubuntu 24.04 destination
server, based on CIS Benchmark Level 1 recommendations.

> **Official Tool**: Canonical provides the Ubuntu Security Guide (USG) for automated CIS compliance.
> If you have Ubuntu Pro: `sudo pro enable usg && sudo usg audit level1_server`

## Quick Start with USG (Recommended)

```bash
# Enable Ubuntu Pro (free for up to 5 machines)
sudo pro attach <your-token>

# Enable Ubuntu Security Guide
sudo pro enable usg

# Audit current compliance
sudo usg audit level1_server

# Auto-fix what can be safely fixed
sudo usg fix level1_server
```

## Manual Hardening Checklist

### SSH Hardening

Edit `/etc/ssh/sshd_config`:

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
AllowUsers backuprecv backupmgr youradminuser
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
```

```bash
sudo systemctl restart sshd
```

### Firewall (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <oracle-server-ip> to any port 22 proto tcp
sudo ufw enable
sudo ufw status verbose
```

### Automatic Security Updates

```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### Filesystem Hardening

Edit `/etc/fstab` — add `noexec,nosuid,nodev` to `/tmp` and backup partition:

```
tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0
```

### Audit Logging

```bash
sudo apt install auditd audispd-plugins
sudo systemctl enable --now auditd
sudo auditctl -w /data/backups/oracle/ -p rwa -k backup_access
sudo auditctl -w /opt/backup/ -p wa -k backup_scripts
```

### Kernel Hardening (sysctl)

Add to `/etc/sysctl.d/99-hardening.conf`:

```
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.disable_ipv6 = 1
kernel.randomize_va_space = 2
kernel.sysrq = 0
```

```bash
sudo sysctl --system
```

### Disable Unnecessary Services

```bash
systemctl list-units --type=service --state=running
sudo systemctl disable --now cups
sudo systemctl disable --now avahi-daemon
sudo systemctl disable --now bluetooth
```

### Password Policy

```bash
sudo apt install libpam-pwquality
# Edit /etc/security/pwquality.conf:
# minlen = 14, dcredit = -1, ucredit = -1, ocredit = -1, lcredit = -1
```

### File Permissions

```bash
sudo chmod 600 /etc/crontab
sudo chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly
sudo chmod 600 /etc/ssh/sshd_config
sudo find / -xdev -type f -perm -0002 -exec chmod o-w {} \;
```

## References

- [CIS Benchmarks for Ubuntu Linux](https://www.cisecurity.org/benchmark/ubuntu_linux)
- [Ubuntu Security Guide (USG)](https://ubuntu.com/security/certifications/docs/usg)
- [Ubuntu 24.04 CIS Hardening Script (Community)](https://github.com/AndyHS-506/Ubuntu-Hardening)
