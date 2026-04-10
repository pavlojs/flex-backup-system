# Security Model

This document describes the security architecture of the Flex Backup System.

## Encryption

### BorgBackup encryption

All backup data is encrypted **before** leaving the server using BorgBackup's `repokey-blake2` encryption mode:

- **Algorithm**: AES-256-CTR + BLAKE2b-256 (HMAC)
- **Key derivation**: Argon2 from your passphrase
- **Scope**: All file data, metadata, names, and directory structures are encrypted
- **Location**: The encryption key is stored inside the borg repository, protected by your passphrase

### What this means

- Data at rest in `/var/backups/borg` is encrypted
- Data uploaded to R2 / Google Drive is encrypted
- Without both the **borg key** and **passphrase**, data cannot be recovered
- Cloudflare / Google cannot read your backup contents

### Key management

| Component | Where stored | How to back up |
|-----------|-------------|----------------|
| Borg passphrase | `/root/.backup-secrets.env` | Password manager |
| Borg repo key | Inside `$BORG_REPO` | `borg key export` → password manager |

**Export your key:**

```bash
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
borg key export ::
```

Store the exported key in your password manager alongside the passphrase. **If you lose either one, your backups are irrecoverable.**

## Secrets Management

### Secrets file

All credentials are stored in a single file: `/root/.backup-secrets.env`

| Secret | Purpose |
|--------|---------|
| `R2_ACCESS_KEY_ID` | Cloudflare R2 API access |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 API secret |
| `BORG_PASSPHRASE` | Encrypts/decrypts backup data |
| `GOTIFY_TOKEN` | Push notification auth |

### File permissions

```
/root/.backup-secrets.env    600  root:root  (owner read/write only)
/root/borg-backup.sh         700  root:root  (owner execute only)
/root/borg-test-restore.sh   700  root:root
/root/borg-uninstall.sh      700  root:root
/var/backups/borg/            700  root:root  (borg repository)
```

### What is NOT encrypted

| Component | Encrypted? | Risk |
|-----------|-----------|------|
| Backup data (borg archive) | ✅ AES-256 | — |
| Secrets file on disk | ❌ Plaintext | Protected by file permissions (600) |
| Backup log | ❌ Plaintext | Contains timestamps and sizes, no content |
| Gotify notifications | ❌ HTTPS transport only | Contains archive names and sizes |
| rclone config | ❌ Plaintext | Contains R2/GDrive credentials |

## Systemd Hardening

The backup service runs with these security restrictions:

```ini
PrivateTmp=true         # Isolated /tmp namespace
ProtectSystem=full      # /usr, /boot, /efi are read-only
NoNewPrivileges=true    # Cannot escalate privileges (no setuid)
Nice=10                 # Lower CPU priority
CPUQuota=50%            # CPU usage cap
IOSchedulingPriority=7  # Low I/O priority
```

`ProtectSystem=full` (not `strict`) is used because backup paths are dynamic and configured in the env file.

## Network Security

| Connection | Protocol | Purpose |
|-----------|----------|---------|
| Server → R2 | HTTPS (TLS 1.2+) | rclone sync upload |
| Server → Google Drive | HTTPS (OAuth 2.0) | rclone sync upload |
| Server → Gotify | HTTPS | Push notifications |

No inbound connections are required. All traffic is outbound only.

## Git Repository Safety

The `.gitignore` prevents accidental commit of secrets:

```
*.env
!*.env.template
```

Only `.env.template` files (without credentials) are tracked in git.

## Threat Model

| Threat | Mitigation |
|--------|-----------|
| R2/GDrive account compromised | Backup data is AES-256 encrypted — attacker gets ciphertext only |
| Server root compromised | Attacker has access to passphrase in env file. Rotate passphrase, re-key borg repo, rotate R2 API keys |
| Backup data tampered in cloud | `borg check` verifies integrity; monthly restore test detects corruption |
| Passphrase lost | **Unrecoverable** — store in password manager |
| Borg key lost | **Unrecoverable** — export and store during setup |
| rclone credentials leak | Rotate R2 API tokens immediately; re-run rclone config for GDrive |

## Credential Rotation

### Rotate R2 API keys

1. Create new API token in Cloudflare dashboard
2. Update `/root/.backup-secrets.env`
3. Reconfigure rclone: `rclone config update r2 access_key_id=NEW secret_access_key=NEW`
4. Revoke old token in Cloudflare

### Rotate borg passphrase

1. `borg key change-passphrase`
2. Update `BORG_PASSPHRASE` in `/root/.backup-secrets.env`
3. Export new key: `borg key export ::`
4. Update password manager

### Rotate Gotify token

1. Create new app token in Gotify UI
2. Update `GOTIFY_TOKEN` in `/root/.backup-secrets.env`
3. Delete old token in Gotify UI
