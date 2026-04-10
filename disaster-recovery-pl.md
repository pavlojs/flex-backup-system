# Przewodnik Odtwarzania po Awarii

**Napisany dla osób nietechnicznych.** Wykonuj kroki dokładnie tak, jak pokazano.

---

## Spis treści

1. [Słowniczek — Co oznaczają te słowa](#1-słowniczek)
2. [Jak sprawdzić czy backupy działają](#2-jak-sprawdzić-czy-backupy-działają)
3. [Scenariusz A — Przypadkowo usunąłem pliki](#3-scenariusz-a--przypadkowo-usunąłem-pliki)
4. [Scenariusz B — Dysk serwera uległ awarii](#4-scenariusz-b--dysk-serwera-uległ-awarii)
5. [Scenariusz C — Serwer został zhakowany](#5-scenariusz-c--serwer-został-zhakowany)
6. [Scenariusz D — VPS został usunięty / Start od zera](#6-scenariusz-d--vps-został-usunięty--start-od-zera)
7. [Jak usunąć wszystko i wrócić do czystego systemu](#7-jak-usunąć-wszystko)
8. [Ważne ścieżki i pliki](#8-ważne-ścieżki-i-pliki)
9. [Co musisz mieć zapisane](#9-co-musisz-mieć-zapisane)
10. [Kontakty](#10-kontakty)

---

## 1. Słowniczek

| Termin | Co to znaczy |
|--------|-------------|
| **BorgBackup (borg)** | Program tworzący backupy. Zapisuje pliki w specjalnym skompresowanym i zaszyfrowanym formacie. |
| **Archiwum** | Jeden snapshot backupu. Jak zdjęcie wszystkich Twoich plików zrobione w konkretnym momencie. |
| **Repozytorium (repo)** | Miejsce przechowywania wszystkich archiwów. Pomyśl o tym jak o folderze zawierającym wszystkie Twoje "zdjęcia" backupów. |
| **rclone** | Program kopiujący repozytorium do chmury (Cloudflare R2 lub Google Drive). |
| **R2** | Usługa przechowywania w chmurze Cloudflare, gdzie znajduje się kopia zapasowa Twoich backupów. |
| **Passphrase (hasło)** | Hasło szyfrujące Twoje backupy. Bez niego nikt (włącznie z Tobą) nie może ich odczytać. |
| **Klucz borg** | Specjalny plik klucza używany razem z hasłem do odblokowania backupów. Musisz mieć OBYDWA. |

---

## 2. Jak sprawdzić czy backupy działają

### Szybka kontrola (30 sekund)

```bash
# Kiedy był ostatni udany backup?
cat /var/log/borg-backup-last-success
```

Jeśli data jest dzisiejsza lub wczorajsza, backupy działają.

### Szczegółowa kontrola

```bash
# Czy timery są aktywne?
systemctl list-timers borg-*

# Jaki był wynik ostatniego backupu?
systemctl status borg-backup.service

# Wylistuj wszystkie archiwa backupów
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
borg list
```

### Miesięczny test odtwarzania

System automatycznie testuje odtwarzanie 1-go dnia każdego miesiąca i wysyła powiadomienie Gotify. Sprawdź:

```bash
cat /var/log/borg-test-restore-last
```

---

## 3. Scenariusz A — Przypadkowo usunąłem pliki

**Sytuacja**: Serwer działa normalnie, ale przez pomyłkę usunąłeś jakieś pliki.

### Krok 1: Znajdź archiwum z Twoimi plikami

```bash
# Załaduj dane dostępowe
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE

# Wylistuj wszystkie archiwa (najnowsze na końcu)
borg list
```

Zobaczysz coś takiego:

```
myserver-2026-04-08T03:00    Mon, 2026-04-08 03:00:15
myserver-2026-04-09T03:00    Tue, 2026-04-09 03:00:12
myserver-2026-04-10T03:00    Wed, 2026-04-10 03:00:18
```

### Krok 2: Zobacz co jest w archiwum

```bash
# Wylistuj pliki w najnowszym archiwum
borg list ::myserver-2026-04-10T03:00 | grep "szukany-plik"
```

### Krok 3a: Przywróć konkretne pliki

```bash
# Przywróć konkretny plik do tymczasowej lokalizacji
borg extract ::myserver-2026-04-10T03:00 var/lib/docker/volumes/myapp/data/wazny-plik.txt \
    --target /tmp/restored

# Sprawdź plik
ls -la /tmp/restored/var/lib/docker/volumes/myapp/data/wazny-plik.txt

# Skopiuj z powrotem na właściwe miejsce
cp /tmp/restored/var/lib/docker/volumes/myapp/data/wazny-plik.txt \
   /var/lib/docker/volumes/myapp/data/wazny-plik.txt
```

### Krok 3b: Przywróć cały katalog

```bash
# Przywróć cały volume Dockera
borg extract ::myserver-2026-04-10T03:00 var/lib/docker/volumes/myapp \
    --target /tmp/restored

# Skopiuj z powrotem
cp -a /tmp/restored/var/lib/docker/volumes/myapp/* /var/lib/docker/volumes/myapp/
```

### Krok 4: Posprzątaj

```bash
rm -rf /tmp/restored
```

### Krok 5: Zrestartuj kontenery

```bash
docker restart myapp
```

---

## 4. Scenariusz B — Dysk serwera uległ awarii

**Sytuacja**: Serwer działa, ale dysk z danymi jest uszkodzony lub wymieniony. Lokalne repozytorium borg może być zniszczone, ale kopia w chmurze jest bezpieczna.

### Krok 1: Przywróć repozytorium borg z chmury

```bash
# Zainstaluj narzędzia (jeśli jeszcze nie zainstalowane)
apt-get update && apt-get install -y borgbackup rclone

# Odtwórz plik sekretów z menedżera haseł
nano /root/.backup-secrets.env
# (Wklej zawartość zapisaną w menedżerze haseł)
chmod 600 /root/.backup-secrets.env

# Załaduj dane dostępowe
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
```

Skonfiguruj rclone (dla R2):

```bash
rclone config create r2 s3 \
    provider=Cloudflare \
    access_key_id="$R2_ACCESS_KEY_ID" \
    secret_access_key="$R2_SECRET_ACCESS_KEY" \
    endpoint="$R2_ENDPOINT" \
    acl=private \
    no_check_bucket=true
```

Pobierz repozytorium:

```bash
mkdir -p "$BORG_REPO"
rclone sync "$RCLONE_DEST" "$BORG_REPO" --progress
```

### Krok 2: Zaimportuj klucz borg (jeśli potrzebne)

Jeśli klucz borg przepadł razem z dyskiem:

```bash
# Użyj klucza zapisanego w menedżerze haseł
borg key import :: /sciezka/do/zapisanego-klucza
# LUB wklej interaktywnie:
borg key import :: -
# (wklej klucz, potem Ctrl+D)
```

### Krok 3: Zweryfikuj i przywróć

```bash
# Zweryfikuj repozytorium
borg check

# Wylistuj archiwa
borg list

# Przywróć wszystko
borg extract ::NAJNOWSZE_ARCHIWUM --target /
```

### Krok 4: Zrestartuj usługi

```bash
# Zrestartuj kontenery Dockera
docker restart $(docker ps -q)

# Lub uruchom konkretne stacki compose
cd /home/user/apps/mystack && docker compose up -d
```

---

## 5. Scenariusz C — Serwer został zhakowany

**Sytuacja**: Serwer został skompromitowany. Musisz zacząć od nowa i przywrócić dane z backupów.

> ⚠️ **WAŻNE**: NIE przywracaj z lokalnego repozytorium borg — mogło zostać zmodyfikowane przez atakującego. Przywracaj TYLKO z kopii w chmurze (R2 / Google Drive).

### Krok 1: Przygotuj nowy serwer

Zamów nowy VPS (u tego samego lub innego dostawcy — nie ma znaczenia). Zainstaluj Ubuntu 22.04 lub nowszy.

### Krok 2: Zainstaluj narzędzia

```bash
apt-get update
apt-get install -y borgbackup curl
curl -fsSL https://rclone.org/install.sh | bash
```

### Krok 3: Odtwórz sekrety

Z **menedżera haseł** pobierz:
- Zawartość `.backup-secrets.env`
- Klucz repozytorium borg
- Hasło (passphrase) borg

```bash
nano /root/.backup-secrets.env
# (wklej zapisaną konfigurację)
chmod 600 /root/.backup-secrets.env
source /root/.backup-secrets.env && export BORG_REPO BORG_PASSPHRASE
```

### Krok 4: Skonfiguruj rclone i pobierz dane

Dla R2:

```bash
rclone config create r2 s3 \
    provider=Cloudflare \
    access_key_id="$R2_ACCESS_KEY_ID" \
    secret_access_key="$R2_SECRET_ACCESS_KEY" \
    endpoint="$R2_ENDPOINT" \
    acl=private \
    no_check_bucket=true

mkdir -p "$BORG_REPO"
rclone sync "$RCLONE_DEST" "$BORG_REPO" --progress
```

Dla Google Drive:

```bash
rclone config  # Skonfiguruj remote "gdrive" interaktywnie

mkdir -p "$BORG_REPO"
rclone sync "${RCLONE_REMOTE}:${RCLONE_GDRIVE_FOLDER}" "$BORG_REPO" --progress
```

### Krok 5: Zaimportuj klucz borg

```bash
borg key import :: -
# (wklej klucz z menedżera haseł, potem Ctrl+D)
```

### Krok 6: Zweryfikuj repozytorium

```bash
borg check
borg list
```

### Krok 7: Przywróć dane

```bash
# Przywróć volume'y Dockera i dane aplikacji
borg extract ::NAJNOWSZE_ARCHIWUM --target /
```

### Krok 8: Zainstaluj Dockera i uruchom usługi

```bash
# Zainstaluj Dockera
curl -fsSL https://get.docker.com | bash

# Uruchom usługi
cd /home/user/apps/mystack && docker compose up -d
```

### Krok 9: Zainstaluj ponownie system backupu

```bash
git clone https://github.com/pavlojs/flex-backup-system.git
cd flex-backup-system
bash borg-setup.sh  # Lub borg-setup-gdrive.sh
```

### Krok 10: Zmień WSZYSTKIE dane dostępowe

Po włamaniu **zmień wszystko**:
- Klucze API R2 (panel Cloudflare)
- Hasło borg (`borg key change-passphrase`)
- Token Gotify
- Wszystkie hasła aplikacji
- Klucze SSH

---

## 6. Scenariusz D — VPS został usunięty / Start od zera

**Sytuacja**: VPS nie istnieje. Zaczynasz na zupełnie nowym, pustym serwerze.

Wykonaj dokładnie **Scenariusz C** — kroki są identyczne. Jedyna różnica: nie musisz się martwić o skompromitowane dane.

---

## 7. Jak usunąć wszystko

Aby całkowicie usunąć system backupu i wrócić do czystego systemu:

```bash
sudo /root/borg-uninstall.sh
```

Skrypt interaktywnie zapyta o potwierdzenie:
- Zatrzymanie timerów systemd
- Usunięcie lokalnego repozytorium borg
- Usunięcie danych z chmury (R2 / Google Drive)
- Usunięcie plików konfiguracyjnych, skryptów, logów
- Opcjonalne odinstalowanie borgbackup i rclone

Po uruchomieniu serwer nie będzie miał zainstalowanego systemu backupu.

### Ręczne usuwanie (jeśli skrypt uninstall jest niedostępny)

```bash
# Zatrzymaj timery
systemctl stop borg-backup.timer borg-test-restore.timer
systemctl disable borg-backup.timer borg-test-restore.timer

# Usuń pliki systemd
rm -f /etc/systemd/system/borg-backup.{service,timer}
rm -f /etc/systemd/system/borg-test-restore.{service,timer}
systemctl daemon-reload

# Usuń lokalne repozytorium (UWAGA — usuwa wszystkie lokalne backupy!)
rm -rf /var/backups/borg

# Usuń dane z chmury (UWAGA — usuwa wszystkie backupy w chmurze!)
source /root/.backup-secrets.env
rclone purge "$RCLONE_DEST"

# Usuń skrypty i konfigurację
rm -f /root/borg-backup.sh /root/borg-test-restore.sh /root/borg-uninstall.sh
rm -f /root/.backup-secrets.env
rm -f /var/log/borg-backup.log /var/log/borg-backup-last-success /var/log/borg-test-restore-last
rm -f /var/lock/borg-backup.lock
rm -f /etc/logrotate.d/borg-backup

# Opcjonalne usunięcie pakietów
apt-get remove -y borgbackup rclone
```

---

## 8. Ważne ścieżki i pliki

| Ścieżka | Opis |
|---------|------|
| `/root/.backup-secrets.env` | Cała konfiguracja i dane dostępowe |
| `/var/backups/borg/` | Lokalne repozytorium borg (wszystkie dane backupu) |
| `/root/borg-backup.sh` | Główny skrypt backupu |
| `/root/borg-test-restore.sh` | Skrypt miesięcznego testu odtwarzania |
| `/root/borg-uninstall.sh` | Skrypt usuwania |
| `/var/log/borg-backup.log` | Plik logu backupu |
| `/var/log/borg-backup-last-success` | Czas ostatniego udanego backupu |
| `/var/log/borg-test-restore-last` | Czas ostatniego testu odtwarzania |
| `/etc/systemd/system/borg-backup.*` | Usługa i timer systemd |
| `/etc/systemd/system/borg-test-restore.*` | Jednostki systemd testu odtwarzania |

---

## 9. Co musisz mieć zapisane

Aby odzyskać dane po całkowitej utracie, potrzebujesz **trzech rzeczy** zapisanych w menedżerze haseł:

| Element | Dlaczego jest potrzebny | Jak go uzyskać |
|---------|------------------------|----------------|
| **Hasło borg (passphrase)** | Odszyfrowuje wszystkie dane backupu | Z pliku `.backup-secrets.env` |
| **Klucz repozytorium borg** | Wymagany razem z hasłem | `borg key export ::` (wykonane podczas setup) |
| **Zawartość `.backup-secrets.env`** | Dane dostępowe R2/GDrive, konfiguracja backupu | Skopiuj z `/root/.backup-secrets.env` |

> ⚠️ Jeśli stracisz hasło LUB klucz, Twoje backupy **nie mogą zostać odzyskane**. Nie ma opcji resetu ani odzyskiwania. Zapisz obydwa w co najmniej dwóch miejscach.

---

## 10. Kontakty

| Rola | Kontakt |
|------|---------|
| Administrator systemu | *(wpisz swój kontakt)* |
| Odpowiedzialny za backupy | *(wpisz swój kontakt)* |

---

*Ostatnia aktualizacja: kwiecień 2026*
