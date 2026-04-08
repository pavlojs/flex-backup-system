# Disaster Recovery — Data Recovery Guide

> **Who is this document for?**
> For someone who has never worked with backups and needs to restore a server after a failure.
> Read step by step. Do not skip any steps.

---

## Before You Start — What You Need

Before proceeding with recovery, make sure you have access to:

- [ ] The `/root/.backup-secrets.env` file (or a copy saved in a password manager)
- [ ] The restic repository password (the `RESTIC_PASSWORD` field from the file above)
- [ ] Access to the Cloudflare dashboard (to verify your data is there)
- [ ] A new or restored Ubuntu server

---

## Glossary — Terms Explained

| Term | Meaning |
|---|---|
| **Restic** | The program that created your backups. Now it will restore them. |
| **Snapshot** | One backup from a specific day, like a "photo" of your server in time. |
| **Repository** | The location on Cloudflare R2 where all snapshots are stored. |
| **R2** | Cloudflare R2 — the cloud storage service where your data physically lives. |
| **Restore** | Recovery — copying data from a backup back to your server. |

---

## PART 1 — Verifying Your Backup Works (Verification)

> Do these steps when **there is no failure** — once a month to be sure.

### Step 1.1 — Log in to your server

```bash
ssh root@SERVER_ADDRESS
```

### Step 1.2 — Load the configuration

```bash
source /root/.backup-secrets.env
```

If this command returns an error, the secrets file doesn't exist — go to Part 3.

### Step 1.3 — List your backups

```bash
restic snapshots
```

You should see a table similar to this:

```
ID        Time                 Host         Paths
-------------------------------------------------------
a1b2c3d4  2025-01-15 03:00:12  my-server    /var/lib/docker/volumes
e5f6g7h8  2025-01-14 03:00:08  my-server    /var/lib/docker/volumes
```

Each row is one backup from one day. **If the list is empty — backups are not working.**

### Step 1.4 — Verify data integrity

```bash
restic check
```

At the end you should see: `no errors were found`. Anything else — contact your administrator.

---

## PART 2 — Recovery After Failure (Disaster Recovery)

### Scenario A — Server is running, but I deleted/overwritten files

This is the simplest case. The server is up, restic is installed.

#### Step A.1 — Load the configuration

```bash
source /root/.backup-secrets.env
```

#### Step A.2 — Find the right snapshot

```bash
restic snapshots
```

Remember the **ID** of the snapshot from the day you want to restore (e.g., `a1b2c3d4`).
If you always want the latest one, you can write `latest` instead of a specific ID.

#### Step A.3 — Restore a specific folder or file

Restore **one directory** to its original location:

```bash
restic restore latest \
  --target / \
  --include /home/pavlojs/apps
```

Restore **a specific file** (e.g., a database):

```bash
restic restore latest \
  --target /tmp/restored \
  --include /var/lib/docker/volumes/my-container/_data/database.db
```

The file will appear in `/tmp/restored/` — you can check it before moving it to the correct location.

#### Step A.4 — Restore everything

```bash
restic restore latest --target /
```

> ⚠️ **Warning:** This will overwrite existing files with their backup versions. Make sure this is what you want.

---

### Scenario B — Server completely down, setting up a new one

#### Step B.1 — Install the system and basic tools

On a fresh Ubuntu:

```bash
apt-get update && apt-get install -y restic
```

#### Step B.2 — Restore your secrets file

You need to manually create the `/root/.backup-secrets.env` file with the data you saved securely:

```bash
nano /root/.backup-secrets.env
```

Paste the content (see the template in this repository: `backup-secrets.env.template`) and fill in the real values.

```bash
chmod 600 /root/.backup-secrets.env
source /root/.backup-secrets.env
```

#### Step B.3 — Verify access to your backup

```bash
restic snapshots
```

If you see a list of snapshots — your data is safe and ready to be restored.

#### Step B.4 — Restore your data

```bash
restic restore latest --target /
```

#### Step B.5 — Start Docker and containers

```bash
apt-get install -y docker.io docker-compose
cd /home/pavlojs/apps
docker-compose up -d
```

#### Step B.6 — Reinstall the backup script

```bash
cp /home/pavlojs/apps/backup/restic-backup.sh /root/restic-backup.sh
chmod 700 /root/restic-backup.sh
```

Choose **one** of the scheduling options:

**Option A — Cron:**
```bash
(crontab -l 2>/dev/null; echo "0 3 * * * /root/restic-backup.sh") | crontab -
```

**Option B — Systemd timer:**
```bash
cp /home/pavlojs/apps/backup/systemd/restic-backup.service /etc/systemd/system/
cp /home/pavlojs/apps/backup/systemd/restic-backup.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now restic-backup.timer

# Check if the timer is active:
systemctl list-timers restic-backup.timer
```

---

## PART 3 — When Something Doesn't Work — Diagnostics

### Problem: `source /root/.backup-secrets.env` returns "No such file"

Your secrets file is missing. You need to restore it from a copy (password manager, another server).
Without this file **you cannot restore your data** — that's why keep it in at least two places.

### Problem: `restic snapshots` returns an authorization error

Likely cause: your Cloudflare API key has changed or the token has expired.

1. Log in to [dash.cloudflare.com](https://dash.cloudflare.com)
2. Go to **R2 → Manage R2 API Tokens**
3. Create a new token with `Object Read & Write` permissions
4. Update `/root/.backup-secrets.env`

### Problem: `restic check` shows errors

```bash
restic rebuild-index
restic check
```

If errors persist, run:

```bash
restic repair snapshots --forget
```

### Problem: Backup hasn't run in several days (no Gotify notifications)

Check the log:

```bash
tail -50 /var/log/restic-backup.log
```

Check if cron or systemd timer is running:

```bash
# If you're using cron:
crontab -l
systemctl status cron

# If you're using systemd timer:
systemctl list-timers restic-backup.timer
systemctl status restic-backup.service
journalctl -u restic-backup.service -n 50
```

Run it manually:

```bash
# Cron / directly:
/root/restic-backup.sh

# Systemd:
systemctl start restic-backup.service
```

---

## PART 4 — Backup Schedule

| Type | Kept | What it means |
|---|---|---|
| Daily | 5 most recent days | You can go back max 5 days |
| Weekly | 1 (last week's) | One backup from last week |
| Monthly | 1 (last month's) | One backup from last month |

> Backups run automatically **daily at 3:00 AM**.
> After each successful or failed backup, a Gotify notification is sent.

---

## PART 5 — Important Paths and Files

| What | Where |
|---|---|
| Backup script (R2) | `/root/restic-backup.sh` |
| Backup script (Google Drive) | `/root/restic-backup-gdrive.sh` |
| Secrets file (R2) | `/root/.backup-secrets.env` |
| Secrets file (Google Drive) | `/root/.backup-secrets-gdrive.env` |
| Backup log (R2) | `/var/log/restic-backup.log` |
| Backup log (Google Drive) | `/var/log/restic-backup-gdrive.log` |
| Systemd service (R2) | `/etc/systemd/system/restic-backup.service` |
| Systemd timer (R2) | `/etc/systemd/system/restic-backup.timer` |
| Systemd service (Google Drive) | `/etc/systemd/system/restic-backup-gdrive.service` |
| Systemd timer (Google Drive) | `/etc/systemd/system/restic-backup-gdrive.timer` |
| Rclone config | `~/.config/rclone/rclone.conf` |
| Docker data | `/var/lib/docker/volumes` |
| Applications | `/home/pavlojs/apps` |

---

## PART 6 — Contacts and Escalation

> Fill in this section with your own information.

| Role | Name | Contact |
|---|---|---|
| Server Administrator | | |
| Cloudflare Account Owner | | |
| Backup Contact (when admin unavailable) | | |

---

## PART 7 — Google Drive Backend (Optional)

> If your backup uses Google Drive instead of (or in addition to) Cloudflare R2.

### Google Drive Secrets File

File: `/root/.backup-secrets-gdrive.env`

Script: `/root/restic-backup-gdrive.sh`

Log: `/var/log/restic-backup-gdrive.log`

### Restoring from Google Drive

The procedure is **identical** to R2. The only difference is the secrets file:

```bash
# Instead of:
source /root/.backup-secrets.env

# Use:
source /root/.backup-secrets-gdrive.env
```

Rclone connection issues:

```bash
rclone config reconnect gdrive:
```

On a headless server (no browser):
1. On a computer with a browser, run: `rclone authorize "drive"`
2. Log in to Google
3. Copy the token back to the server

All other restic commands (`snapshots`, `restore`, `check`) work the same way.

---

*Document automatically generated. For the last configuration update, check the date of the latest snapshot (`restic snapshots`).*
