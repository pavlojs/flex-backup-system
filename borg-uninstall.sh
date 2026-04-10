#!/usr/bin/env bash
# =============================================================================
# Flex Backup System — Uninstall
# =============================================================================
# Removes all backup components: systemd timers, scripts, borg repo,
# cloud data, logs, and optionally the packages themselves.
# Interactive with confirmations for destructive actions.
# =============================================================================
set -uo pipefail

ENV_FILE="/root/.backup-secrets.env"
INSTALL_DIR="/root"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

confirm() {
    read -rp "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

confirm_danger() {
    echo ""
    echo -e "  \033[1;31m⚠️  WARNING: This action is IRREVERSIBLE!\033[0m"
    read -rp "$1 Type YES to confirm: " ans
    [[ "$ans" == "YES" ]]
}

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { err "This script must be run as root."; exit 1; }

info "=== Flex Backup System — Uninstall ==="
echo ""
echo "  This will remove the backup system from this server."
echo "  You will be asked to confirm each destructive step."
echo ""

if ! confirm "Continue with uninstall?"; then
    echo "Cancelled."
    exit 0
fi

REMOVED=()
SKIPPED=()

# ---------------------------------------------------------------------------
# Load environment (if available, for BORG_REPO and RCLONE_DEST)
# ---------------------------------------------------------------------------
BORG_REPO=""
RCLONE_DEST=""
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Step 1: Stop and disable systemd timers/services
# ---------------------------------------------------------------------------
info "Stopping systemd timers and services..."
for unit in borg-backup.timer borg-backup.service borg-test-restore.timer borg-test-restore.service; do
    if systemctl is-active "$unit" &>/dev/null || systemctl is-enabled "$unit" &>/dev/null; then
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
        ok "Stopped and disabled $unit"
        REMOVED+=("systemd: $unit")
    fi
done

# ---------------------------------------------------------------------------
# Step 2: Remove systemd unit files
# ---------------------------------------------------------------------------
info "Removing systemd unit files..."
for unit in borg-backup.service borg-backup.timer borg-test-restore.service borg-test-restore.timer; do
    if [[ -f "/etc/systemd/system/$unit" ]]; then
        rm -f "/etc/systemd/system/$unit"
        REMOVED+=("file: /etc/systemd/system/$unit")
    fi
done
systemctl daemon-reload 2>/dev/null || true
ok "Systemd units removed"

# ---------------------------------------------------------------------------
# Step 3: Delete local borg repository
# ---------------------------------------------------------------------------
if [[ -n "$BORG_REPO" && -d "$BORG_REPO" ]]; then
    info "Local borg repository found at: $BORG_REPO"
    REPO_SIZE=$(du -sh "$BORG_REPO" 2>/dev/null | cut -f1 || echo "unknown")
    echo "  Size: $REPO_SIZE"

    if confirm_danger "Delete local borg repository ($BORG_REPO)?"; then
        rm -rf "$BORG_REPO"
        ok "Local borg repository deleted"
        REMOVED+=("borg repo: $BORG_REPO")
    else
        warn "Kept local borg repository"
        SKIPPED+=("borg repo: $BORG_REPO")
    fi
else
    info "No local borg repository found (BORG_REPO not set or directory missing)"
fi

# ---------------------------------------------------------------------------
# Step 4: Delete cloud backup data
# ---------------------------------------------------------------------------
if [[ -n "$RCLONE_DEST" ]]; then
    info "Cloud backup destination: $RCLONE_DEST"

    if confirm_danger "Delete ALL cloud backup data ($RCLONE_DEST)?"; then
        if rclone purge "$RCLONE_DEST" 2>/dev/null; then
            ok "Cloud backup data deleted"
            REMOVED+=("cloud: $RCLONE_DEST")
        else
            warn "Failed to delete cloud data (may already be empty)"
        fi
    else
        warn "Kept cloud backup data"
        SKIPPED+=("cloud: $RCLONE_DEST")
    fi
else
    info "No cloud destination configured (RCLONE_DEST not set)"
fi

# ---------------------------------------------------------------------------
# Step 5: Remove rclone remote configuration
# ---------------------------------------------------------------------------
info "Checking rclone remotes..."
if rclone listremotes 2>/dev/null | grep -q "^r2:"; then
    if confirm "Remove rclone remote 'r2'?"; then
        rclone config delete r2
        ok "rclone remote 'r2' removed"
        REMOVED+=("rclone remote: r2")
    else
        SKIPPED+=("rclone remote: r2")
    fi
fi
if rclone listremotes 2>/dev/null | grep -q "^gdrive:"; then
    if confirm "Remove rclone remote 'gdrive'?"; then
        rclone config delete gdrive
        ok "rclone remote 'gdrive' removed"
        REMOVED+=("rclone remote: gdrive")
    else
        SKIPPED+=("rclone remote: gdrive")
    fi
fi

# ---------------------------------------------------------------------------
# Step 6: Remove configuration file
# ---------------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
    info "Removing configuration file..."
    if confirm "Delete $ENV_FILE?"; then
        rm -f "$ENV_FILE"
        ok "Configuration removed"
        REMOVED+=("config: $ENV_FILE")
    else
        SKIPPED+=("config: $ENV_FILE")
    fi
fi

# ---------------------------------------------------------------------------
# Step 7: Remove scripts
# ---------------------------------------------------------------------------
info "Removing backup scripts..."
for script in borg-backup.sh borg-test-restore.sh borg-uninstall.sh; do
    if [[ -f "$INSTALL_DIR/$script" ]]; then
        rm -f "$INSTALL_DIR/$script"
        REMOVED+=("script: $INSTALL_DIR/$script")
    fi
done
ok "Scripts removed"

# ---------------------------------------------------------------------------
# Step 8: Remove logs and stamp files
# ---------------------------------------------------------------------------
info "Removing logs and state files..."
for f in /var/log/borg-backup.log /var/log/borg-backup-last-success /var/log/borg-test-restore-last /var/lock/borg-backup.lock; do
    [[ -f "$f" ]] && rm -f "$f" && REMOVED+=("log: $f")
done
[[ -f /etc/logrotate.d/borg-backup ]] && rm -f /etc/logrotate.d/borg-backup && REMOVED+=("logrotate: /etc/logrotate.d/borg-backup")
ok "Logs and state files removed"

# ---------------------------------------------------------------------------
# Step 9: Optionally uninstall packages
# ---------------------------------------------------------------------------
echo ""
if confirm "Uninstall borgbackup package?"; then
    if apt-get remove -y borgbackup 2>/dev/null; then
        REMOVED+=("package: borgbackup")
    fi
fi

if confirm "Uninstall rclone package?"; then
    apt-get remove -y rclone 2>/dev/null || true
    # Also handle curl-installed rclone
    [[ -f /usr/bin/rclone ]] && rm -f /usr/bin/rclone
    [[ -f /usr/local/bin/rclone ]] && rm -f /usr/local/bin/rclone
    REMOVED+=("package: rclone")
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "╔══════════════════════════════════════════════════════════════╗"
info "║  Uninstall complete                                          ║"
info "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [[ ${#REMOVED[@]} -gt 0 ]]; then
    echo "  Removed:"
    for item in "${REMOVED[@]}"; do
        echo "    ✅ $item"
    done
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo ""
    echo "  Kept (skipped):"
    for item in "${SKIPPED[@]}"; do
        echo "    ⏭️  $item"
    done
fi

echo ""
echo "  The system is now clean of backup components."
echo "  If you skipped deleting the borg repo or cloud data,"
echo "  you can remove them manually later."
