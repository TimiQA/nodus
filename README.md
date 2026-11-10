# 🛡️ Nodus v2: свой Matrix-мессенджер со звонками за одну команду

![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)
![Rust](https://img.shields.io/badge/rust-%23000000.svg?style=for-the-badge&logo=rust&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-A81D33?style=for-the-badge&logo=debian&logoColor=white)
![Matrix](https://img.shields.io/badge/Matrix-000000?style=for-the-badge&logo=matrix&logoColor=white)

**Nodus** ставит на дешёвый VPS (1 vCPU, 2 ГБ RAM) приватный Matrix-сервер для семьи или небольшой команды:
**Tuwunel** (лёгкий homeserver на Rust) + **Element Web** + **coturn** + по желанию **LiveKit** для новых звонков
Element X / Element Call. Управление и бэкапы — текстовым меню `nodus`, которое ставится само.

> Старая версия на Conduit с классическими звонками заморожена в теге
> [`v1-conduit`](https://github.com/TimiQA/nodus/tree/v1-conduit).

---

## ⚡ Установка

Чистый **Debian 13** (12 тоже подходит), A-запись домена уже смотрит на сервер:

```bash
curl -sSL https://raw.githubusercontent.com/TimiQA/nodus/main/setup.sh | sudo bash
```

Скрипт покажет меню:

| | Что делает |
|---|---|
| **1. Новая установка** | спросит домен, email, IP, какие звонки, свободен ли 443, как регистрироваться — покажет план и поставит |
| **2. Восстановить из бэкапа** | переезд на новый VPS: база, аккаунты и конфиги из файла `nodus-backup` |
| **3. Сверить шаблоны** | на работающем сервере: сравнит его конфиги с тем, что сгенерировал бы скрипт. Ничего не меняет |
| **4. Поставить/обновить `nodus`** | на уже работающем сервере: только инструменты, конфиги не трогает |

Любой шаг можно задать флагами и не отвечать на вопросы — `setup.sh --help`.
`--check` показывает план и ничего не меняет.

```bash
# пример: всё заранее, без вопросов
curl -sSL https://raw.githubusercontent.com/TimiQA/nodus/main/setup.sh | sudo bash -s -- \
  --install --yes --domain chat.example.org --email me@example.org --calls both
```

### Звонки

| Вариант | Клиенты | Что внутри |
|---|---|---|
| `new` — новые | Element X (iOS/Android), Element Web | LiveKit + lk-jwt-service, медиа через coturn TURN/TLS 5349 |
| `legacy` — старые | классический Element, SchildiChat, Element Web | coturn |
| `both` — оба | любые | оба механизма; но новые и старые клиенты друг другу не дозвонятся |

Переключать можно и потом: `nodus` → «Legacy-звонки» / «Новые звонки».

### Порт 443 занят (Xray и т.п.)

Если на 443 уже висит другой прокси, `setup.sh` это увидит и поставит nginx за ним на `127.0.0.1:10443`
(порт можно выбрать). Прокси должен отдавать трафик сайта туда **как есть, по TCP, без PROXY protocol**:
в Xray это `fallbacks: [{"dest": "127.0.0.1:10443", "xver": 0}]` (или `dest` в REALITY).
Сам конфиг прокси `setup.sh` не трогает.

---

## 🎛️ Управление: `nodus`

```
nodus           меню: статус сверху, выбираешь номер
nodus check     полная проверка с итогом «что не так и что делать»
nodus help      все команды
```

**Главный экран** — то, что нужно постоянно:

| | |
|---|---|
| **Проверка** | контейнеры и их перезапуски, Matrix изнутри и снаружи, well-known, поддержка Element X, пуш-шлюз, DNS, сертификат и автопродление, coturn, LiveKit, настоящий тест TURN, UFW, диск/RAM/swap, часы, бэкапы — и список, что исправить |
| **Логи** | выбрать сервис → последние 100 строк / ошибки за сутки / живой поток; секреты замазаны |
| **Сервисы** | состояние, аптайм, перезапуски; перезапуск одного или всех с проверкой. Чужие контейнеры (RustDesk и т.п.) только показываются |
| **Тест TURN** | настоящий запрос relay по UDP 3478 и TLS 5349 с тем же паролем, что у клиентов |
| **Отчёт для Claude** | всё про сервер в одном файле без секретов — чтобы скинуть в чат |

**Расширенные** — разовое:

- **Бэкапы:** полный, только конфиги (без простоя), список, удаление, автобэкап по расписанию (systemd-таймер).
- **Обновления:** образы контейнеров — скачать, перезапустить, проверить, при ошибке вернуть прежние версии;
  перед новым Tuwunel — полный бэкап. Обновление самого `nodus` из репо.
- **Сертификат:** срок, пробное продление (проверяет хуки), продление сейчас.
- **Секреты:** смена TURN-секретов и API-ключа LiveKit.
- **Звонки:** старые и новые — выключить, удалить, включить (новые при необходимости ставятся заново).

Перед любым изменением `nodus` показывает diff (секреты замазаны), спрашивает «да?», сохраняет конфиги,
делает шаги с проверками и при ошибке сам всё откатывает. `CHECK_ONLY=1 nodus <действие>` — только посмотреть.
На узком экране (телефон) всё становится компактным само.

## 💾 Бэкапы и переезд

`nodus-backup` собирает конфиги, сертификаты, данные контейнеров и базу Matrix (Tuwunel стоит ~3 секунды)
в `/root/backups/nodus-backup-<host>-<дата>.tar`. Хранит последние 3 — **скачивай к себе**.
Свои пути (VPN и т.п.) добавляются в `/etc/nodus/backup-paths.conf`.

Переезд на новый VPS — [docs/MIGRATION.md](docs/MIGRATION.md).

---

## 📱 Клиенты

- **Element X** — [App Store](https://apps.apple.com/app/element-x-secure-chat-call/id1631335820) ·
  [Google Play](https://play.google.com/store/apps/details?id=io.element.android.x).
  При входе: «Сменить сервер» → ваш домен → логин и пароль.
- **Классический Element** / **SchildiChat** — для варианта `legacy` или `both`.
- **Element Web** — `https://ваш-домен` (регистрация по токену, если выбрали её).

## ⚙️ Как устроено

| Компонент | Где | Порты |
|---|---|---|
| Tuwunel (`matrix-conduit`) | `/opt/nodus/conduit.toml`, том `nodus_conduit-db` | 6167 внутри docker |
| nginx (`matrix-nginx`) | `/opt/nodus/nginx.conf` | 80, 443 (или 127.0.0.1:10443), 8448 |
| Element Web | `/opt/nodus/element-config.json` | внутри docker |
| coturn (host network) | `/opt/nodus/coturn.conf` | 3478 tcp/udp, 5349 TLS, 49152–49200/udp |
| LiveKit + lk-jwt (host network) | `/opt/nodus-rtc/` | 7880/8080 только из docker-сетей, 7881, 50100–50200/udp закрыты снаружи |

Имена `conduit.toml`, `matrix-conduit` и `nodus_conduit-db` остались с v1 — так совместимы старые бэкапы и серверы.
Профиль установки без секретов — `/opt/nodus/nodus.env`, версии образов — `versions.env`.
Сертификат продлевает certbot; хуки в `/etc/letsencrypt/renewal-hooks/` освобождают порт 80 на время продления.

## 🇬🇧 In short

Nodus provisions a private Matrix node (Tuwunel + Element Web + coturn, optionally LiveKit for Element X calls)
on a small Debian VPS with one command, including backups, restore-to-new-VPS and a text-menu manager (`nodus`).
Run `setup.sh --help` for non-interactive flags. The previous Conduit-based version lives in tag `v1-conduit`.
