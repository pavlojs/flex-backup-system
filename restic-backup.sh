#!/bin/bash
# ============================================================
# RESTIC BACKUP → CLOUDFLARE R2
# Cron: 0 3 * * * /root/restic-backup.sh
# ============================================================
set -uo pipefail

# --- Load secrets ---
set -a
source /root/.backup-secrets.env
set +a

# --- Configuration ---
BACKUP_PATHS=(
  "/var/lib/docker/volumes"
  "/home/pavlojs/apps"
)
LOGFILE="/var/log/restic-backup.log"
HOSTNAME="$(hostname)"

# --- Gotify notification ---
gotify_notify() {
  local title="$1"
  local message="$2"
  local priority="$3"
  if [ -n "${GOTIFY_URL:-}" ] && [ -n "${GOTIFY_TOKEN:-}" ]; then
    curl -s -X POST "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" \
      -F "title=${title}" \
      -F "message=${message}" \
      -F "priority=${priority}" >/dev/null 2>&1 || true
  fi
}

# --- Backup ---
{
  echo ""
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') START BACKUP ====="

  restic backup "${BACKUP_PATHS[@]}" \
    --exclude-caches \
    --one-file-system \
    --compression max

  echo "----- $(date '+%H:%M:%S') Backup OK, running forget/prune -----"

  restic forget \
    --keep-daily  5 \
    --keep-weekly 1 \
    --keep-monthly 1 \
    --prune

  echo "----- $(date '+%H:%M:%S') Forget OK, running check -----"

  restic check --read-data-subset=5%

  echo "===== $(date '+%Y-%m-%d %H:%M:%S') BACKUP COMPLETED SUCCESSFULLY ====="

} >> "$LOGFILE" 2>&1
STATUS=$?

if [ $STATUS -eq 0 ]; then
  gotify_notify \
    "✅ Backup OK — ${HOSTNAME}" \
    "Restic → R2 completed successfully. Details: ${LOGFILE}" \
    "${GOTIFY_PRIORITY_SUCCESS:-3}"
else
  gotify_notify \
    "❌ Backup FAILED — ${HOSTNAME}" \
    "Restic → R2 FAILED. Check: ${LOGFILE}" \
    "${GOTIFY_PRIORITY_ERROR:-8}"
  exit 1
fi
