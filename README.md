# Flex Backup System

**BorgBackup + rclone** — encrypted, deduplicated backups with cloud sync to Cloudflare R2 or Google Drive.

```
Docker volumes / app data
        ↓ borg create (local dedup + AES-256 encryption + zstd compression)
  /var/backups/borg        ← local repository
        ↓ rclone sync (only changed segments uploaded)
  Cloudflare R2 / GDrive   ← offsite cold backup
```

## Why BorgBackup + rclone?

| Feature | This system |
|---------|-------------|
| **Deduplication** | Block-level, across all archives |
| **Encryption** | AES-256 (repokey-blake2), client-side |
| **Compression** | zstd level 6 (fast + great ratio) |
| **Permissions** | uid/gid/chmod preserved natively |
| **Cloud operations** | ~1-5 rclone ops/day (vs hundreds with Restic chunks) |
| **R2 free tier safe** | ~1,500 ops/month for 10 containers (limit: 1M) |
| **Retention** | Configurable daily/weekly/monthly |
| **Monitoring** | Gotify push notifications + monthly restore test |

## Project Structure

```
├── borg-backup.sh                  # Main backup script (borg + prune + rclone sync)
├── borg-test-restore.sh            # Monthly restore verification
├── borg-setup.sh                   # One-time setup (Cloudflare R2)
├── borg-setup-gdrive.sh            # One-time setup (Google Drive)
├── borg-uninstall.sh               # Complete removal of backup system
├── backup-secrets.env.template     # Config template (R2)
├── backup-secrets-gdrive.env.template  # Config template (Google Drive)
├── systemd/
│   ├── borg-backup.service         # Backup service unit
│   ├── borg-backup.timer           # Daily timer (03:00)
│   ├── borg-test-restore.service   # Restore test service unit
│   └── borg-test-restore.timer     # Monthly timer (1st at 04:00)
├── disaster-recovery.md            # Step-by-step recovery guide (English)
├── disaster-recovery-pl.md         # Step-by-step recovery guide (Polish)
├── SECURITY.md                     # Security model documentation
└── README.md                       # This file
```

## Prerequisites

- **OS**: Ubuntu/Debian 20.04+ (or any system with apt)
- **Access**: Root (sudo)
- **Storage backend** (one of):
  - Cloudflare R2 account + API token
  - Google account (for Google Drive)
- **Optional**: [Gotify](https://gotify.net/) server for push notifications

## Quick Start — Cloudflare R2

### 1. Clone the repository

```bash
git clone https://github.com/pavlojs/flex-backup-system.git
cd flex-backup-system
```

### 2. Run the setup script

```bash
sudo bash borg-setup.sh
```

The setup will:
1. Install `borgbackup` and `rclone`
2. Copy the config template to `/root/.backup-secrets.env`
3. Prompt you to fill in your R2 credentials
4. Configure rclone remote `r2` (S3-compatible with R2 endpoint)
5. Initialize an encrypted borg repository
6. **Display your borg key — save it in your password manager!**
7. Install scripts to `/root/`
8. Enable systemd timers (daily backup + monthly restore test)
9. Configure log rotation
10. Optionally run the first backup

### 3. Configure backup targets

Edit `/root/.backup-secrets.env`:

```bash
# Paths to back up (space-separated)
BACKUP_PATHS="/var/lib/docker/volumes /home/user/apps"

# Retention policy
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
```

### 4. Verify

```bash
# Check timer status
systemctl list-timers borg-*

# Run manually
sudo /root/borg-backup.sh

# List archives
sudo BORG_REPO=/var/backups/borg BORG_PASSPHRASE=<your-pass> borg list
```

## Quick Start — Google Drive

```bash
sudo bash borg-setup-gdrive.sh
```

Same flow as R2, except:
- You'll run `rclone config` interactively to set up OAuth for Google Drive
- Create a remote named `gdrive`
- No R2 credentials needed — only `BORG_PASSPHRASE` and `BACKUP_PATHS`

## Configuration Reference

All settings are in `/root/.backup-secrets.env` (created during setup).

### Backup Targets

```bash
# Space-separated absolute paths
BACKUP_PATHS="/var/lib/docker/volumes /home/user/apps /opt/myservice/data"
```

### Exclusions

Patterns are applied to all backup paths. One pattern per line:

```bash
BACKUP_EXCLUDES="
*.log
*.log.*
mysql-bin.*
ib_logfile*
*.cache
*/.cache
__pycache__
*.pyc
.npm
node_modules/.cache
*.tmp
*.swp
.Trash*
lost+found
*.sock
*.pid
"
```

Default exclusions prevent silent backup growth from:
- **Logs**: `*.log`, `*.log.*`, `*.log.gz`
- **Database binary logs**: `mysql-bin.*`, `ib_logfile*`, `slow-query.log*`, `binlog.*`, `relay-log.*`
- **Caches**: `*.cache`, `*/.cache`, `__pycache__`, `.npm`, `_cacache`
- **Temporary files**: `*.tmp`, `*.swp`, `*.bak`, `.Trash*`
- **Runtime files**: `*.sock`, `*.pid`, `core`, `core.[0-9]*`

### Retention Policy

```bash
KEEP_DAILY=7      # Keep last 7 daily archives
KEEP_WEEKLY=4     # Keep last 4 weekly archives
KEEP_MONTHLY=6    # Keep last 6 monthly archives
```

Older archives are pruned automatically after each backup.

### Gotify Notifications

```bash
GOTIFY_URL="https://gotify.example.com"
GOTIFY_TOKEN="your-app-token"
GOTIFY_PRIORITY_SUCCESS=3   # 1-10
GOTIFY_PRIORITY_ERROR=8
GOTIFY_PRIORITY_TEST=5
```

Leave `GOTIFY_URL` empty to disable notifications.

Notifications are sent for:
- ✅ **Backup success** — archive name, duration, repo size, retention stats
- ❌ **Backup failure** — phase that failed, error message
- ✅/⚠️ **Monthly restore test** — checks passed/failed, details

## What Gets Backed Up (and What Doesn't)

| Backed up ✅ | NOT backed up ❌ |
|---|---|
| Docker volume data | Log files (`*.log`) |
| App configuration | Database binary logs (`mysql-bin.*`) |
| User data | Cache directories |
| Database dumps (if in volumes) | Temporary files |
| Permissions (uid/gid/chmod) | Sockets, PID files |

## How It Works

### Daily Backup Flow (03:00)

1. **Lock** — `flock` prevents parallel runs
2. **borg create** — deduplicated, compressed, encrypted archive
3. **borg prune** — remove archives outside retention policy
4. **borg compact** — free disk space from pruned data
5. **rclone sync** — upload only changed repository segments to cloud
6. **Stamp** — write success timestamp to `/var/log/borg-backup-last-success`
7. **Notify** — Gotify push with stats (or error details on failure)

### Monthly Restore Test (1st of month, 04:00)

1. **borg check** — verify repository integrity
2. **Dry-run extract** — verify all data chunks are readable
3. **Real extract** — restore a subset of files to `/tmp/`
4. **Verify** — check file existence, non-zero sizes, permissions
5. **Cleanup** — remove test files
6. **Notify** — Gotify push with test results

### Cloud Sync Efficiency

BorgBackup stores data in large segments (~500MB). When `rclone sync` runs, only modified segments are uploaded. For a typical daily backup of 10 Docker containers:

- **Changed data**: ~50-200 MB
- **rclone operations**: ~1-5 PUT requests
- **Monthly total**: ~150 operations (R2 free tier allows 1,000,000)

## Manual Commands

```bash
# Source environment for interactive use
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE

# List all archives
borg list

# Show archive details
borg info ::ARCHIVE_NAME

# List files in an archive
borg list ::ARCHIVE_NAME | head -50

# Restore specific files
borg extract ::ARCHIVE_NAME path/to/file --target /tmp/restored

# Restore entire archive
borg extract ::ARCHIVE_NAME --target /tmp/full-restore

# Check repository integrity
borg check

# Show repository size
du -sh "$BORG_REPO"

# Check cloud backup
rclone ls "$RCLONE_DEST" | head -20
rclone size "$RCLONE_DEST"

# Run backup manually
/root/borg-backup.sh

# Run restore test manually
/root/borg-test-restore.sh

# Check when last backup succeeded
cat /var/log/borg-backup-last-success

# Check when last restore test ran
cat /var/log/borg-test-restore-last

# View backup log
tail -100 /var/log/borg-backup.log
```

## Monitoring

### Is the backup running?

```bash
# Check timer status
systemctl list-timers borg-*

# Check last run
systemctl status borg-backup.service

# Last success timestamp
cat /var/log/borg-backup-last-success
```

### Something went wrong?

```bash
# Check service logs
journalctl -u borg-backup.service --since "24 hours ago"

# Check backup log
tail -200 /var/log/borg-backup.log

# Verify borg repo
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
borg check
```

## Uninstall / Return to Clean System

To completely remove the backup system and all its data:

```bash
sudo /root/borg-uninstall.sh
```

This interactively removes:
1. Systemd timers and services
2. Local borg repository (with confirmation)
3. Cloud backup data (with confirmation)
4. rclone remote configuration
5. Config file, scripts, logs
6. Optionally: borgbackup and rclone packages

See also: [disaster-recovery.md](disaster-recovery.md) for full recovery procedures.

## Troubleshooting

### "Another backup is already running"

The backup uses `flock` to prevent parallel runs. If a previous run crashed:

```bash
rm -f /var/lock/borg-backup.lock
```

### "Repository does not exist" or "Failed to open repository"

```bash
# Verify repo path
ls -la /var/backups/borg/

# Re-check environment
source /root/.backup-secrets.env
echo "$BORG_REPO"  # Should print the correct path
```

### rclone sync fails

```bash
# Test rclone connectivity
rclone lsd r2:  # List buckets (R2)
rclone lsd gdrive:  # List folders (Google Drive)

# Verbose sync
rclone sync /var/backups/borg r2:borg-backup -v
```

### Backup is too large / growing unexpectedly

Check what's being backed up:

```bash
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
borg list ::LATEST_ARCHIVE --sort-by size --last 50
```

Add patterns to `BACKUP_EXCLUDES` in your env file to exclude large/unnecessary files.

### Gotify notifications not working

```bash
# Test manually
curl "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" \
  -F "title=Test" -F "message=Hello" -F "priority=5"
```

## License

MIT
