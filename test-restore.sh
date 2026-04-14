#!/usr/bin/env bash
# =============================================================================
# Flex Backup System — Monthly restore test
# =============================================================================
# Extracts a subset of the latest archive, verifies file integrity,
# and sends a Gotify notification with the result.
# Designed to run monthly via systemd timer.
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ENV_FILE="${BACKUP_ENV_FILE:-/root/.backup-secrets.env}"
RESTORE_DIR="/tmp/test-restore"
LOG_FILE="/var/log/backup.log"
STAMP_FILE="/var/log/test-restore-last"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [test-restore] $*" | tee -a "$LOG_FILE"
}

log_error() {
    log "ERROR: $*" >&2
}

# ---------------------------------------------------------------------------
# Gotify notification
# ---------------------------------------------------------------------------
notify() {
    local title="$1" message="$2" priority="${3:-5}"
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
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup() {
    # shellcheck disable=SC2317
    if [[ -d "$RESTORE_DIR" ]]; then
        rm -rf "$RESTORE_DIR"
        log "Cleaned up test restore directory"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Load environment
# ---------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Environment file not found: $ENV_FILE" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

export BORG_REPO BORG_PASSPHRASE
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

log "========== Restore test started =========="
START_TIME=$(date +%s)
CHECKS_PASSED=0
CHECKS_FAILED=0
DETAILS=""

# ---------------------------------------------------------------------------
# Step 1: Verify repository integrity
# ---------------------------------------------------------------------------
log "Checking repository integrity..."
if REPO_CHECK=$(borg check --show-rc 2>&1); then
    log "Repository check: OK"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    DETAILS+="✅ Repository integrity check passed\n"
else
    log_error "Repository check failed"
    log "$REPO_CHECK"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    DETAILS+="❌ Repository integrity check FAILED\n"
fi

# ---------------------------------------------------------------------------
# Step 2: Get latest archive info
# ---------------------------------------------------------------------------
log "Finding latest archive..."
LATEST_ARCHIVE=$(borg list --last 1 --format '{archive}' 2>/dev/null)
if [[ -z "$LATEST_ARCHIVE" ]]; then
    log_error "No archives found in repository"
    notify "❌ Restore test FAILED — $(hostname)" \
           "No archives found in repository.\nIs the backup running?" \
           "${GOTIFY_PRIORITY_ERROR:-8}"
    exit 1
fi

log "Latest archive: ${LATEST_ARCHIVE}"
DETAILS+="📦 Archive: ${LATEST_ARCHIVE}\n"

# ---------------------------------------------------------------------------
# Step 3: Dry-run extract (verify all data chunks are readable)
# ---------------------------------------------------------------------------
log "Dry-run extract (verifying data integrity)..."
if DRY_RUN_OUTPUT=$(borg extract --dry-run --show-rc "::${LATEST_ARCHIVE}" 2>&1); then
    FILE_COUNT=$(borg list "::${LATEST_ARCHIVE}" --format '{type}' 2>/dev/null | wc -l)
    log "Dry-run extract: OK (${FILE_COUNT} items)"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    DETAILS+="✅ Dry-run extract passed (${FILE_COUNT} items)\n"
else
    log_error "Dry-run extract failed"
    log "$DRY_RUN_OUTPUT"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    DETAILS+="❌ Dry-run extract FAILED\n"
fi

# ---------------------------------------------------------------------------
# Step 4: Real extract of a small subset — verify permissions & content
# ---------------------------------------------------------------------------
log "Extracting subset for verification..."
mkdir -p "$RESTORE_DIR"

# Pick first backup path from config and extract a few files
read -ra PATHS <<< "${BACKUP_PATHS:-}"
SUBSET_PATH="${PATHS[0]:-}"

if [[ -n "$SUBSET_PATH" ]]; then
    # Extract up to 100 files from first backup path
    # Extract into RESTORE_DIR
    pushd "$RESTORE_DIR" > /dev/null || exit 1
    borg extract "::${LATEST_ARCHIVE}" "${SUBSET_PATH#/}" 2>/dev/null || true
    popd > /dev/null || exit 1

    # Check: did files actually restore?
    RESTORED_FILES=$(find "$RESTORE_DIR" -type f 2>/dev/null | head -20)
    RESTORED_COUNT=$(find "$RESTORE_DIR" -type f 2>/dev/null | wc -l)

    if [[ "$RESTORED_COUNT" -gt 0 ]]; then
        log "Extracted ${RESTORED_COUNT} files to ${RESTORE_DIR}"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        DETAILS+="✅ Real extract: ${RESTORED_COUNT} files restored\n"

        # Check: non-zero file sizes?
        EMPTY_FILES=$(find "$RESTORE_DIR" -type f -empty 2>/dev/null | wc -l)
        NON_EMPTY=$((RESTORED_COUNT - EMPTY_FILES))
        if [[ "$NON_EMPTY" -gt 0 ]]; then
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
            DETAILS+="✅ File content: ${NON_EMPTY} non-empty files\n"
        else
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
            DETAILS+="⚠️ All restored files are empty\n"
        fi

        # Check: permissions preserved? (compare a sample)
        SAMPLE_FILE=$(echo "$RESTORED_FILES" | head -1)
        if [[ -n "$SAMPLE_FILE" ]]; then
            RESTORED_PERMS=$(stat -c '%a %U:%G' "$SAMPLE_FILE" 2>/dev/null || echo "unknown")
            DETAILS+="📋 Sample permissions: ${RESTORED_PERMS}\n"
        fi
    else
        log "WARNING: No files extracted from ${SUBSET_PATH}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        DETAILS+="⚠️ No files extracted from subset\n"
    fi
else
    log "WARNING: No BACKUP_PATHS configured, skipping real extract"
    DETAILS+="⚠️ Skipped real extract (no BACKUP_PATHS)\n"
fi

# ---------------------------------------------------------------------------
# Step 5: Verify cloud copy exists
# ---------------------------------------------------------------------------
log "Checking cloud backup availability..."
if RCLONE_LS=$(rclone ls "${RCLONE_DEST:-}" --max-depth 1 2>&1 | head -5); then
    if [[ -n "$RCLONE_LS" ]]; then
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        DETAILS+="✅ Cloud backup reachable (${RCLONE_DEST:-})\n"
    else
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        DETAILS+="⚠️ Cloud backup empty or unreachable\n"
    fi
else
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    DETAILS+="❌ Cannot reach cloud backup: ${RCLONE_DEST:-}\n"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

# Write stamp
date '+%Y-%m-%d %H:%M:%S' > "$STAMP_FILE"

SUMMARY="${CHECKS_PASSED} passed, ${CHECKS_FAILED} failed — ${DURATION}s"
log "Restore test finished: ${SUMMARY}"
log "========== Restore test finished =========="

if [[ "$CHECKS_FAILED" -eq 0 ]]; then
    notify "✅ Restore test OK — $(hostname)" \
           "Monthly restore verification passed.\n${SUMMARY}\n\n${DETAILS}" \
           "${GOTIFY_PRIORITY_TEST:-5}"
    exit 0
else
    notify "⚠️ Restore test issues — $(hostname)" \
           "Some checks failed!\n${SUMMARY}\n\n${DETAILS}" \
           "${GOTIFY_PRIORITY_ERROR:-8}"
    exit 1
fi
