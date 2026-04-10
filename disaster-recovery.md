# Disaster Recovery Guide

**Written for non-technical users.** Follow the steps exactly as shown.

---

## Table of Contents

1. [Glossary — What These Words Mean](#1-glossary)
2. [How to Check That Backups Are Working](#2-how-to-check-that-backups-are-working)
3. [Scenario A — I Accidentally Deleted Files](#3-scenario-a--i-accidentally-deleted-files)
4. [Scenario B — The Server's Disk Failed](#4-scenario-b--the-servers-disk-failed)
5. [Scenario C — The Server Was Hacked](#5-scenario-c--the-server-was-hacked)
6. [Scenario D — The VPS Was Deleted / Starting From Scratch](#6-scenario-d--the-vps-was-deleted--starting-from-scratch)
7. [How to Remove Everything and Return to a Clean System](#7-how-to-remove-everything)
8. [Important Paths and Files](#8-important-paths-and-files)
9. [What You Need to Have Saved](#9-what-you-need-to-have-saved)
10. [Contacts](#10-contacts)

---

## 1. Glossary

| Term | What it means |
|------|---------------|
| **BorgBackup (borg)** | The program that creates backups. It saves your files in a special compressed and encrypted format. |
| **Archive** | One backup snapshot. Like a photo of all your files taken at a specific time. |
| **Repository (repo)** | The place where all archives are stored. Think of it as a folder containing all your backup photos. |
| **rclone** | A program that copies the repository to the cloud (Cloudflare R2 or Google Drive). |
| **R2** | Cloudflare's cloud storage service where an offsite copy of your backups lives. |
| **Passphrase** | The password that encrypts your backups. Without it, nobody (including you) can read them. |
| **Borg key** | A special key file used together with the passphrase to unlock backups. You must have BOTH. |

---

## 2. How to Check That Backups Are Working

### Quick check (30 seconds)

```bash
# When was the last successful backup?
cat /var/log/borg-backup-last-success
```

If the date is today or yesterday, backups are working.

### Detailed check

```bash
# Are the timers active?
systemctl list-timers borg-*

# What was the result of the last backup?
systemctl status borg-backup.service

# List all backup archives
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
borg list
```

### Monthly restore test

The system automatically tests restore on the 1st of every month and sends a Gotify notification. Check:

```bash
cat /var/log/borg-test-restore-last
```

---

## 3. Scenario A — I Accidentally Deleted Files

**Situation**: The server is running fine, but you deleted some files by mistake.

### Step 1: Find which archive has your files

```bash
# Load backup credentials
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE

# List all archives (newest last)
borg list
```

You'll see something like:

```
myserver-2026-04-08T03:00    Mon, 2026-04-08 03:00:15
myserver-2026-04-09T03:00    Tue, 2026-04-09 03:00:12
myserver-2026-04-10T03:00    Wed, 2026-04-10 03:00:18
```

### Step 2: See what's inside an archive

```bash
# List files in the latest archive
borg list ::myserver-2026-04-10T03:00 | grep "the-file-you-lost"
```

### Step 3a: Restore specific files

```bash
# Restore a specific file to a temporary location
borg extract ::myserver-2026-04-10T03:00 var/lib/docker/volumes/myapp/data/important-file.txt \
    --target /tmp/restored

# Check the file
ls -la /tmp/restored/var/lib/docker/volumes/myapp/data/important-file.txt

# Copy it back to where it belongs
cp /tmp/restored/var/lib/docker/volumes/myapp/data/important-file.txt \
   /var/lib/docker/volumes/myapp/data/important-file.txt
```

### Step 3b: Restore an entire directory

```bash
# Restore a full Docker volume
borg extract ::myserver-2026-04-10T03:00 var/lib/docker/volumes/myapp \
    --target /tmp/restored

# Copy it back
cp -a /tmp/restored/var/lib/docker/volumes/myapp/* /var/lib/docker/volumes/myapp/
```

### Step 4: Clean up

```bash
rm -rf /tmp/restored
```

### Step 5: Restart affected containers

```bash
docker restart myapp
```

---

## 4. Scenario B — The Server's Disk Failed

**Situation**: Your server is running but the disk with data is corrupted or replaced. The local borg repository may be damaged or lost, but the cloud copy is safe.

### Step 1: Restore borg repository from cloud

```bash
# Install tools (if not already installed)
apt-get update && apt-get install -y borgbackup rclone

# Recreate the secrets file from your password manager
nano /root/.backup-secrets.env
# (Paste the contents you saved in your password manager)
chmod 600 /root/.backup-secrets.env

# Load credentials
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
```

Configure rclone (for R2):

```bash
rclone config create r2 s3 \
    provider=Cloudflare \
    access_key_id="$R2_ACCESS_KEY_ID" \
    secret_access_key="$R2_SECRET_ACCESS_KEY" \
    endpoint="$R2_ENDPOINT" \
    acl=private \
    no_check_bucket=true
```

Download the repository:

```bash
mkdir -p "$BORG_REPO"
rclone sync "$RCLONE_DEST" "$BORG_REPO" --progress
```

### Step 2: Import borg key (if needed)

If the borg key was lost with the disk:

```bash
# Get the key you saved in your password manager
borg key import :: /path/to/saved-key-file
# OR paste it interactively:
borg key import :: -
# (paste the key, then Ctrl+D)
```

### Step 3: Verify and restore

```bash
# Verify repository
borg check

# List archives
borg list

# Restore everything
borg extract ::LATEST_ARCHIVE --target /
```

### Step 4: Restart services

```bash
# Restart Docker containers
docker restart $(docker ps -q)

# Or start specific compose stacks
cd /home/user/apps/mystack && docker compose up -d
```

---

## 5. Scenario C — The Server Was Hacked

**Situation**: Your server was compromised. You need to start fresh and restore from backups.

> ⚠️ **IMPORTANT**: Do NOT restore from the local borg repository — it may be tampered with. Restore only from the cloud copy (R2 / Google Drive).

### Step 1: Provision a new server

Order a new VPS (same provider or different — doesn't matter). Install Ubuntu 22.04 or later.

### Step 2: Install tools

```bash
apt-get update
apt-get install -y borgbackup curl
curl -fsSL https://rclone.org/install.sh | bash
```

### Step 3: Recreate secrets

From your **password manager**, get:
- The contents of `.backup-secrets.env`
- The borg repository key
- The borg passphrase

```bash
nano /root/.backup-secrets.env
# (paste your saved config)
chmod 600 /root/.backup-secrets.env
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
```

### Step 4: Configure rclone and download

For R2:

```bash
rclone config create r2 s3 \
    provider=Cloudflare \
    access_key_id="$R2_ACCESS_KEY_ID" \
    secret_access_key="$R2_SECRET_ACCESS_KEY" \
    endpoint="$R2_ENDPOINT" \
    acl=private \
    no_check_bucket=true

mkdir -p "$BORG_REPO"
rclone sync "$RCLONE_DEST" "$BORG_REPO" --progress
```

For Google Drive:

```bash
rclone config  # Set up "gdrive" remote interactively

mkdir -p "$BORG_REPO"
rclone sync "${RCLONE_REMOTE}:${RCLONE_GDRIVE_FOLDER}" "$BORG_REPO" --progress
```

### Step 5: Import borg key

```bash
borg key import :: -
# (paste the key from your password manager, then Ctrl+D)
```

### Step 6: Verify repository

```bash
borg check
borg list
```

### Step 7: Restore data

```bash
# Restore Docker volumes and app data
borg extract ::LATEST_ARCHIVE --target /
```

### Step 8: Install Docker and start services

```bash
# Install Docker
curl -fsSL https://get.docker.com | bash

# Start your services
cd /home/user/apps/mystack && docker compose up -d
```

### Step 9: Re-install backup system

```bash
git clone https://github.com/pavlojs/flex-backup-system.git
cd flex-backup-system
bash borg-setup.sh  # Or borg-setup-gdrive.sh
```

### Step 10: Rotate ALL credentials

After a hack, **change everything**:
- R2 API keys (Cloudflare dashboard)
- Borg passphrase (`borg key change-passphrase`)
- Gotify token
- All application passwords
- SSH keys

---

## 6. Scenario D — The VPS Was Deleted / Starting From Scratch

**Situation**: The VPS is gone entirely. You're starting on a brand new empty server.

Follow **Scenario C** exactly — the steps are the same. The only difference is you don't need to worry about compromised data.

---

## 7. How to Remove Everything

To completely remove the backup system and return to a clean, un-backed-up system:

```bash
sudo /root/borg-uninstall.sh
```

The script will interactively ask you to confirm:
- Stopping systemd timers
- Deleting the local borg repository
- Deleting cloud backup data (R2 / Google Drive)
- Removing config files, scripts, logs
- Optionally uninstalling borgbackup and rclone

After running this, the server will have no backup system installed.

### Manual removal (if uninstall script is missing)

```bash
# Stop timers
systemctl stop borg-backup.timer borg-test-restore.timer
systemctl disable borg-backup.timer borg-test-restore.timer

# Remove systemd files
rm -f /etc/systemd/system/borg-backup.{service,timer}
rm -f /etc/systemd/system/borg-test-restore.{service,timer}
systemctl daemon-reload

# Delete local repository (CAREFUL — this deletes all local backups!)
rm -rf /var/backups/borg

# Delete cloud data (CAREFUL — this deletes all cloud backups!)
source /root/.backup-secrets.env
rclone purge "$RCLONE_DEST"

# Remove scripts and config
rm -f /root/borg-backup.sh /root/borg-test-restore.sh /root/borg-uninstall.sh
rm -f /root/.backup-secrets.env
rm -f /var/log/borg-backup.log /var/log/borg-backup-last-success /var/log/borg-test-restore-last
rm -f /var/lock/borg-backup.lock
rm -f /etc/logrotate.d/borg-backup

# Optionally remove packages
apt-get remove -y borgbackup rclone
```

---

## 8. Important Paths and Files

| Path | Description |
|------|-------------|
| `/root/.backup-secrets.env` | All configuration and credentials |
| `/var/backups/borg/` | Local borg repository (all backup data) |
| `/root/borg-backup.sh` | Main backup script |
| `/root/borg-test-restore.sh` | Monthly restore test script |
| `/root/borg-uninstall.sh` | Uninstall script |
| `/var/log/borg-backup.log` | Backup log file |
| `/var/log/borg-backup-last-success` | Timestamp of last successful backup |
| `/var/log/borg-test-restore-last` | Timestamp of last restore test |
| `/etc/systemd/system/borg-backup.*` | Systemd service and timer |
| `/etc/systemd/system/borg-test-restore.*` | Systemd restore test units |

---

## 9. What You Need to Have Saved

To recover from a total loss, you need **three things** stored in your password manager:

| Item | Why you need it | How to get it |
|------|----------------|---------------|
| **Borg passphrase** | Decrypts all backup data | From your `.backup-secrets.env` |
| **Borg repository key** | Required together with passphrase | `borg key export ::` (done during setup) |
| **`.backup-secrets.env` contents** | R2/GDrive credentials, backup config | Copy from `/root/.backup-secrets.env` |

> ⚠️ If you lose the passphrase OR the key, your backups **cannot be recovered**. There is no reset or recovery option. Save both in at least two places.

---

## 10. Contacts

| Role | Contact |
|------|---------|
| System administrator | *(fill in your contact)* |
| Backup responsible | *(fill in your contact)* |

---

*Last updated: April 2026*
