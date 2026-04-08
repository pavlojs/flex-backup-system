# Disaster Recovery — Przewodnik Odtwarzania Danych

> **Dla kogo jest ten dokument?**
> Dla osoby, która nigdy nie zajmowała się backupami i musi odtworzyć serwer po awarii.
> Czytaj krok po kroku. Nie pomijaj żadnego kroku.

---

## Zanim zaczniesz — co musisz mieć pod ręką

Przed przystąpieniem do odtwarzania upewnij się, że masz dostęp do:

- [ ] Pliku `/root/.backup-secrets.env` (lub jego kopii zapisanej w menedżerze haseł)
- [ ] Hasła do repozytorium restic (pole `RESTIC_PASSWORD` z pliku powyżej)
- [ ] Dostępu do panelu Cloudflare (jako weryfikacja, że dane są tam obecne)
- [ ] Nowego lub odtworzonego serwera z Ubuntu

---

## Słownik — co oznaczają pojęcia

| Słowo | Co to znaczy po ludzku |
|---|---|
| **Restic** | Program, który robił kopie zapasowe. Teraz będzie je odtwarzał. |
| **Snapshot** | Jedna kopia z konkretnego dnia, jak "zdjęcie" serwera w czasie. |
| **Repository** | Miejsce na Cloudflare R2, gdzie przechowywane są wszystkie snapshoty. |
| **R2** | Cloudflare R2 — usługa w chmurze, gdzie fizycznie siedzą dane. |
| **Restore** | Odtworzenie — skopiowanie danych z backupu z powrotem na serwer. |

---

## CZĘŚĆ 1 — Sprawdzenie czy backup w ogóle działa (weryfikacja)

> Wykonaj te kroki gdy **nie ma awarii** — raz w miesiącu, żeby mieć pewność.

### Krok 1.1 — Zaloguj się na serwer

```bash
ssh root@ADRES_SERWERA
```

### Krok 1.2 — Załaduj konfigurację

```bash
source /root/.backup-secrets.env
```

Jeśli to polecenie zwróci błąd, plik sekretów nie istnieje — przejdź do Części 3.

### Krok 1.3 — Wyświetl listę kopii zapasowych

```bash
restic snapshots
```

Powinieneś zobaczyć tabelkę podobną do tej:

```
ID        Time                 Host         Paths
-------------------------------------------------------
a1b2c3d4  2025-01-15 03:00:12  moj-serwer   /var/lib/docker/volumes
e5f6g7h8  2025-01-14 03:00:08  moj-serwer   /var/lib/docker/volumes
```

Każdy wiersz to jedna kopia z jednego dnia. **Jeśli lista jest pusta — backup nie działa.**

### Krok 1.4 — Sprawdź integralność danych

```bash
restic check
```

Na końcu powinno pojawić się: `no errors were found`. Cokolwiek innego — skontaktuj się z administratorem.

---

## CZĘŚĆ 2 — Odtwarzanie po awarii (Disaster Recovery)

### Scenariusz A — Serwer działa, ale skasowałem/nadpisałem pliki

To najprostszy przypadek. Serwer stoi, restic jest zainstalowany.

#### Krok A.1 — Załaduj konfigurację

```bash
source /root/.backup-secrets.env
```

#### Krok A.2 — Znajdź właściwy snapshot

```bash
restic snapshots
```

Zapamiętaj **ID** snapshotu z dnia, z którego chcesz odtworzyć (np. `a1b2c3d4`).
Jeśli chcesz zawsze ostatni, możesz napisać `latest` zamiast konkretnego ID.

#### Krok A.3 — Odtwórz konkretny folder lub plik

Odtworzenie **jednego katalogu** do jego oryginalnej lokalizacji:

```bash
restic restore latest \
  --target / \
  --include /home/pavlojs/apps
```

Odtworzenie **konkretnego pliku** (np. bazy danych):

```bash
restic restore latest \
  --target /tmp/odtworzone \
  --include /var/lib/docker/volumes/moj-kontener/_data/database.db
```

Plik pojawi się w `/tmp/odtworzone/` — możesz go sprawdzić przed przeniesieniem na właściwe miejsce.

#### Krok A.4 — Odtworzenie wszystkiego

```bash
restic restore latest --target /
```

> ⚠️ **Uwaga:** To nadpisze istniejące pliki ich wersjami z backupu. Upewnij się, że tego chcesz.

---

### Scenariusz B — Serwer całkowicie padł, stawiam nowy

#### Krok B.1 — Zainstaluj system i podstawowe narzędzia

Na świeżym Ubuntu:

```bash
apt-get update && apt-get install -y restic
```

#### Krok B.2 — Odtwórz plik sekretów

Musisz ręcznie stworzyć plik `/root/.backup-secrets.env` z danymi, które miałeś zapisane w bezpiecznym miejscu:

```bash
nano /root/.backup-secrets.env
```

Wklej zawartość (patrz szablon w tym repozytorium: `backup-secrets.env.template`) i uzupełnij prawdziwe wartości.

```bash
chmod 600 /root/.backup-secrets.env
source /root/.backup-secrets.env
```

#### Krok B.3 — Zweryfikuj dostęp do backupu

```bash
restic snapshots
```

Jeśli widzisz listę snapshotów — dane są bezpieczne i gotowe do odtworzenia.

#### Krok B.4 — Odtwórz dane

```bash
restic restore latest --target /
```

#### Krok B.5 — Uruchom Dockera i kontenery

```bash
apt-get install -y docker.io docker-compose
cd /home/pavlojs/apps
docker-compose up -d
```

#### Krok B.6 — Zainstaluj ponownie skrypt backupu

```bash
cp /home/pavlojs/apps/backup/restic-backup.sh /root/restic-backup.sh
chmod 700 /root/restic-backup.sh
```

Wybierz **jedną** z opcji schedulowania:

**Opcja A — Cron:**
```bash
(crontab -l 2>/dev/null; echo "0 3 * * * /root/restic-backup.sh") | crontab -
```

**Opcja B — Systemd timer:**
```bash
cp /home/pavlojs/apps/backup/systemd/restic-backup.service /etc/systemd/system/
cp /home/pavlojs/apps/backup/systemd/restic-backup.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now restic-backup.timer

# Sprawdź czy timer jest aktywny:
systemctl list-timers restic-backup.timer
```

---

## CZĘŚĆ 3 — Gdy coś nie działa — diagnostyka

### Problem: `source /root/.backup-secrets.env` zwraca błąd "No such file"

Plik sekretów zaginął. Musisz go odtworzyć z kopii (menedżer haseł, inny serwer).
Bez tego pliku **nie możesz odtworzyć danych** — dlatego trzymaj go w co najmniej dwóch miejscach.

### Problem: `restic snapshots` zwraca błąd autoryzacji

Prawdopodobna przyczyna: zmienił się klucz API w Cloudflare lub token wygasł.

1. Zaloguj się do [dash.cloudflare.com](https://dash.cloudflare.com)
2. Przejdź do **R2 → Manage R2 API Tokens**
3. Utwórz nowy token z uprawnieniami `Object Read & Write`
4. Zaktualizuj `/root/.backup-secrets.env`

### Problem: `restic check` wykazuje błędy

```bash
restic rebuild-index
restic check
```

Jeśli błędy nadal są, uruchom:

```bash
restic repair snapshots --forget
```

### Problem: Backup od kilku dni nie działa (brak powiadomień Gotify)

Sprawdź log:

```bash
tail -50 /var/log/restic-backup.log
```

Sprawdź czy cron lub systemd timer działa:

```bash
# Jeśli używasz crona:
crontab -l
systemctl status cron

# Jeśli używasz systemd timer:
systemctl list-timers restic-backup.timer
systemctl status restic-backup.service
journalctl -u restic-backup.service -n 50
```

Uruchom ręcznie:

```bash
# Cron / bezpośrednio:
/root/restic-backup.sh

# Systemd:
systemctl start restic-backup.service
```

---

## CZĘŚĆ 4 — Harmonogram backupów

| Typ | Ile przechowywane | Co to znaczy |
|---|---|---|
| Dzienne | 5 ostatnich dni | Możesz cofnąć się o max 5 dni |
| Tygodniowe | 1 (ostatni tydzień) | Jedna kopia z poprzedniego tygodnia |
| Miesięczne | 1 (ostatni miesiąc) | Jedna kopia z poprzedniego miesiąca |

> Backup uruchamia się automatycznie **codziennie o 3:00 w nocy**.
> Po każdym udanym lub nieudanym backupie przychodzi powiadomienie na Gotify.

---

## CZĘŚĆ 5 — Ważne ścieżki i pliki

| Co | Gdzie |
|---|---|
| Skrypt backupu (R2) | `/root/restic-backup.sh` |
| Skrypt backupu (Google Drive) | `/root/restic-backup-gdrive.sh` |
| Plik sekretów (R2) | `/root/.backup-secrets.env` |
| Plik sekretów (Google Drive) | `/root/.backup-secrets-gdrive.env` |
| Log backupu (R2) | `/var/log/restic-backup.log` |
| Log backupu (Google Drive) | `/var/log/restic-backup-gdrive.log` |
| Systemd service (R2) | `/etc/systemd/system/restic-backup.service` |
| Systemd timer (R2) | `/etc/systemd/system/restic-backup.timer` |
| Systemd service (Google Drive) | `/etc/systemd/system/restic-backup-gdrive.service` |
| Systemd timer (Google Drive) | `/etc/systemd/system/restic-backup-gdrive.timer` |
| Rclone config | `~/.config/rclone/rclone.conf` |
| Dane Docker | `/var/lib/docker/volumes` |
| Aplikacje | `/home/pavlojs/apps` |

---

## CZĘŚĆ 6 — Kontakty i eskalacja

> Uzupełnij tę sekcję własnymi danymi.

| Rola | Imię | Kontakt |
|---|---|---|
| Administrator serwera | | |
| Właściciel konta Cloudflare | | |
| Backup kontakt (gdy admin niedostępny) | | |

---

## CZĘŚĆ 7 — Google Drive Backend (opcjonalnie)

> Jeśli backup korzysta z Google Drive zamiast (lub oprócz) Cloudflare R2.

### Plik sekretów Google Drive

Plik: `/root/.backup-secrets-gdrive.env`

Skrypt: `/root/restic-backup-gdrive.sh`

Log: `/var/log/restic-backup-gdrive.log`

### Odtwarzanie z Google Drive

Procedura jest **identyczna** jak dla R2. Jedyna różnica to plik sekretów:

```bash
# Zamiast:
source /root/.backup-secrets.env

# Użyj:
source /root/.backup-secrets-gdrive.env
```

Reszta komend restic (`snapshots`, `restore`, `check`) działa tak samo.

### Problem: Rclone nie łączy się z Google Drive

Odśwież autoryzację:

```bash
rclone config reconnect gdrive:
```

Na serwerze bez przeglądarki:
1. Na komputerze z przeglądarką uruchom: `rclone authorize "drive"`
2. Zaloguj się do Google
3. Skopiuj token z powrotem na serwer

### Problem: `RESTIC_REPOSITORY` wskazuje na rclone, ale rclone nie jest zainstalowany

```bash
curl https://rclone.org/install.sh | bash
```

Sprawdź konfigurację:

```bash
rclone listremotes
rclone lsd gdrive:restic-backup
```

---

*Dokument wygenerowany automatycznie. Ostatnia aktualizacja konfiguracji: sprawdź datę ostatniego snapshotu (`restic snapshots`).*
