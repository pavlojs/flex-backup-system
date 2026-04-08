#!/bin/bash
# ============================================================
# ONE-TIME SETUP — Run once after configuring secrets
# ============================================================
set -euo pipefail

echo "=== [1/5] Installing restic ==="
apt-get update -qq && apt-get install -y restic
restic self-update 2>/dev/null || true   # optionally get the latest version
echo "Restic: $(restic version)"

echo ""
echo "=== [2/5] Installing awscli (for R2 diagnostics) ==="
apt-get install -y awscli

echo ""
echo "=== [3/5] Copying files ==="
cp backup-secrets.env.template /root/.backup-secrets.env
chmod 600 /root/.backup-secrets.env
echo ">> EDIT NOW: /root/.backup-secrets.env"
echo "   Fill in all values, then press ENTER to continue."
read -r

cp restic-backup.sh /root/restic-backup.sh
chmod 700 /root/restic-backup.sh

echo ""
echo "=== [4/5] Initializing restic repository on R2 ==="
set -a
source /root/.backup-secrets.env
set +a
restic init
echo "Repository initialized!"

echo ""
echo "=== [5/5] Scheduling — cron or systemd timer ==="
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
  cp systemd/restic-backup.service /etc/systemd/system/restic-backup.service
  cp systemd/restic-backup.timer   /etc/systemd/system/restic-backup.timer
  systemctl daemon-reload
  systemctl enable --now restic-backup.timer
  echo "Systemd timer active:"
  systemctl list-timers restic-backup.timer --no-pager
  echo ""
  echo "Useful commands:"
  echo "  systemctl status restic-backup.timer   # timer status"
  echo "  systemctl status restic-backup.service  # last run status"
  echo "  journalctl -u restic-backup.service     # full log"
  echo "  systemctl start restic-backup.service   # manual run"
else
  CRON_LINE="0 3 * * * /root/restic-backup.sh"
  ( crontab -l 2>/dev/null | grep -v "restic-backup"; echo "$CRON_LINE" ) | crontab -
  echo "Cron active: $CRON_LINE"
fi

echo ""
echo "=== SETUP COMPLETE ==="
echo "Run your first test backup:"
if [ "$SCHED_CHOICE" = "2" ]; then
  echo "  systemctl start restic-backup.service"
else
  echo "  /root/restic-backup.sh"
fi
echo ""
echo "Check snapshots:"
echo "  source /root/.backup-secrets.env && restic snapshots"
