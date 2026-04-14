#!/usr/bin/env bash
# =============================================================================
# Flex Backup System — Setup (Cloudflare R2 backend)
# =============================================================================
# One-time setup: installs borgbackup + rclone, configures R2 remote,
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

info "=== Flex Backup System — R2 Setup ==="

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
# Step 3: Copy secrets template
# ---------------------------------------------------------------------------
info "Setting up configuration..."
if [[ -f "$ENV_DEST" ]]; then
    warn "Config already exists at $ENV_DEST"
    if ! confirm "Overwrite existing config?"; then
        info "Keeping existing config."
    else
        cp "$SCRIPT_DIR/backup-secrets.env.template" "$ENV_DEST"
        chmod 600 "$ENV_DEST"
        ok "Config copied to $ENV_DEST"
    fi
else
    cp "$SCRIPT_DIR/backup-secrets.env.template" "$ENV_DEST"
    chmod 600 "$ENV_DEST"
    ok "Config copied to $ENV_DEST"
fi

# ---------------------------------------------------------------------------
# Step 4: Edit configuration
# ---------------------------------------------------------------------------
info "You MUST edit $ENV_DEST with your R2 credentials before continuing."
echo ""
echo "  Required fields:"
echo "    R2_ACCESS_KEY_ID      — Cloudflare R2 access key"
echo "    R2_SECRET_ACCESS_KEY  — Cloudflare R2 secret key"
echo "    R2_ENDPOINT           — https://<account-id>.r2.cloudflarestorage.com"
echo "    BORG_PASSPHRASE       — Strong password (min 20 chars)"
echo "    BACKUP_PATHS          — Space-separated list of paths to back up"
echo ""
echo "  Optional:"
echo "    GOTIFY_URL / GOTIFY_TOKEN — for push notifications"
echo ""

if confirm "Open $ENV_DEST in \$EDITOR now?"; then
    "${EDITOR:-nano}" "$ENV_DEST"
fi

echo ""
read -rp "Press Enter when you have finished editing $ENV_DEST..."

# ---------------------------------------------------------------------------
# Step 5: Load and validate config
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$ENV_DEST"

for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT BORG_REPO BORG_PASSPHRASE BACKUP_PATHS; do
    if [[ -z "${!var:-}" ]]; then
        die "Required variable $var is empty in $ENV_DEST"
    fi
done
ok "Configuration validated"

# ---------------------------------------------------------------------------
# Step 6: Configure rclone remote "r2"
# ---------------------------------------------------------------------------
info "Configuring rclone remote 'r2' for Cloudflare R2..."

# Remove existing r2 remote if present
rclone config delete r2 2>/dev/null || true

rclone config create r2 s3 \
    provider="Cloudflare" \
    access_key_id="$R2_ACCESS_KEY_ID" \
    secret_access_key="$R2_SECRET_ACCESS_KEY" \
    endpoint="$R2_ENDPOINT" \
    acl="private" \
    no_check_bucket="true"

ok "rclone remote 'r2' configured"

# ---------------------------------------------------------------------------
# Step 7: Verify R2 bucket exists (connectivity test)
# ---------------------------------------------------------------------------
info "Verifying R2 bucket: ${R2_BUCKET:-borg-backup}"
echo ""
warn "⚠  Cloudflare R2 does NOT support creating buckets via S3 API"
warn "   for EU jurisdiction. The bucket must already exist."
warn "   Create it manually: Cloudflare Dashboard → R2 → Create bucket"
echo ""

# Write a small test file to verify connectivity
TEST_FILE=$(mktemp)
echo "flex-backup-system connectivity test $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TEST_FILE"

if rclone copyto "$TEST_FILE" "r2:${R2_BUCKET:-borg-backup}/.flex-backup-test" 2>&1; then
    rclone deletefile "r2:${R2_BUCKET:-borg-backup}/.flex-backup-test" 2>/dev/null || true
    rm -f "$TEST_FILE"
    ok "R2 bucket verified — write test passed"
else
    rm -f "$TEST_FILE"
    echo ""
    err "Cannot write to R2 bucket '${R2_BUCKET:-borg-backup}'."
    err "Possible causes:"
    err "  1. Bucket does not exist — create it in Cloudflare Dashboard"
    err "  2. Wrong R2_ENDPOINT (check account ID)"
    err "  3. API token lacks write permissions"
    die "Fix the issue above and re-run setup."
fi

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

for script in backup.sh test-restore.sh uninstall.sh; do
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

for unit in backup.service backup.timer test-restore.service test-restore.timer; do
    if [[ -f "$SCRIPT_DIR/systemd/$unit" ]]; then
        cp "$SCRIPT_DIR/systemd/$unit" "/etc/systemd/system/$unit"
        ok "Installed $unit"
    else
        warn "Unit file not found: $SCRIPT_DIR/systemd/$unit"
    fi
done

systemctl daemon-reload
systemctl enable --now backup.timer
systemctl enable --now test-restore.timer
ok "Systemd timers enabled"

echo ""
echo "  backup.timer     → daily at 03:00"
echo "  test-restore.timer → monthly on the 1st at 04:00"
echo ""
systemctl list-timers borg-*

# ---------------------------------------------------------------------------
# Step 12: Configure logrotate
# ---------------------------------------------------------------------------
info "Configuring log rotation..."
cat > /etc/logrotate.d/backup << 'EOF'
/var/log/backup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
EOF
ok "Logrotate configured for /var/log/backup.log"

# ---------------------------------------------------------------------------
# Step 13: Run first backup (optional)
# ---------------------------------------------------------------------------
echo ""
if confirm "Run the first backup now?"; then
    info "Running first backup..."
    "$INSTALL_DIR/backup.sh"
    ok "First backup completed!"
else
    info "You can run it manually: $INSTALL_DIR/backup.sh"
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
info "║  Cloud:     r2:${R2_BUCKET:-borg-backup}"
info "║  Logs:      /var/log/backup.log"
info "║  Manual:    $INSTALL_DIR/backup.sh"
info "║  Uninstall: $INSTALL_DIR/uninstall.sh"
info "╚══════════════════════════════════════════════════════════════╝"
