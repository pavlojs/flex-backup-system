#!/bin/bash
# ============================================================
# ONE-TIME SETUP — Google Drive backend (via rclone)
# Run once after configuring secrets
# ============================================================
set -euo pipefail

echo "=== [1/6] Installing restic ==="
apt-get update -qq && apt-get install -y restic
restic self-update 2>/dev/null || true
echo "Restic: $(restic version)"

echo ""
echo "=== [2/6] Installing rclone ==="
if ! command -v rclone &>/dev/null; then
  curl https://rclone.org/install.sh | bash
else
  echo "rclone already installed: $(rclone version --check | head -1)"
fi

echo ""
echo "=== [3/6] Configuring rclone remote for Google Drive ==="
echo ""
echo "You need to create an rclone remote for Google Drive."
echo "If you are on a HEADLESS server (no browser), you will need to"
echo "authorize on another machine first. See README.md for details."
echo ""
echo "Starting interactive rclone config..."
echo "  → Choose: New remote"
echo "  → Name:   gdrive"
echo "  → Type:   drive (Google Drive)"
echo "  → Follow prompts (defaults are fine for most options)"
echo ""
read -rp "Press ENTER to start rclone config..."
rclone config

echo ""
echo "=== [4/6] Copying files ==="
cp backup-secrets-gdrive.env.template /root/.backup-secrets-gdrive.env
chmod 600 /root/.backup-secrets-gdrive.env
echo ">> EDIT NOW: /root/.backup-secrets-gdrive.env"
echo "   Fill in all values (especially RESTIC_PASSWORD), then press ENTER."
read -r

cp restic-backup-gdrive.sh /root/restic-backup-gdrive.sh
chmod 700 /root/restic-backup-gdrive.sh

echo ""
echo "=== [5/6] Initializing restic repository on Google Drive ==="
set -a
source /root/.backup-secrets-gdrive.env
set +a
restic init
echo "Repository initialized!"

echo ""
echo "=== [6/6] Scheduling — cron or systemd timer ==="
echo ""
echo "Choose how to schedule backups (daily at 3:00 AM):"
echo "  1) Cron job (traditional, simple)"
echo "  2) Systemd timer (modern, better logging & resource control)"
echo ""
read -rp "Enter 1 or 2 [default: 1]: " SCHED_CHOICE
SCHED_CHOICE="${SCHED_CHOICE:-1}"

if [ "$SCHED_CHOICE" = "2" ]; then
  echo ""
  echo "Installing systemd service + timer..."
  cp systemd/restic-backup-gdrive.service /etc/systemd/system/restic-backup-gdrive.service
  cp systemd/restic-backup-gdrive.timer   /etc/systemd/system/restic-backup-gdrive.timer
  systemctl daemon-reload
  systemctl enable --now restic-backup-gdrive.timer
  echo "Systemd timer active:"
  systemctl list-timers restic-backup-gdrive.timer --no-pager
  echo ""
  echo "Useful commands:"
  echo "  systemctl status restic-backup-gdrive.timer   # timer status"
  echo "  systemctl status restic-backup-gdrive.service  # last run status"
  echo "  journalctl -u restic-backup-gdrive.service     # full log"
  echo "  systemctl start restic-backup-gdrive.service   # manual run"
else
  CRON_LINE="0 3 * * * /root/restic-backup-gdrive.sh"
  ( crontab -l 2>/dev/null | grep -v "restic-backup-gdrive"; echo "$CRON_LINE" ) | crontab -
  echo "Cron active: $CRON_LINE"
fi

echo ""
echo "=== SETUP COMPLETE ==="
echo "Run a test backup:"
if [ "$SCHED_CHOICE" = "2" ]; then
  echo "  systemctl start restic-backup-gdrive.service"
else
  echo "  /root/restic-backup-gdrive.sh"
fi
echo ""
echo "Check snapshots:"
echo "  source /root/.backup-secrets-gdrive.env && restic snapshots"
