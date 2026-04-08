# Restic Backup Project

> ⚠️ **NOTICE: This project is currently in active development and testing.**
> Scripts may contain bugs, incomplete features, or behave unexpectedly.
> **Do not rely on this as your sole backup solution** until you have personally verified
> that backups and restores work correctly in your environment.
> Always test with non-critical data first and maintain an alternative backup strategy.

**Automated, encrypted, deduplicated backups** for Linux servers using [restic](https://restic.net/) with two supported backends:

| Backend | Storage | Cost | Best for |
|---------|---------|------|----------|
| **Cloudflare R2** | S3-compatible object storage | Free 10 GB/mo, then ~$0.015/GB | Production servers, fast restore |
| **Google Drive** *(optional)* | Google Drive via rclone | Free 15 GB (personal), more with Workspace | Budget/personal projects |

## Features

- 🔐 **AES-256 encrypted** — data is encrypted before leaving your server
- 📦 **Deduplicated** — only changed blocks are uploaded (saves bandwidth & storage)
- 🗜️ **Compressed** — maximum compression enabled
- ⏰ **Automated** — daily cron job **or** systemd timer at 3:00 AM
- 🔔 **Notifications** — Gotify push notifications on success/failure
- 🩺 **Self-checking** — verifies 5% of backup data integrity after each run
- 🧹 **Auto-pruning** — keeps 5 daily + 1 weekly + 1 monthly snapshots

## Project Structure

```
├── README.md                              # This file (English)
├── SECURITY.md                            # Security policy and threat model
├── disaster-recovery.md                   # Recovery guide (English)
├── disaster-recovery-pl.md                # Przewodnik odtwarzania (Polish)
│
├── ── Cloudflare R2 backend ──
├── backup-secrets.env.template            # Secrets template (R2)
├── restic-setup.sh                        # One-time setup script (R2)
├── restic-backup.sh                       # Daily backup script (R2)
│
├── ── Google Drive backend (optional) ──
├── backup-secrets-gdrive.env.template     # Secrets template (Google Drive)
├── restic-setup-gdrive.sh                 # One-time setup script (Google Drive)
├── restic-backup-gdrive.sh                # Daily backup script (Google Drive)
│
└── systemd/                               # Systemd units (optional)
    ├── restic-backup.service              # Service unit (R2)
    ├── restic-backup.timer                # Timer unit (R2)
    ├── restic-backup-gdrive.service       # Service unit (Google Drive)
    └── restic-backup-gdrive.timer         # Timer unit (Google Drive)
```

---

## Prerequisites

- **Ubuntu/Debian** server (20.04+ recommended)
- **Root access** (or `sudo`)
- **curl** and **git** installed
- **One** of the following backends configured:
  - Cloudflare account with R2 enabled, **OR**
  - Google account (for Google Drive)

---

## Setup from Scratch — Cloudflare R2

### Step 1: Create a Cloudflare R2 Bucket

1. Go to [dash.cloudflare.com](https://dash.cloudflare.com)
2. In the left sidebar, click **R2 Object Storage**
3. Click **Create bucket**
4. Name it `restic-backup` (or your preferred name)
5. Choose a location (Auto is fine)
6. Click **Create bucket**

### Step 2: Create R2 API Token

1. In the R2 section, click **Manage R2 API Tokens**
2. Click **Create API token**
3. Name: `restic-backup`
4. Permissions: **Object Read & Write**
5. Scope: Apply to the specific bucket you just created
6. Click **Create API Token**
7. **Copy the Access Key ID and Secret Access Key immediately** — they won't be shown again

### Step 3: Note your Account ID

Your Cloudflare Account ID is visible in the R2 dashboard URL or in the right sidebar of any R2 page. It looks like: `a1b2c3d4e5f6g7h8i9j0...`

### Step 4: Clone and Run Setup

```bash
# On your server
cd /root
git clone https://github.com/YOUR-USERNAME/ResticR2BackupProject.git
cd ResticR2BackupProject

# Run setup
chmod +x restic-setup.sh
./restic-setup.sh
```

The setup script will:
1. Install `restic` and `awscli`
2. Copy the secrets template to `/root/.backup-secrets.env`
3. **Pause** — you fill in your R2 credentials and a strong password
4. Initialize the restic repository on R2
5. Set up a daily cron job at 3:00 AM

### Step 5: Fill in Your Secrets

When prompted, edit `/root/.backup-secrets.env`:

```bash
# --- Cloudflare R2 ---
export AWS_ACCESS_KEY_ID="your-r2-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-r2-secret-access-key"
export R2_ACCOUNT_ID="your-cloudflare-account-id"
export R2_BUCKET="restic-backup"

# --- Restic ---
export RESTIC_PASSWORD="a-very-strong-password-at-least-20-characters"

# --- Gotify (optional) ---
export GOTIFY_URL="https://gotify.yourdomain.com"
export GOTIFY_TOKEN="your-gotify-app-token"
```

> ⚠️ **CRITICAL**: Save `RESTIC_PASSWORD` in a password manager. If you lose it, **your backups are unrecoverable**.

### Step 6: Run a Test Backup

```bash
/root/restic-backup.sh
```

Check the log:
```bash
cat /var/log/restic-backup.log
```

Check snapshots:
```bash
source /root/.backup-secrets.env
restic snapshots
```

---

## Setup from Scratch — Google Drive (Optional)

### Step 1: Install rclone + restic

```bash
cd /root
git clone https://github.com/YOUR-USERNAME/ResticR2BackupProject.git
cd ResticR2BackupProject

chmod +x restic-setup-gdrive.sh
./restic-setup-gdrive.sh
```

### Step 2: Configure rclone (Google Drive Remote)

The setup script will launch `rclone config`. Follow these steps:

```
n) New remote
name> gdrive
Storage> drive            (or type the number for "Google Drive")
client_id>                (press Enter for default)
client_secret>            (press Enter for default)
scope> 1                  (Full access)
root_folder_id>           (press Enter for default)
service_account_file>     (press Enter for default)
Edit advanced config> n
Auto config> y            (if you have a browser, otherwise see below)
```

#### Headless Server (No Browser)

If your server has no browser (typical for VPS):

1. Choose `n` for "Auto config"
2. Rclone will show a URL — **open it on your local machine**
3. Log in to your Google account and authorize rclone
4. Copy the verification code back to the server terminal

Alternatively, run `rclone authorize "drive"` on a local machine with a browser, then paste the token on the server.

### Step 3: Fill in Secrets

When prompted, edit `/root/.backup-secrets-gdrive.env`:

```bash
export RCLONE_REMOTE="gdrive"                    # must match rclone config name
export RCLONE_GDRIVE_FOLDER="restic-backup"      # folder in Google Drive
export RESTIC_PASSWORD="a-very-strong-password-at-least-20-characters"

# Gotify (optional)
export GOTIFY_URL="https://gotify.yourdomain.com"
export GOTIFY_TOKEN="your-gotify-app-token"
```

### Step 4: Run a Test Backup

```bash
/root/restic-backup-gdrive.sh
```

Check:
```bash
cat /var/log/restic-backup-gdrive.log
source /root/.backup-secrets-gdrive.env
restic snapshots
```

---

## What Gets Backed Up

By default, these paths are backed up (edit `restic-backup.sh` or `restic-backup-gdrive.sh` to change):

| Path | What it contains |
|------|-----------------|
| `/var/lib/docker/volumes` | All Docker container persistent data |
| `/home/pavlojs/apps` | Application configs, docker-compose files |

### Customizing Backup Paths

Edit the `BACKUP_PATHS` array in the backup script:

```bash
BACKUP_PATHS=(
  "/var/lib/docker/volumes"
  "/home/pavlojs/apps"
  "/etc/nginx"              # add more paths as needed
  "/home/user/important"
)
```

---

## Retention Policy

| Type | Kept | Meaning |
|------|------|---------|
| Daily | 5 | Last 5 days of backups |
| Weekly | 1 | One backup from last week |
| Monthly | 1 | One backup from last month |

Older snapshots are automatically pruned after each backup run.

---

## Gotify Notifications (Optional)

[Gotify](https://gotify.net/) sends push notifications to your phone/browser.

### Quick Gotify Setup

1. Self-host Gotify or use an existing instance
2. Create an **Application** in Gotify's web UI
3. Copy the application token
4. Paste it into your secrets file (`GOTIFY_TOKEN`)

If you don't want notifications, leave `GOTIFY_URL` and `GOTIFY_TOKEN` empty — the Google Drive scripts handle this gracefully. For the R2 scripts, comment out the `gotify_notify` calls.

---

## Restoring Data

See **[disaster-recovery.md](disaster-recovery.md)** (English) or **[disaster-recovery-pl.md](disaster-recovery-pl.md)** (Polski) for a complete, step-by-step restore guide.

### Quick Restore Commands

```bash
# Load secrets
source /root/.backup-secrets.env       # R2
# OR
source /root/.backup-secrets-gdrive.env  # Google Drive

# List available snapshots
restic snapshots

# Restore everything from latest snapshot
restic restore latest --target /

# Restore a specific folder
restic restore latest --target / --include /home/pavlojs/apps

# Restore to a temporary location (safe)
restic restore latest --target /tmp/restore --include /var/lib/docker/volumes

# Restore from a specific snapshot (by ID)
restic restore a1b2c3d4 --target /tmp/restore

# Browse backup contents interactively
restic mount /mnt/restic
# Then: ls /mnt/restic/snapshots/latest/
```

---

## Useful Commands Reference

```bash
# ── Status & Info ──
restic snapshots                      # List all snapshots
restic stats                          # Show repository size
restic stats latest                   # Show latest snapshot size
restic ls latest                      # List all files in latest snapshot

# ── Maintenance ──
restic check                          # Verify repository integrity
restic check --read-data              # Full data verification (slow)
restic prune                          # Remove unreferenced data
restic rebuild-index                  # Fix index issues

# ── Backup ──
restic backup /path/to/folder         # Manual one-off backup
restic backup --dry-run /path         # Preview what would be backed up

# ── Troubleshooting ──
tail -50 /var/log/restic-backup.log   # View recent backup log
crontab -l                            # Verify cron is set up
systemctl status cron                 # Check cron service

# ── Systemd timer (if using) ──
systemctl list-timers restic-backup*  # When is next run?
systemctl status restic-backup.service # Last run status
journalctl -u restic-backup.service   # Full service log
```

---

## Scheduling: Cron vs Systemd Timer

During setup you're asked to choose between **cron** and a **systemd timer**. Both run the backup daily at 3:00 AM.

### Comparison

| Feature | Cron | Systemd Timer |
|---------|------|---------------|
| Setup | Single line in crontab | Service + timer unit files |
| Missed runs (server was off) | ❌ Skipped silently | ✅ `Persistent=true` — runs on next boot |
| Logging | Manual (`>> logfile`) | Built-in `journalctl` + log file |
| Resource limits | None | CPU, I/O, memory limits built-in |
| Status at a glance | `crontab -l` | `systemctl status`, `systemctl list-timers` |
| Dependency handling | None | Waits for `network-online.target` |
| Randomized delay | No | ✅ 15 min jitter (avoids thundering herd) |
| Best for | Simple setups | Production servers |

### Manual Systemd Setup (Without the Setup Script)

If you want to install the systemd units manually:

```bash
# ── R2 backend ──
cp systemd/restic-backup.service /etc/systemd/system/
cp systemd/restic-backup.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now restic-backup.timer

# ── Google Drive backend ──
cp systemd/restic-backup-gdrive.service /etc/systemd/system/
cp systemd/restic-backup-gdrive.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now restic-backup-gdrive.timer
```

### Managing the Systemd Timer

```bash
# Check when the next backup will run
systemctl list-timers restic-backup.timer

# View status of the last backup run
systemctl status restic-backup.service

# View full logs
journalctl -u restic-backup.service --no-pager -n 50

# Trigger a manual backup right now
systemctl start restic-backup.service

# Temporarily disable scheduled backups
systemctl stop restic-backup.timer
systemctl disable restic-backup.timer

# Re-enable
systemctl enable --now restic-backup.timer

# Change the schedule (edit, then reload)
systemctl edit restic-backup.timer   # creates an override
systemctl daemon-reload
```

### Customizing the Timer Schedule

Edit the `OnCalendar=` line in the `.timer` file. Examples:

```ini
OnCalendar=*-*-* 03:00:00          # Daily at 3:00 AM (default)
OnCalendar=*-*-* 03,15:00:00       # Twice daily at 3:00 AM and 3:00 PM
OnCalendar=Mon *-*-* 03:00:00      # Weekly on Monday at 3:00 AM
OnCalendar=hourly                   # Every hour
OnCalendar=*-*-* *:00/30:00        # Every 30 minutes
```

After changing, run:
```bash
systemctl daemon-reload
systemctl restart restic-backup.timer
```

### Switching from Cron to Systemd (or vice versa)

```bash
# ── Remove cron, add systemd ──
crontab -l | grep -v "restic-backup" | crontab -
cp systemd/restic-backup.service /etc/systemd/system/
cp systemd/restic-backup.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now restic-backup.timer

# ── Remove systemd, add cron ──
systemctl disable --now restic-backup.timer
rm /etc/systemd/system/restic-backup.{service,timer}
systemctl daemon-reload
echo "0 3 * * * /root/restic-backup.sh" | crontab -
```

---

## Security Notes

- Secrets file has `chmod 600` (owner-read only)
- `RESTIC_PASSWORD` encrypts all data — **store it in a password manager**
- R2 API tokens should be scoped to the specific bucket
- Google Drive: rclone config is stored in `~/.config/rclone/rclone.conf`
- Consider backing up your secrets to a **separate** secure location (password manager, encrypted USB)

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `restic: command not found` | Run `apt-get install -y restic` |
| `Fatal: unable to open config` | Repository not initialized. Run `restic init` |
| S3/R2 auth errors | Check `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` |
| Google Drive auth errors | Run `rclone config reconnect gdrive:` |
| Backup not running | Check `crontab -l` and `systemctl status cron` |
| Systemd timer not firing | Check `systemctl list-timers` and `journalctl -u restic-backup.timer` |
| Systemd service fails | Run `journalctl -u restic-backup.service -n 50` for details |
| Gotify not sending | Verify `GOTIFY_URL` and `GOTIFY_TOKEN`; test with `curl` |
| Large first backup | First backup uploads everything; subsequent ones are incremental |
| `rclone` not found | Install: `curl https://rclone.org/install.sh \| bash` |

---

## R2 vs Google Drive — Which to Choose?

| Criteria | Cloudflare R2 | Google Drive |
|----------|--------------|--------------|
| **Free tier** | 10 GB/month storage, 10M reads | 15 GB total |
| **Egress** | Always free | Free (via rclone) |
| **Speed** | Fast (S3 protocol) | Moderate (rclone overhead) |
| **Reliability** | Enterprise-grade SLA | Consumer service |
| **API limits** | Generous | 750 GB/day upload, quota limits |
| **Setup difficulty** | Easy (S3 compatible) | Easy (rclone wizard) |
| **Best for** | Production, large data | Personal projects, small data |

> 💡 **Tip**: You can use **both** backends simultaneously for extra redundancy. Just set up both cron jobs — they are completely independent.

---

## License

MIT — use freely for your own infrastructure.
