#!/usr/bin/env bash
# =============================================================================
# Flex Backup System — Setup (Google Drive backend)
# =============================================================================
# One-time setup: installs borgbackup + rclone, configures Google Drive remote,
# initialises borg repository, installs systemd timers.
# Run as root on a fresh server.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_DEST="/root/.backup-secrets.env"
INSTALL_DIR="/root"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
die()   { err "$@"; exit 1; }

confirm() {
    read -rp "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "This script must be run as root."

info "=== Flex Backup System — Google Drive Setup ==="

# ---------------------------------------------------------------------------
# Step 1: Install borgbackup
# ---------------------------------------------------------------------------
info "Installing borgbackup..."
if command -v borg &>/dev/null; then
    ok "borgbackup already installed: $(borg --version)"
else
    apt-get update -qq
    apt-get install -y -qq borgbackup
    ok "borgbackup installed: $(borg --version)"
fi

# ---------------------------------------------------------------------------
# Step 2: Install rclone
# ---------------------------------------------------------------------------
info "Installing rclone..."
if command -v rclone &>/dev/null; then
    ok "rclone already installed: $(rclone version --check 2>/dev/null | head -1 || rclone version | head -1)"
else
    curl -fsSL https://rclone.org/install.sh | bash
    ok "rclone installed: $(rclone version | head -1)"
fi

# ---------------------------------------------------------------------------
# Step 3: Configure rclone remote "gdrive"
# ---------------------------------------------------------------------------
info "Configuring rclone remote for Google Drive..."
echo ""
echo "  You will now run 'rclone config' interactively."
echo "  Create a new remote with these settings:"
echo ""
echo "    Name:    gdrive"
echo "    Type:    drive  (Google Drive)"
echo "    Scope:   drive  (full access)"
echo ""
echo "  If this is a headless server (no browser), rclone will give you"
echo "  a URL to visit on another machine for OAuth authentication."
echo ""
read -rp "Press Enter to start rclone config..."

rclone config

# Verify the remote was created
if rclone listremotes | grep -q "^gdrive:"; then
    ok "rclone remote 'gdrive' configured"
else
    die "rclone remote 'gdrive' not found. Please re-run setup and create a remote named 'gdrive'."
fi

# ---------------------------------------------------------------------------
# Step 4: Copy secrets template
# ---------------------------------------------------------------------------
info "Setting up configuration..."
if [[ -f "$ENV_DEST" ]]; then
    warn "Config already exists at $ENV_DEST"
    if ! confirm "Overwrite existing config?"; then
        info "Keeping existing config."
    else
        cp "$SCRIPT_DIR/backup-secrets-gdrive.env.template" "$ENV_DEST"
        chmod 600 "$ENV_DEST"
        ok "Config copied to $ENV_DEST"
    fi
else
    cp "$SCRIPT_DIR/backup-secrets-gdrive.env.template" "$ENV_DEST"
    chmod 600 "$ENV_DEST"
    ok "Config copied to $ENV_DEST"
fi

# ---------------------------------------------------------------------------
# Step 5: Edit configuration
# ---------------------------------------------------------------------------
info "You MUST edit $ENV_DEST with your settings before continuing."
echo ""
echo "  Required fields:"
echo "    BORG_PASSPHRASE  — Strong password (min 20 chars)"
echo "    BACKUP_PATHS     — Space-separated list of paths to back up"
echo ""
echo "  Optional:"
echo "    RCLONE_REMOTE         — rclone remote name (default: gdrive)"
echo "    RCLONE_GDRIVE_FOLDER  — Google Drive folder (default: borg-backup)"
echo "    GOTIFY_URL / GOTIFY_TOKEN — for push notifications"
echo ""

if confirm "Open $ENV_DEST in \$EDITOR now?"; then
    "${EDITOR:-nano}" "$ENV_DEST"
fi

echo ""
read -rp "Press Enter when you have finished editing $ENV_DEST..."

# ---------------------------------------------------------------------------
# Step 6: Load and validate config
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$ENV_DEST"

for var in BORG_REPO BORG_PASSPHRASE BACKUP_PATHS; do
    if [[ -z "${!var:-}" ]]; then
        die "Required variable $var is empty in $ENV_DEST"
    fi
done
ok "Configuration validated"

# ---------------------------------------------------------------------------
# Step 7: Create Google Drive folder
# ---------------------------------------------------------------------------
info "Creating Google Drive folder: ${RCLONE_GDRIVE_FOLDER:-borg-backup}"
rclone mkdir "${RCLONE_REMOTE:-gdrive}:${RCLONE_GDRIVE_FOLDER:-borg-backup}" 2>/dev/null || true
ok "Google Drive folder ready"

# ---------------------------------------------------------------------------
# Step 8: Initialize borg repository
# ---------------------------------------------------------------------------
info "Initializing borg repository at $BORG_REPO"

export BORG_REPO BORG_PASSPHRASE

if [[ -d "$BORG_REPO" ]] && borg list &>/dev/null; then
    warn "Borg repository already initialized at $BORG_REPO"
else
    mkdir -p "$BORG_REPO"
    borg init --encryption=repokey-blake2
    ok "Borg repository initialized"
fi

# ---------------------------------------------------------------------------
# Step 9: Export borg key (CRITICAL!)
# ---------------------------------------------------------------------------
info "╔══════════════════════════════════════════════════════════════╗"
info "║  CRITICAL: Save your borg repository key!                  ║"
info "║  Without this key + passphrase, your backups are LOST.     ║"
info "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "--- BEGIN BORG KEY ---"
borg key export :: 2>/dev/null || borg key export "$BORG_REPO"
echo ""
echo "--- END BORG KEY ---"
echo ""
echo "⚠️  Copy this key and store it in your password manager!"
echo "⚠️  Also save your BORG_PASSPHRASE separately."
echo ""
read -rp "Press Enter after you have saved the key..."

# ---------------------------------------------------------------------------
# Step 10: Install scripts
# ---------------------------------------------------------------------------
info "Installing scripts to $INSTALL_DIR"

for script in borg-backup.sh borg-test-restore.sh borg-uninstall.sh; do
    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/$script"
        chmod 700 "$INSTALL_DIR/$script"
        ok "Installed $script"
    else
        warn "Script not found: $SCRIPT_DIR/$script"
    fi
done

# ---------------------------------------------------------------------------
# Step 11: Install systemd units
# ---------------------------------------------------------------------------
info "Installing systemd timers..."

for unit in borg-backup.service borg-backup.timer borg-test-restore.service borg-test-restore.timer; do
    if [[ -f "$SCRIPT_DIR/systemd/$unit" ]]; then
        cp "$SCRIPT_DIR/systemd/$unit" "/etc/systemd/system/$unit"
        ok "Installed $unit"
    else
        warn "Unit file not found: $SCRIPT_DIR/systemd/$unit"
    fi
done

systemctl daemon-reload
systemctl enable --now borg-backup.timer
systemctl enable --now borg-test-restore.timer
ok "Systemd timers enabled"

echo ""
echo "  borg-backup.timer         → daily at 03:00"
echo "  borg-test-restore.timer   → monthly on the 1st at 04:00"
echo ""
systemctl list-timers borg-*

# ---------------------------------------------------------------------------
# Step 12: Configure logrotate
# ---------------------------------------------------------------------------
info "Configuring log rotation..."
cat > /etc/logrotate.d/borg-backup << 'EOF'
/var/log/borg-backup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
EOF
ok "Logrotate configured for /var/log/borg-backup.log"

# ---------------------------------------------------------------------------
# Step 13: Run first backup (optional)
# ---------------------------------------------------------------------------
echo ""
if confirm "Run the first backup now?"; then
    info "Running first backup..."
    "$INSTALL_DIR/borg-backup.sh"
    ok "First backup completed!"
else
    info "You can run it manually: $INSTALL_DIR/borg-backup.sh"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
info "╔══════════════════════════════════════════════════════════════╗"
info "║  Setup complete!                                           ║"
info "╠══════════════════════════════════════════════════════════════╣"
info "║  Config:    $ENV_DEST"
info "║  Borg repo: $BORG_REPO"
info "║  Cloud:     ${RCLONE_REMOTE:-gdrive}:${RCLONE_GDRIVE_FOLDER:-borg-backup}"
info "║  Logs:      /var/log/borg-backup.log"
info "║  Manual:    $INSTALL_DIR/borg-backup.sh"
info "║  Uninstall: $INSTALL_DIR/borg-uninstall.sh"
info "╚══════════════════════════════════════════════════════════════╝"
