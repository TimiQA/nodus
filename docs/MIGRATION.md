# Переезд и обновление

## Переезд на новый VPS (из бэкапа)

Домен остаётся тем же — на нём держатся аккаунты (`@user:домен`), сменить его нельзя.

1. **На старом сервере** сделай свежий бэкап и скачай его к себе вместе с `.sha256`:
   ```bash
   nodus-backup          # или nodus → «полный бэкап»
   ```
   Файл: `/root/backups/nodus-backup-<host>-<дата>.tar`.
2. **Останови Matrix на старом сервере** (`docker stop matrix-conduit`), чтобы в обоих местах не было разных версий базы.
3. **Поменяй A-запись** домена на IP нового сервера. Подожди, пока DNS обновится (`dig +short домен`).
4. **На новом сервере** (чистый Debian) закинь бэкап и `.sha256` в `/root/` по SFTP и запусти:
   ```bash
   curl -sSL https://raw.githubusercontent.com/TimiQA/nodus/main/setup.sh | sudo bash
   ```
   → «2) восстановить из бэкапа». Скрипт:
   - проверит sha256 бэкапа и файлов внутри;
   - спросит новый IP, какие звонки оставить, свободен ли 443;
   - возьмёт из бэкапа `conduit.toml` (токен регистрации, TURN-секрет, настройки медиа), `coturn.conf`, `element-config.json` и базу;
   - сертификат возьмёт из бэкапа, если он ещё действует, иначе выпустит новый;
   - nginx и docker-compose сгенерирует заново под новый сервер;
   - новые звонки (LiveKit) поставит заново со свежими ключами.
5. Проверь: `nodus status`, вход в Element X и звонок.

Сначала можно посмотреть план без изменений: `setup.sh --restore /root/nodus-backup-....tar --check`.

**Что `setup.sh` НЕ восстанавливает** — всё, что не относится к Matrix (VPN, свои скрипты, SSH-ключи,
данные других контейнеров). Список путей в бэкапе — `configs-list.txt`. Вернуть руками:
```bash
mkdir /root/bk && tar -C /root/bk -xf /root/nodus-backup-....tar
tar -C / -xzf /root/bk/configs.tar.gz etc/нужная/папка
```

## Сервер, поставленный до v2

На сервер, который ставился v1 или настраивался руками, переставлять ничего не нужно.

1. Сверка — ничего не меняет:
   ```bash
   curl -sSL https://raw.githubusercontent.com/TimiQA/nodus/main/setup.sh | sudo bash -s -- --compare
   ```
   Ожидаемые отличия: `http2 on` в nginx, `no-cli` в coturn, комментарии в файлах LiveKit.
2. Поставить `nodus` и `nodus-backup` из репо (конфиги и контейнеры не трогаются):
   ```bash
   curl -sSL https://raw.githubusercontent.com/TimiQA/nodus/main/setup.sh | sudo bash -s -- --tools
   ```
   Если у тебя был свой `nodus-backup`, он сохранится как `/usr/local/sbin/nodus-backup.old-<дата>`.
   Свои пути из него перенеси в `/etc/nodus/backup-paths.conf`.
3. Если Matrix стоял на Conduit (v1) — переход на Tuwunel делается отдельно, по
   [инструкции Tuwunel](https://github.com/matrix-construct/tuwunel). Сначала полный бэкап.
