#!/usr/bin/env bash
# =============================================================================
# Flex Backup System — BorgBackup + rclone sync
# =============================================================================
# Daily backup: borg create (local) → borg prune → borg compact → rclone sync (cloud)
# Notifications via Gotify on success/failure with detailed stats.
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ENV_FILE="${BACKUP_ENV_FILE:-/root/.backup-secrets.env}"
LOCK_FILE="/var/lock/backup.lock"
LOG_FILE="/var/log/backup.log"
STAMP_FILE="/var/log/backup-last-success"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

log_error() {
    log "ERROR: $*" >&2
}

# ---------------------------------------------------------------------------
# Gotify notification
# ---------------------------------------------------------------------------
notify() {
    local title="$1" message="$2" priority="${3:-3}"
    if [[ -n "${GOTIFY_URL:-}" && -n "${GOTIFY_TOKEN:-}" ]]; then
        curl -fsSL --max-time 10 \
            "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" \
            -F "title=${title}" \
            -F "message=${message}" \
            -F "priority=${priority}" \
            >/dev/null 2>&1 || log "WARNING: Gotify notification failed"
    fi
}

# ---------------------------------------------------------------------------
# Error handler
# ---------------------------------------------------------------------------
CURRENT_PHASE="init"
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        local msg="Backup FAILED during phase: ${CURRENT_PHASE} (exit code: ${exit_code})"
        log_error "$msg"
        notify "❌ Backup FAILED — $(hostname)" \
               "$msg\nCheck log: $LOG_FILE" \
               "${GOTIFY_PRIORITY_ERROR:-8}"
    fi
    # Release lock (fd 9 closed automatically)
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Load environment
# ---------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Environment file not found: $ENV_FILE" >&2
    echo "Run setup.sh first or set BACKUP_ENV_FILE." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------
CURRENT_PHASE="validation"
missing=()
for var in BORG_REPO BORG_PASSPHRASE RCLONE_DEST BACKUP_PATHS; do
    if [[ -z "${!var:-}" ]]; then
        missing+=("$var")
    fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required variables: ${missing[*]}"
    exit 1
fi

export BORG_REPO BORG_PASSPHRASE
# Suppress borg "terminating with success" warnings
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

# ---------------------------------------------------------------------------
# Acquire exclusive lock (prevent parallel runs)
# ---------------------------------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log_error "Another backup is already running (lock: $LOCK_FILE)"
    exit 1
fi

log "========== Backup started =========="
START_TIME=$(date +%s)

# ---------------------------------------------------------------------------
# Update borg and rclone
# ---------------------------------------------------------------------------
CURRENT_PHASE="update"
log "Checking for borg/rclone updates..."

if command -v apt-get &>/dev/null; then
    apt-get update -qq 2>/dev/null || log "WARNING: apt-get update failed"
    apt-get install -y -qq --only-upgrade borgbackup 2>/dev/null || true
fi

if command -v rclone &>/dev/null; then
    rclone selfupdate -q 2>/dev/null || true
fi

log "borg $(borg --version 2>/dev/null || echo 'unknown'), rclone $(rclone version --check 2>/dev/null | head -1 || rclone version 2>/dev/null | head -1 || echo 'unknown')"

# ---------------------------------------------------------------------------
# Build exclude arguments
# ---------------------------------------------------------------------------
EXCLUDE_ARGS=()
EXCLUDE_ARGS+=("--exclude-caches")
while IFS= read -r pattern; do
    pattern="$(echo "$pattern" | xargs)"  # trim whitespace
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    EXCLUDE_ARGS+=("--exclude" "$pattern")
done <<< "${BACKUP_EXCLUDES:-}"

# ---------------------------------------------------------------------------
# Phase 1: Borg create
# ---------------------------------------------------------------------------
CURRENT_PHASE="borg-create"
ARCHIVE_NAME="$(hostname)-$(date '+%Y-%m-%dT%H:%M')"
log "Creating archive: ${ARCHIVE_NAME}"

# Split BACKUP_PATHS into array
read -ra PATHS <<< "$BACKUP_PATHS"

# Verify paths exist
for p in "${PATHS[@]}"; do
    if [[ ! -e "$p" ]]; then
        log "WARNING: Backup path does not exist, skipping: $p"
    fi
done

BORG_OUTPUT=$(borg create \
    --stats \
    --show-rc \
    --compression zstd,6 \
    --one-file-system \
    "${EXCLUDE_ARGS[@]}" \
    "::${ARCHIVE_NAME}" \
    "${PATHS[@]}" 2>&1) || {
    log_error "borg create failed"
    log "$BORG_OUTPUT"
    exit 1
}
log "$BORG_OUTPUT"

# Parse stats from borg output
BORG_STATS=$(echo "$BORG_OUTPUT" | grep -E "^(This archive|All archives|Deduplicated size|Number of files)" || true)

# ---------------------------------------------------------------------------
# Phase 2: Borg prune
# ---------------------------------------------------------------------------
CURRENT_PHASE="borg-prune"
log "Pruning old archives (keep: ${KEEP_DAILY:-7}d/${KEEP_WEEKLY:-4}w/${KEEP_MONTHLY:-6}m)"

PRUNE_OUTPUT=$(borg prune \
    --stats \
    --show-rc \
    --keep-daily="${KEEP_DAILY:-7}" \
    --keep-weekly="${KEEP_WEEKLY:-4}" \
    --keep-monthly="${KEEP_MONTHLY:-6}" \
    2>&1) || {
    log_error "borg prune failed"
    log "$PRUNE_OUTPUT"
    exit 1
}
log "$PRUNE_OUTPUT"

# ---------------------------------------------------------------------------
# Phase 3: Borg compact (free disk space after prune)
# ---------------------------------------------------------------------------
CURRENT_PHASE="borg-compact"
log "Compacting repository"

COMPACT_OUTPUT=$(borg compact --show-rc 2>&1) || {
    log_error "borg compact failed"
    log "$COMPACT_OUTPUT"
    exit 1
}
log "$COMPACT_OUTPUT"

# ---------------------------------------------------------------------------
# Phase 4: rclone sync to cloud
# ---------------------------------------------------------------------------
CURRENT_PHASE="rclone-sync"
log "Syncing to cloud: ${RCLONE_DEST}"

RCLONE_OUTPUT=$(rclone sync \
    "$BORG_REPO" \
    "$RCLONE_DEST" \
    --transfers 4 \
    --checkers 8 \
    --stats-one-line \
    --stats 0 \
    --log-level NOTICE \
    2>&1) || {
    log_error "rclone sync failed"
    log "$RCLONE_OUTPUT"
    exit 1
}
log "$RCLONE_OUTPUT"

# ---------------------------------------------------------------------------
# Success
# ---------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
DURATION_MIN=$(( DURATION / 60 ))
DURATION_SEC=$(( DURATION % 60 ))

# Get repo size
REPO_SIZE=$(du -sh "$BORG_REPO" 2>/dev/null | cut -f1 || echo "unknown")

# Write stamp
date '+%Y-%m-%d %H:%M:%S' > "$STAMP_FILE"

log "Backup completed in ${DURATION_MIN}m ${DURATION_SEC}s — repo size: ${REPO_SIZE}"
log "========== Backup finished =========="

# Success notification
notify "✅ Backup OK — $(hostname)" \
       "Archive: ${ARCHIVE_NAME}
Duration: ${DURATION_MIN}m ${DURATION_SEC}s
Local repo: ${REPO_SIZE}
Cloud: ${RCLONE_DEST}
Retention: ${KEEP_DAILY:-7}d / ${KEEP_WEEKLY:-4}w / ${KEEP_MONTHLY:-6}m

${BORG_STATS}" \
       "${GOTIFY_PRIORITY_SUCCESS:-3}"
