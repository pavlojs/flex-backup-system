# Security Policy

## ⚠️ Project Status

This project is in **active development and testing**. Security practices described below are goals and guidelines — review the code yourself before trusting it with sensitive infrastructure.

---

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please **do not** open a public issue.

Instead, report it privately:

1. **Email**: Send details to the repository owner (see profile)
2. **GitHub**: Use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) if enabled

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge your report within **48 hours** and aim to provide a fix or mitigation within **7 days**.

---

## Security Model

### What This Project Encrypts

- All backup data is encrypted **client-side** using AES-256 (via restic) before leaving your server
- The encryption key is derived from `RESTIC_PASSWORD`
- Neither Cloudflare R2 nor Google Drive can read your backup contents

### What This Project Does NOT Encrypt

- **The secrets file** (`/root/.backup-secrets.env`) is stored in plaintext on disk
- **Log files** (`/var/log/restic-backup.log`) may contain file paths (but not file contents)
- **Gotify notifications** are sent over HTTPS but contain hostnames and status info
- **Cron/systemd environment** — environment variables are visible to root processes

---

## Secrets Management

### Storage

| Secret | Where it lives | Protection |
|--------|---------------|------------|
| `RESTIC_PASSWORD` | `/root/.backup-secrets.env` | `chmod 600` (root-only read) |
| `AWS_ACCESS_KEY_ID` | `/root/.backup-secrets.env` | `chmod 600` (root-only read) |
| `AWS_SECRET_ACCESS_KEY` | `/root/.backup-secrets.env` | `chmod 600` (root-only read) |
| `GOTIFY_TOKEN` | `/root/.backup-secrets.env` | `chmod 600` (root-only read) |
| Rclone OAuth token | `~/.config/rclone/rclone.conf` | Default file permissions |

### Best Practices

1. **Never commit secrets to git** — `.gitignore` blocks `*.env` files, but always verify
2. **Store `RESTIC_PASSWORD` in a password manager** — if you lose it, your backups are **permanently unrecoverable**
3. **Store a copy of the secrets file** in at least two separate secure locations (password manager, encrypted USB, printed in a safe)
4. **Use unique, strong passwords** — minimum 20 characters for `RESTIC_PASSWORD`
5. **Scope API tokens narrowly**:
   - Cloudflare R2: Scope to specific bucket, `Object Read & Write` only
   - Google Drive: Consider using a dedicated Google account

### Rotation

- **Cloudflare R2 tokens**: Rotate periodically via [Cloudflare dashboard](https://dash.cloudflare.com) → R2 → Manage API Tokens
- **Restic password**: Can be changed with `restic key passwd` (requires current password)
- **Gotify tokens**: Regenerate in Gotify web UI if compromised
- **Rclone/Google Drive**: Run `rclone config reconnect gdrive:` to re-authorize

---

## File Permissions

The setup scripts enforce these permissions:

| File | Permission | Meaning |
|------|-----------|---------|
| `/root/.backup-secrets.env` | `600` | Owner (root) read/write only |
| `/root/.backup-secrets-gdrive.env` | `600` | Owner (root) read/write only |
| `/root/restic-backup.sh` | `700` | Owner (root) read/write/execute only |
| `/root/restic-backup-gdrive.sh` | `700` | Owner (root) read/write/execute only |

Verify with:
```bash
ls -la /root/.backup-secrets*.env /root/restic-backup*.sh
```

---

## Systemd Security Hardening

When using the systemd timer (instead of cron), the service unit includes:

| Directive | Purpose |
|-----------|---------|
| `PrivateTmp=true` | Isolates `/tmp` from other processes |
| `ProtectSystem=strict` | Makes filesystem read-only except allowed paths |
| `ReadWritePaths=` | Explicitly whitelists only needed paths |
| `NoNewPrivileges=true` | Prevents privilege escalation |
| `CPUQuota=50%` | Limits CPU usage to avoid starving other services |
| `Nice=10` | Lower scheduling priority |
| `IOSchedulingPriority=7` | Lower I/O priority |

---

## Network Security

### Outbound Connections

The backup scripts connect to:

| Destination | Protocol | Purpose |
|-------------|----------|---------|
| `*.r2.cloudflarestorage.com` | HTTPS (443) | R2 backup data transfer |
| Google Drive API | HTTPS (443) | Google Drive backup (via rclone) |
| Gotify server | HTTPS (443) | Push notifications |

### Recommendations

- Use a firewall to restrict outbound traffic to only necessary destinations
- Ensure your Gotify instance uses HTTPS with a valid certificate
- If using Google Drive on a server, consider a service account instead of personal OAuth

---

## Git Repository Safety

### `.gitignore` Rules

The repository `.gitignore` prevents accidental commits of:

```
*.env           # All environment/secrets files
!*.env.template # Except templates (safe — contain placeholders only)
*.log           # Log files
```

### Pre-push Checklist

Before pushing changes, verify no secrets are staged:

```bash
git diff --cached --name-only | grep -E '\.(env|log)$'
```

If any matches appear, unstage them:

```bash
git reset HEAD <filename>
```

### If Secrets Were Accidentally Committed

1. **Immediately rotate all exposed credentials** (R2 keys, Gotify tokens, etc.)
2. Remove from git history:
   ```bash
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch .backup-secrets.env" \
     --prune-empty --tag-name-filter cat -- --all
   git push --force
   ```
3. Consider using [BFG Repo Cleaner](https://rclone.github.io/bfg-repo-cleaner/) for simpler cleanup

---

## Threat Model

| Threat | Mitigation | Residual Risk |
|--------|-----------|---------------|
| Cloud provider reads your data | AES-256 client-side encryption | None — data is encrypted before upload |
| Cloud provider deletes your data | Use both backends (R2 + Google Drive) | Low — two independent providers |
| Server compromised — attacker reads secrets | `chmod 600` on secrets file | Medium — root access = game over |
| Server compromised — attacker deletes backups | Cloud-side versioning / object lock (R2) | Medium — attacker with secrets can delete remote backups |
| Lost `RESTIC_PASSWORD` | Store in 2+ secure locations | **Critical** — loss = permanent data loss |
| Man-in-the-middle | All connections use HTTPS/TLS | Low |
| Backup script modified by attacker | `chmod 700`, systemd `ProtectSystem` | Medium — requires root |

### Recommendations for High-Security Environments

- Enable **R2 Object Lock** to prevent backup deletion even with valid credentials
- Use a **dedicated backup user** instead of root where possible
- Set up **append-only mode** in restic (`--append-only` on the REST server, if applicable)
- Monitor backup logs and Gotify alerts — a missing alert is itself an alert
- Regularly test restores (monthly recommended)

---

## Dependencies

| Dependency | Source | Verification |
|------------|--------|-------------|
| restic | [github.com/restic/restic](https://github.com/restic/restic) | Official releases, SHA256 checksums |
| rclone | [rclone.org](https://rclone.org) | Official install script |
| awscli | Ubuntu/Debian apt repository | Distro-maintained package |
| curl | Ubuntu/Debian apt repository | Distro-maintained package |

Always prefer installing from official sources and verify checksums when possible.

---

## Contact

For security concerns, reach out to the repository owner via GitHub.
