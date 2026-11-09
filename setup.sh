#!/usr/bin/env bash
# =====================================================================
#  Nodus v2 — установка Matrix (Tuwunel) + звонки + управление одной командой
# ---------------------------------------------------------------------
#  curl -sSL https://raw.githubusercontent.com/TimiQA/nodus/main/setup.sh | sudo bash
#
#  Без флагов — меню. Флаги (всё можно задать заранее, чтобы ничего не спрашивал):
#    --install | --restore FILE | --compare | --tools
#    --domain example.org  --email me@example.org  --ip 203.0.113.10
#    --calls new|legacy|both          звонки: Element X / классические / оба
#    --proxy direct|behind            443 свободен / занят прокси (Xray и т.п.)
#    --nginx-port 10443               куда встаёт nginx при --proxy behind
#    --registration token|open|closed
#    --brand "My Chat"   --federation      (федерация по умолчанию выключена)
#    --staging        сертификат из тестового Let's Encrypt (для проб)
#    --self-signed    самоподписанный сертификат (локальная виртуалка без домена)
#    --check          только проверки и план, ничего не меняет
#    --yes            не задавать вопросов (нужны все флаги)
#  Старая версия на Conduit: тег v1-conduit.
# =====================================================================
set -Eeuo pipefail
umask 022

NODUS_REPO="${NODUS_REPO:-TimiQA/nodus}"
NODUS_REF="${NODUS_REF:-main}"

# ---------- bootstrap: при запуске через curl | bash скачиваем весь репо ----------
_src="${BASH_SOURCE[0]:-}"
if [ -n "$_src" ] && [ -f "$_src" ] && [ -f "$(dirname "$_src")/lib/common.sh" ]; then
  SRC="$(cd "$(dirname "$_src")" && pwd)"
else
  [ "$(id -u)" = 0 ] || { echo "Запусти от root: curl ... | sudo bash" >&2; exit 1; }
  command -v curl >/dev/null && command -v tar >/dev/null || { apt-get update -y >/dev/null; apt-get install -y curl tar >/dev/null; }
  _t="$(mktemp -d)"
  echo "==> Скачиваю nodus ($NODUS_REPO@$NODUS_REF)..."
  curl -fsSL "https://codeload.github.com/$NODUS_REPO/tar.gz/$NODUS_REF" | tar -xz -C "$_t" \
    || { echo "Не скачался репо $NODUS_REPO@$NODUS_REF" >&2; exit 1; }
  _d="$(find "$_t" -mindepth 1 -maxdepth 1 -type d | head -1)"
  NODUS_REF="$NODUS_REF" exec bash "$_d/setup.sh" "$@"
fi

NODUS_LIB_SRC="$SRC"
NODUS_LIB="$SRC"           # пока работаем из скачанного репо
# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"
INSTALL_LIB=/usr/local/lib/nodus

MODE=""; RESTORE_FILE=""; CHECK=0; STAGING=0; SELF_SIGNED=0
DOMAIN=""; LE_EMAIL=""; PUBLIC_IP=""; CALLS=""; PROXY_MODE=""; NGINX_PORT=""; REG_MODE=""; BRAND=""; FEDERATION=""
REG_TOKEN=""

usage(){ sed -n '2,23p' "$SRC/setup.sh"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --install) MODE=install;;
    --restore) MODE=restore; RESTORE_FILE="${2:-}"; shift;;
    --compare) MODE=compare;;
    --tools) MODE=tools;;
    --domain) DOMAIN="${2:-}"; shift;;
    --email) LE_EMAIL="${2:-}"; shift;;
    --ip) PUBLIC_IP="${2:-}"; shift;;
    --calls) CALLS="${2:-}"; shift;;
    --proxy) PROXY_MODE="${2:-}"; shift;;
    --nginx-port) NGINX_PORT="${2:-}"; shift;;
    --registration) REG_MODE="${2:-}"; shift;;
    --brand) BRAND="${2:-}"; shift;;
    --federation) FEDERATION=true;;
    --staging) STAGING=1;;
    --self-signed) SELF_SIGNED=1;;
    --check) CHECK=1;;
    --yes|-y) YES=1;;
    -h|--help) usage; exit 0;;
    *) echo "Неизвестный флаг: $1 (см. --help)" >&2; exit 1;;
  esac; shift
done

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
detect_width
[ "$(id -u)" = 0 ] || die "запусти от root"

# ---------- проверки ввода ----------
valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }
valid_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_email(){ [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
detect_ip(){ # IP с исходящего интерфейса, иначе A-запись домена
  local ip; ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1 || true)"
  [[ -n "$ip" && ! "$ip" =~ ^(10|127|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\. ]] || ip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  printf '%s' "$ip"; }
port_owner(){ { ss -Hltnp "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | sed 's/users:(("//; s/"$//'; } || true; }
ssh_ports(){ local p; p="$(ss -Hltnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}' | sort -u | tr '\n' ' ' || true)"; echo "${p:-22}"; }

# ---------- пакеты и docker (по официальной инструкции docs.docker.com) ----------
install_packages(){
  step "Пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y ca-certificates curl openssl ufw certbot python3 dnsutils iproute2 >/dev/null
  python3 -c 'import tomllib' 2>/dev/null || die "нужен python3 ≥ 3.11 (Debian 12/13 подходят)"
  ok "базовые пакеты на месте"
  if ! command -v docker >/dev/null; then
    step "Docker (официальный репозиторий)"
    . /etc/os-release
    [ "${ID:-}" = debian ] || warn "это не Debian (${ID:-?}) — ставлю Docker по инструкции для Debian, может не подойти"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y >/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  systemctl is-active --quiet docker || systemctl start docker
  dc version >/dev/null 2>&1 || die "docker есть, а docker compose v2 нет. Поставь docker-compose-plugin (docs.docker.com/engine/install/debian)"
  ok "docker и compose v2 работают"
}

# ---------- firewall ----------
apply_firewall(){
  step "Firewall (UFW)"
  local raw n p
  raw="$(ufw status numbered 2>/dev/null || true)"
  mapfile -t nums < <(printf '%s\n' "$raw" | sed -n 's/^\[ *\([0-9]\+\)\].*# nodus-managed.*/\1/p' | sort -rn)
  for n in "${nums[@]}"; do ufw --force delete "$n" >/dev/null 2>&1 || true; done
  for p in $(ssh_ports); do ufw allow "$p/tcp" comment nodus-managed >/dev/null; done
  for p in 80/tcp 443/tcp 8448/tcp 3478/tcp 3478/udp 5349/tcp 49152:49200/udp; do ufw allow "$p" comment nodus-managed >/dev/null; done
  ufw --force enable >/dev/null
  ok "SSH ($(ssh_ports | xargs)), 80, 443, 8448, TURN 3478/5349, relay 49152-49200/udp"
}

# ---------- сертификат ----------
install_cert_hooks(){
  mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post,deploy}
  printf '#!/bin/sh\ndocker stop matrix-nginx\n'    > /etc/letsencrypt/renewal-hooks/pre/10-stop-matrix-nginx.sh
  printf '#!/bin/sh\ndocker start matrix-nginx\n'   > /etc/letsencrypt/renewal-hooks/post/10-start-matrix-nginx.sh
  printf '#!/bin/sh\ndocker restart matrix-coturn\n' > /etc/letsencrypt/renewal-hooks/deploy/10-restart-coturn.sh
  chmod 755 /etc/letsencrypt/renewal-hooks/*/10-*.sh
  ok "хуки продления: nginx освобождает порт 80 на время продления, coturn берёт новый сертификат"
}
ensure_cert(){
  step "Сертификат для $DOMAIN"
  local live="/etc/letsencrypt/live/$DOMAIN"
  if [ "$SELF_SIGNED" = 1 ]; then
    mkdir -p "$live"
    [ -f "$live/fullchain.pem" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=$DOMAIN" \
      -addext "subjectAltName=DNS:$DOMAIN" -keyout "$live/privkey.pem" -out "$live/fullchain.pem" >/dev/null 2>&1
    ok "самоподписанный сертификат (только для тестов)"; return 0
  fi
  if [ -f "$live/fullchain.pem" ] && openssl x509 -checkend 2592000 -noout -in "$live/fullchain.pem" >/dev/null 2>&1; then
    ok "сертификат уже есть и действует ещё >30 дней"
  else
    tcp_listen 80 && die "порт 80 занят ($(port_owner 80)) — certbot не сможет выпустить сертификат"
    local st=(); [ "$STAGING" = 1 ] && st=(--test-cert)
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" "${st[@]}" >/dev/null \
      || die "certbot не выпустил сертификат. Проверь: A-запись $DOMAIN → $PUBLIC_IP и открыт ли порт 80"
    if [ "$STAGING" = 1 ]; then ok "сертификат выпущен (staging — браузер ему не доверяет, это для проб)"; else ok "сертификат выпущен"; fi
  fi
  install_cert_hooks
}

# ---------- инструменты (nodus, nodus-backup) ----------
install_tools(){
  step "Инструменты: nodus и nodus-backup"
  rm -rf "$INSTALL_LIB.new"; mkdir -p "$INSTALL_LIB.new"
  cp -a "$SRC/lib" "$SRC/tools" "$SRC/versions.env" "$INSTALL_LIB.new/"
  echo "$NODUS_REF" > "$INSTALL_LIB.new/REF"
  rm -rf "$INSTALL_LIB"; mv "$INSTALL_LIB.new" "$INSTALL_LIB"
  chmod 755 "$INSTALL_LIB/tools/"*
  ln -sfn "$INSTALL_LIB/tools/nodus" /usr/local/sbin/nodus
  ln -sfn "$INSTALL_LIB/tools/nodus-backup" /usr/local/sbin/nodus-backup
  mkdir -p /etc/nodus
  [ -f /etc/nodus/backup-paths.conf ] || cat > /etc/nodus/backup-paths.conf <<'EOF'
# Свои пути для nodus-backup (по строке, относительно /). Примеры:
# etc/xray
# usr/local/sbin/my-script
# inside my-container:/opt/data
EOF
  ok "команды nodus и nodus-backup установлены ($INSTALL_LIB)"
  NODUS_LIB="$INSTALL_LIB"; PYF="$INSTALL_LIB/lib/edit.py"
}

# ---------- вопросы ----------
ask_domain(){
  while ! valid_domain "$DOMAIN"; do
    [ "$YES" = 1 ] && die "нужен --domain"
    DOMAIN="$(ask_val "Домен сервера (A-запись уже смотрит на этот VPS)" "")"
    valid_domain "$DOMAIN" || warn "это не похоже на домен"
  done
}
ask_email(){
  [ "$SELF_SIGNED" = 1 ] && return 0
  while ! valid_email "$LE_EMAIL"; do
    [ "$YES" = 1 ] && die "нужен --email (для Let's Encrypt)"
    LE_EMAIL="$(ask_val "Email для Let's Encrypt" "")"
  done
}
ask_ip(){
  local d; d="$(detect_ip)"
  [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(ask_val "Публичный IP сервера" "$d")"
  valid_ip "$PUBLIC_IP" || die "кривой IP: $PUBLIC_IP"
  if [ "$SELF_SIGNED" != 1 ]; then
    local dns; dns="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    if [[ " $dns " == *" $PUBLIC_IP "* ]]; then ok "DNS: $DOMAIN → $PUBLIC_IP"
    else warn "DNS: $DOMAIN → ${dns:-ничего}, а сервер $PUBLIC_IP. Пока A-запись не смотрит сюда, сертификат не выпустится."
         ask "Продолжить всё равно? да/нет:" || die "поправь DNS и запусти снова"; fi
  fi
}
ask_calls(){
  local def="${1:-both}" c
  if [ -z "$CALLS" ]; then
    [ "$YES" = 1 ] && CALLS="$def"
    if [ -z "$CALLS" ]; then
      { echo
        echo "  Звонки:"
        echo "    1) новые — Element X / Element Call (LiveKit). Нужен Element X у всех."
        echo "    2) старые — классический Element / SchildiChat (через coturn)"
        echo "    3) оба — работают любые клиенты, но новые и старые между собой не созваниваются"; } | wrapt
      case "$def" in new) def=1;; legacy) def=2;; both) def=3;; esac
      c="$(ask_val "Выбор" "$def")"
      case "$c" in 1) CALLS=new;; 2) CALLS=legacy;; 3) CALLS=both;; *) die "нет такого варианта";; esac
    fi
  fi
  case "$CALLS" in new|legacy|both) ;; *) die "--calls: new | legacy | both";; esac
}
ask_proxy(){
  local own; own="$(port_owner 443)"
  if [ -z "$PROXY_MODE" ]; then
    if tcp_listen 443; then
      { echo; echo "  Порт 443 занят: ${own:-неизвестный процесс}."
        echo "  Nginx встанет за ним на 127.0.0.1:<порт>, а твой прокси (Xray и т.п.) должен"
        echo "  отдавать туда трафик сайта (fallback, TCP как есть)."; } | wrapt
      ask "Так и делаем? да/нет:" || die "освободи 443 или запусти снова"
      PROXY_MODE=behind
    else
      PROXY_MODE=direct
      ok "порт 443 свободен — nginx займёт его сам"
    fi
  fi
  case "$PROXY_MODE" in
    direct) NGINX_PORT=443
            if tcp_listen 443 && [ "$CHECK" != 1 ] && [ "$MODE" != compare ]; then die "443 занят ($own) — нужен --proxy behind"; fi;;
    behind) [ -n "$NGINX_PORT" ] || NGINX_PORT="$(ask_val "Порт для nginx на 127.0.0.1" 10443)"
            [[ "$NGINX_PORT" =~ ^[0-9]+$ ]] && [ "$NGINX_PORT" -gt 1024 ] && [ "$NGINX_PORT" -lt 65536 ] || die "кривой порт: $NGINX_PORT"
            [ "$MODE" = compare ] || ! tcp_listen "$NGINX_PORT" || die "127.0.0.1:$NGINX_PORT уже занят ($(port_owner "$NGINX_PORT"))";;
    *) die "--proxy: direct | behind";;
  esac
}
ask_reg(){
  if [ -z "$REG_MODE" ]; then
    if [ "$YES" = 1 ]; then REG_MODE=token
    else
      { echo; echo "  Регистрация: 1) по токену (рекомендую)  2) открытая для всех  3) закрыта"; } | wrapt
      case "$(ask_val "Выбор" 1)" in 1) REG_MODE=token;; 2) REG_MODE=open;; 3) REG_MODE=closed;; *) die "нет такого варианта";; esac
    fi
  fi
  case "$REG_MODE" in token|open|closed) ;; *) die "--registration: token | open | closed";; esac
  [ -n "$BRAND" ] || BRAND="$(ask_val "Название в веб-клиенте" "Nodus")"
  [[ "$BRAND" =~ ^[A-Za-z0-9\ ._-]{1,40}$ ]] || die "название: латиница, цифры, пробел и . _ - (до 40 символов)"
  FEDERATION="${FEDERATION:-false}"
}

show_plan(){
  step "План"
  { echo "  домен:        $DOMAIN  (IP $PUBLIC_IP)"
    case "$PROXY_MODE" in direct) echo "  порт 443:     nginx напрямую";;
      behind) echo "  порт 443:     за прокси, nginx на 127.0.0.1:$NGINX_PORT";; esac
    case "$CALLS" in new) echo "  звонки:       новые (Element X / Element Call)";;
      legacy) echo "  звонки:       старые (классический Element)";; both) echo "  звонки:       оба вида";; esac
    echo "  регистрация:  $REG_MODE   федерация: $FEDERATION   название: $BRAND"
    if [ "$SELF_SIGNED" = 1 ]; then echo "  сертификат:   самоподписанный (тест)"
    elif [ "$STAGING" = 1 ]; then echo "  сертификат:   Let's Encrypt staging (тест) для $LE_EMAIL"
    else echo "  сертификат:   Let's Encrypt для $LE_EMAIL"; fi
    load_versions; echo "  образы:       $TUWUNEL_IMAGE, $ELEMENT_IMAGE, $NGINX_IMAGE, $COTURN_IMAGE"
    [ "$CALLS" = legacy ] || echo "                $LK_IMAGE, $JWT_IMAGE"; } | wrapt
}

render_to(){ # render_to <папка>  — свежие конфиги по профилю (секреты генерятся тут)
  local d="$1"; mkdir -p "$d"; load_versions
  env DOMAIN="$DOMAIN" PUBLIC_IP="$PUBLIC_IP" CALLS="$CALLS" REG_MODE="$REG_MODE" REG_TOKEN="$REG_TOKEN" \
      PROXY_MODE="$PROXY_MODE" NGINX_PORT="$NGINX_PORT" BRAND="$BRAND" FEDERATION="$FEDERATION" \
      TUWUNEL_IMAGE="$TUWUNEL_IMAGE" ELEMENT_IMAGE="$ELEMENT_IMAGE" NGINX_IMAGE="$NGINX_IMAGE" COTURN_IMAGE="$COTURN_IMAGE" \
      P_compose="$d/docker-compose.yml" P_nginx="$d/nginx.conf" P_conduit="$d/conduit.toml" \
      P_coturn="$d/coturn.conf" P_element="$d/element-config.json" \
      python3 -I "$PYF" render-base
}
place_configs(){ # place_configs <папка> → /opt/nodus (права: секреты 600, остальное 644)
  local d="$1" f
  mkdir -p "$NODUS_DIR"; chmod 755 "$NODUS_DIR"
  for f in docker-compose.yml nginx.conf conduit.toml coturn.conf element-config.json; do
    install -m 644 "$d/$f" "$NODUS_DIR/$f"
  done
  chmod 600 "$NODUS_DIR/conduit.toml" "$NODUS_DIR/coturn.conf"
}
write_profile(){
  save_profile NODUS_REF="$NODUS_REF" DOMAIN="$DOMAIN" PUBLIC_IP="$PUBLIC_IP" CALLS="$CALLS" PROXY_MODE="$PROXY_MODE" \
    NGINX_PORT="$NGINX_PORT" REG_MODE="$REG_MODE" BRAND="$BRAND" FEDERATION="$FEDERATION" LE_EMAIL="$LE_EMAIL"
}
start_stack(){
  step "Запускаю Matrix"
  dc -p nodus -f "$NODUS_DIR/docker-compose.yml" up -d >/dev/null 2>&1 || { dc -p nodus -f "$NODUS_DIR/docker-compose.yml" up -d; die "контейнеры не стартовали"; }
  wait_matrix || { show_logs "$C_MATRIX"; show_logs "$C_NGINX"; die "Matrix не ответил на /_matrix/client/versions"; }
  ok "Matrix отвечает"
  wait_coturn && ok "coturn слушает 3478 и 5349" || warn "coturn не слушает 3478/5349 — глянь: docker logs $C_TURN"
}
setup_calls(){ # довести звонки до выбранного профиля через nodus
  local st legacy
  st="$(env DOMAIN="$DOMAIN" P_conduit="$NODUS_DIR/conduit.toml" P_coturn="$NODUS_DIR/coturn.conf" \
        P_nginx="$NODUS_DIR/nginx.conf" P_element="$NODUS_DIR/element-config.json" python3 -I "$PYF" state)"
  legacy="$(echo "$st" | sed -n 's/^LEGACY=//p')"
  case "$CALLS" in
    new)    [ "$legacy" = on ] && { YES=1 nodus legacy-remove || warn "не удалось убрать legacy-звонки — потом: nodus legacy-remove"; };;
    legacy|both) [ "$legacy" = on ] || { YES=1 nodus legacy-on || warn "не удалось включить legacy — потом: nodus legacy-on"; };;
  esac
  if [ "$CALLS" != legacy ]; then
    step "Новые звонки (LiveKit + lk-jwt)"
    YES=1 nodus rtc-install || warn "новые звонки не встали — Matrix работает. Повторить: nodus rtc-install"
  fi
}
final_words(){
  step "Готово ✅"
  { echo "  Веб-клиент:  https://$DOMAIN"
    [ "$REG_MODE" = token ] && [ -n "$REG_TOKEN" ] && echo "  Токен регистрации: $REG_TOKEN  (он же в $NODUS_DIR/conduit.toml)"
    [ "$PROXY_MODE" = behind ] && echo "  Прокси на 443 должен отдавать трафик $DOMAIN на 127.0.0.1:$NGINX_PORT (TCP как есть, без PROXY protocol)."
    case "$CALLS" in
      new) echo "  Клиенты: Element X (iOS/Android), Element Web — https://$DOMAIN";;
      legacy) echo "  Клиенты: классический Element, SchildiChat, Element Web";;
      both) echo "  Клиенты: Element X для новых звонков; классический Element тоже работает (но не созванивается с Element X)";;
    esac
    echo "  Управление:  nodus      (звонки, секреты, бэкапы)"
    echo "  Бэкап:       nodus-backup → скачай файл из /root/backups/ к себе"; } | wrapt
}

# =====================================================================
#  РЕЖИМЫ
# =====================================================================
do_install(){
  [ -f "$NODUS_DIR/conduit.toml" ] && die "в $NODUS_DIR уже стоит Matrix. setup.sh ставит только на чистый сервер (управление — nodus)"
  step "Новая установка"
  ask_domain; ask_email; ask_ip; ask_calls both; ask_proxy; ask_reg
  show_plan
  if [ "$CHECK" = 1 ]; then echo; ok "--check: ничего не менял."; return 0; fi
  ask "Ставим? да/нет:" || { ok "Ок, ничего не делаю."; return 0; }
  install_packages; apply_firewall
  [ "$REG_MODE" = token ] && REG_TOKEN="$(openssl rand -hex 16)"
  ensure_cert
  step "Конфиги"
  render_to "$TMPD/cfg"; place_configs "$TMPD/cfg"; write_profile
  ok "конфиги в $NODUS_DIR, профиль в $PROFILE"
  start_stack
  install_tools
  setup_calls
  final_words
}

do_restore(){
  [ -f "$NODUS_DIR/conduit.toml" ] && die "в $NODUS_DIR уже стоит Matrix — восстанавливать можно только на чистый сервер"
  step "Восстановление из бэкапа nodus-backup"
  local f="$RESTORE_FILE" x="$TMPD/bk" c="$TMPD/bkcfg" st legacy rtc def
  if [ -z "$f" ]; then
    def="$(ls -1t /root/nodus-backup-*.tar /root/backups/nodus-backup-*.tar 2>/dev/null | head -1 || true)"
    f="$(ask_val "Путь к файлу бэкапа (закинь его по SFTP)" "$def")"
  fi
  [ -f "$f" ] || die "нет файла $f"
  if [ -f "$f.sha256" ]; then
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$(cat "$f.sha256")" ] && ok "sha256 совпадает" || die "sha256 НЕ совпадает — файл битый"
  else warn "рядом нет $f.sha256 — сверь хеш с тем, что на Mac"; fi
  mkdir -p "$x" "$c"; tar -C "$x" -xf "$f"
  [ -f "$x/configs.tar.gz" ] && [ -f "$x/matrix-db.tar.gz" ] || die "в бэкапе нет configs.tar.gz или matrix-db.tar.gz — это точно nodus-backup?"
  ( cd "$x" && sha256sum -c --quiet SHA256SUMS ) || die "внутренние файлы бэкапа не сходятся с SHA256SUMS"
  tar -C "$c" -xzf "$x/configs.tar.gz" opt/nodus 2>/dev/null || die "в бэкапе нет opt/nodus"
  tar -C "$c" -xzf "$x/configs.tar.gz" opt/nodus-rtc 2>/dev/null || true
  [ -f "$c/opt/nodus/conduit.toml" ] || die "в бэкапе нет opt/nodus/conduit.toml"

  # профиль из бэкапа
  local old_profile="$PROFILE"; PROFILE="$c/opt/nodus/nodus.env"
  local k v
  while IFS='=' read -r k v; do case "$k" in DOMAIN|BRAND|REG_MODE|FEDERATION) [ -n "${!k}" ] || printf -v "$k" '%s' "$v";; esac
  done < <(env P_conduit="$c/opt/nodus/conduit.toml" P_element="$c/opt/nodus/element-config.json" python3 -I "$PYF" derive)
  if [ -f "$PROFILE" ] && [ -z "$LE_EMAIL" ]; then
    LE_EMAIL="$(sed -n 's/^LE_EMAIL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$PROFILE" | head -1)"
    valid_email "$LE_EMAIL" || LE_EMAIL=""
  fi
  PROFILE="$old_profile"
  valid_domain "$DOMAIN" || die "не понял домен из бэкапа"
  st="$(env DOMAIN="$DOMAIN" P_conduit="$c/opt/nodus/conduit.toml" P_coturn="$c/opt/nodus/coturn.conf" \
        P_nginx="$c/opt/nodus/nginx.conf" P_element="$c/opt/nodus/element-config.json" python3 -I "$PYF" state)"
  legacy="$(echo "$st" | sed -n 's/^LEGACY=//p')"; rtc="$(echo "$st" | sed -n 's/^RTC_NGINX=//p')"
  if [ "$legacy" = on ] && [ "$rtc" = 1 ]; then def=both; elif [ "$rtc" = 1 ]; then def=new; else def=legacy; fi
  ok "в бэкапе: $DOMAIN, звонки: $def, база $(du -h "$x/matrix-db.tar.gz" | cut -f1)"
  { echo; echo "  ⚠ Домен остаётся $DOMAIN (его нельзя сменить — на нём аккаунты)."
    echo "  ⚠ Старый сервер должен быть ВЫКЛЮЧЕН (или Matrix на нём остановлен), а A-запись — смотреть сюда."; } | wrapt

  ask_ip; ask_email; ask_calls "$def"; ask_proxy
  [ -n "$BRAND" ] || BRAND=Nodus; [ -n "$REG_MODE" ] || REG_MODE=token; FEDERATION="${FEDERATION:-false}"
  show_plan
  echo "  + конфиги Matrix, coturn, Element и база — из бэкапа; nginx/compose — по шаблону; новые звонки — заново" | wrapt
  if [ "$CHECK" = 1 ]; then echo; ok "--check: ничего не менял."; return 0; fi
  ask "Восстанавливаем? да/нет:" || { ok "Ок, ничего не делаю."; return 0; }

  install_packages; apply_firewall
  # сертификат: из бэкапа, если подходит, иначе новый
  if tar -tzf "$x/configs.tar.gz" "etc/letsencrypt/live/$DOMAIN" >/dev/null 2>&1; then
    tar -C / -xzf "$x/configs.tar.gz" etc/letsencrypt && ok "Let's Encrypt восстановлен из бэкапа"
  fi
  [ -n "$LE_EMAIL" ] || [ "$SELF_SIGNED" = 1 ] || ask_email
  ensure_cert

  step "Конфиги"
  REG_TOKEN="x"  # не используется: conduit.toml берём из бэкапа
  render_to "$TMPD/cfg"; REG_TOKEN=""
  cp "$c/opt/nodus/conduit.toml" "$c/opt/nodus/coturn.conf" "$c/opt/nodus/element-config.json" "$TMPD/cfg/"
  # вычищаем старые новые-звонки (поставим заново с новыми ключами) и меняем IP
  env DOMAIN="$DOMAIN" PUBLIC_IP="$PUBLIC_IP" P_nginx="$TMPD/cfg/nginx.conf" P_conduit="$TMPD/cfg/conduit.toml" \
      P_coturn="$TMPD/cfg/coturn.conf" P_element="$TMPD/cfg/element-config.json" \
      P_lkyaml="$c/opt/nodus-rtc/livekit.yaml" python3 -I "$PYF" rtc-remove set-ip || die "не смог подготовить конфиги из бэкапа"
  place_configs "$TMPD/cfg"; write_profile
  ok "конфиги на месте (IP → $PUBLIC_IP)"

  step "База Matrix"
  dc -p nodus -f "$NODUS_DIR/docker-compose.yml" pull -q >/dev/null 2>&1 || true
  dc -p nodus -f "$NODUS_DIR/docker-compose.yml" create >/dev/null 2>&1 || die "не создались контейнеры"
  local vol; vol="$(docker volume inspect nodus_conduit-db -f '{{.Mountpoint}}')" || die "нет тома nodus_conduit-db"
  find "$vol" -mindepth 1 -delete
  tar -C "$vol" -xzf "$x/matrix-db.tar.gz" || die "база не распаковалась"
  ok "база распакована в том nodus_conduit-db"
  start_stack
  install_tools
  setup_calls

  local other; other="$(grep -vE '^(opt/nodus|opt/nodus-rtc|etc/nodus|usr/local/lib/nodus|etc/letsencrypt)$' "$x/configs-list.txt" 2>/dev/null | tr '\n' ' ' || true)"
  final_words
  if [ -n "$other" ]; then
    { echo; echo "  Ещё в бэкапе есть (setup.sh их не трогает): $other"
      echo "  Вернуть руками, например:  tar -C / -xzf <распакованный бэкап>/configs.tar.gz etc/ufw"
      echo "  Данные других контейнеров — в container-data.tar.gz."; } | wrapt
  fi
}

do_compare(){ # сверка шаблонов с ЭТИМ сервером: ничего не меняет
  step "Сверка шаблонов с этим сервером (ничего не меняю)"
  [ -f "$NODUS_DIR/conduit.toml" ] || die "здесь нет $NODUS_DIR — сверять не с чем"
  NODUS_LIB="$SRC"; PYF="$SRC/lib/edit.py"; load_profile
  local st legacy rtc g d="$TMPD/cmp" k f
  st="$(env DOMAIN="$DOMAIN" P_conduit="$NODUS_DIR/conduit.toml" P_coturn="$NODUS_DIR/coturn.conf" \
        P_nginx="$NODUS_DIR/nginx.conf" P_element="$NODUS_DIR/element-config.json" python3 -I "$PYF" state)"
  legacy="$(echo "$st" | sed -n 's/^LEGACY=//p')"; rtc="$(echo "$st" | sed -n 's/^RTC_NGINX=//p')"
  if [ "$legacy" = on ] && [ "$rtc" = 1 ]; then CALLS=both; elif [ "$rtc" = 1 ]; then CALLS=new; else CALLS=legacy; fi
  REG_MODE="${REG_MODE:-token}"; REG_TOKEN=x; BRAND="${BRAND:-Nodus}"; FEDERATION="${FEDERATION:-false}"; PROXY_MODE="${PROXY_MODE:-direct}"
  ok "профиль: $DOMAIN, IP ${PUBLIC_IP:-?}, звонки $CALLS, 443: $PROXY_MODE${NGINX_PORT:+ ($NGINX_PORT)}, регистрация $REG_MODE"
  render_to "$d"
  if [ "$rtc" = 1 ]; then
    g="$(sed -n 's#.*proxy_pass http://\([0-9.]*\):8080/;.*#\1#p' "$NODUS_DIR/nginx.conf" | head -1)"
    load_versions
    env DOMAIN="$DOMAIN" PUBLIC_IP="$PUBLIC_IP" GW="$g" LK_IMAGE="$LK_IMAGE" JWT_IMAGE="$JWT_IMAGE" \
        P_nginx="$d/nginx.conf" P_conduit="$d/conduit.toml" P_coturn="$d/coturn.conf" P_element="$d/element-config.json" \
        P_lkyaml="$d/livekit.yaml" P_lkcompose="$d/rtc-compose.yml" python3 -I "$PYF" rtc-add
  fi
  cmask(){ mask | sed -E 's/^(  )[a-z]+[0-9a-f]{8}:/\1‹ключ›:/; s/(LIVEKIT_KEY: ")[^"]*/\1‹ключ›/'; }
  local any=0
  for k in docker-compose.yml nginx.conf conduit.toml coturn.conf element-config.json livekit.yaml rtc-compose.yml; do
    case "$k" in livekit.yaml) f="$RTC_DIR/livekit.yaml";; rtc-compose.yml) f="$RTC_DIR/docker-compose.yml";; *) f="$NODUS_DIR/$k";; esac
    [ -f "$d/$k" ] || continue
    [ -f "$f" ] || { warn "$f нет на сервере"; continue; }
    if diff -q <(cmask < "$f") <(cmask < "$d/$k") >/dev/null; then ok "$k — совпадает (кроме секретов)"
    else any=1; echo "  ---------- $k (− сервер, + шаблон) ----------"
      diff -u <(cmask < "$f") <(cmask < "$d/$k") | tail -n +3 | sed 's/^/  /' || true; fi
  done
  echo
  [ $any = 0 ] && ok "шаблоны полностью совпадают с сервером" || \
    echo "  Ожидаемые отличия: «http2 on» в nginx, «no-cli» в coturn, комментарии в шапке файлов LiveKit." | wrapt
}

do_tools(){ # поставить/обновить nodus и nodus-backup на уже работающем сервере
  step "nodus и nodus-backup на этом сервере"
  [ -f "$NODUS_DIR/conduit.toml" ] || die "здесь нет $NODUS_DIR — сначала установка (setup.sh --install)"
  NODUS_LIB="$SRC"; PYF="$SRC/lib/edit.py"; load_profile
  local st legacy rtc old=""
  [ -f /usr/local/sbin/nodus-backup ] && [ ! -L /usr/local/sbin/nodus-backup ] && old=/usr/local/sbin/nodus-backup.old-$(date +%Y%m%d)
  { echo "  • поставить nodus и nodus-backup из $NODUS_REPO@$NODUS_REF в $INSTALL_LIB"
    [ -n "$old" ] && echo "  • твой текущий nodus-backup сохранить как $old"
    [ -f "$PROFILE" ] || echo "  • создать профиль $PROFILE из текущих конфигов (домен $DOMAIN)"
    echo "  • конфиги и контейнеры НЕ трогаю"; } | wrapt
  if [ "$CHECK" = 1 ]; then echo; ok "--check: ничего не менял."; return 0; fi
  ask "Ставим? да/нет:" || { ok "Ок, ничего не делаю."; return 0; }
  [ -n "$old" ] && cp -a /usr/local/sbin/nodus-backup "$old" && rm -f /usr/local/sbin/nodus-backup
  install_tools
  if [ ! -f "$PROFILE" ]; then
    st="$(env DOMAIN="$DOMAIN" P_conduit="$NODUS_DIR/conduit.toml" P_coturn="$NODUS_DIR/coturn.conf" \
          P_nginx="$NODUS_DIR/nginx.conf" P_element="$NODUS_DIR/element-config.json" python3 -I "$PYF" state)"
    legacy="$(echo "$st" | sed -n 's/^LEGACY=//p')"; rtc="$(echo "$st" | sed -n 's/^RTC_NGINX=//p')"
    if [ "$legacy" = on ] && [ "$rtc" = 1 ]; then CALLS=both; elif [ "$rtc" = 1 ]; then CALLS=new; else CALLS=legacy; fi
    PROXY_MODE="${PROXY_MODE:-direct}"; FEDERATION="${FEDERATION:-false}"
    write_profile; ok "профиль создан: $PROFILE"
  fi
  if [ -n "$old" ]; then
    { echo; echo "  ⚠ Новый nodus-backup берёт только Matrix-часть. Свои пути (VPN, Xray и т.п.)"
      echo "    впиши в /etc/nodus/backup-paths.conf — по строке на путь. Старый скрипт: $old"; } | wrapt
  fi
  ok "готово — проверь: nodus status"
}

main_menu(){
  { echo; echo "  Nodus v2 — Matrix (Tuwunel) + звонки"
    echo "    1) новая установка на чистый сервер"
    echo "    2) восстановить из бэкапа (переезд на новый VPS)"
    echo "    3) сверить шаблоны с этим сервером (ничего не меняет)"
    echo "    4) поставить/обновить nodus и nodus-backup на этом сервере"
    echo "    0) выход"; } | wrapt
  case "$(ask_val "Что делаем?" "")" in
    1) MODE=install;; 2) MODE=restore;; 3) MODE=compare;; 4) MODE=tools;; *) exit 0;;
  esac
}

[ -n "$MODE" ] || { [ "$YES" = 1 ] && die "укажи --install, --restore FILE, --compare или --tools"; main_menu; }
case "$MODE" in
  install) do_install;;
  restore) do_restore;;
  compare) do_compare;;
  tools) do_tools;;
esac
