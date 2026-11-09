# shellcheck shell=bash
# =====================================================================
#  nodus: общие функции для setup.sh, nodus и nodus-backup
# =====================================================================
NODUS_DIR="${NODUS_DIR:-/opt/nodus}"
RTC_DIR="${RTC_DIR:-/opt/nodus-rtc}"
NODUS_LIB="${NODUS_LIB:-/usr/local/lib/nodus}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/backups}"
PROFILE="$NODUS_DIR/nodus.env"
PYF="${PYF:-$NODUS_LIB/lib/edit.py}"
YES="${YES:-0}"

C_NGINX=matrix-nginx; C_MATRIX=matrix-conduit; C_TURN=matrix-coturn; C_ELEMENT=matrix-element
C_LK=matrix-livekit; C_JWT=matrix-lk-jwt

# ---------- вывод ----------
if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1;36m'; N=$'\e[0m'; else R=; G=; Y=; B=; N=; fi
COLS=80; NARROW=0
detect_width(){ # узкий экран (телефон) → компактный вид. NODUS_WIDE=1 / NODUS_NARROW=1 — принудительно
  local c=""
  c="$( { stty size </dev/tty; } 2>/dev/null | awk '{print $2}')" || c=""
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] || c="$(tput cols 2>/dev/null || true)"
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] || c=80
  COLS=$c; NARROW=0; [ "$COLS" -lt 70 ] && NARROW=1
  [ "${NODUS_WIDE:-0}" = 1 ] && NARROW=0
  [ "${NODUS_NARROW:-0}" = 1 ] && NARROW=1
  return 0
}
wrapt(){ # переносит длинные строки по словам (только на узком экране)
  if [ "$NARROW" = 1 ]; then python3 -I -c 'import sys, textwrap
w = max(int(sys.argv[1]) - 1, 20)
for l in sys.stdin.read().splitlines():
    s = l.lstrip(); ind = " " * (len(l) - len(s))
    print(textwrap.fill(s, w, initial_indent=ind, subsequent_indent=ind + "  ", break_on_hyphens=False) if s else "")' "$COLS"
  else cat; fi; }
cutl(){ python3 -I -c 'import sys
w = max(int(sys.argv[1]) - 1, 20)
for l in sys.stdin.read().splitlines():
    print(l if len(l) <= w else l[:w - 1] + "…")' "$COLS"; }
step(){ printf '\n%s==> %s%s\n' "$B" "$*" "$N" | wrapt; }
ok(){   printf '  %s✔%s %s\n' "$G" "$N" "$*" | wrapt; }
warn(){ printf '  %s⚠%s %s\n' "$Y" "$N" "$*" | wrapt; }
die(){  printf '\n%s✘ СТОП:%s %s\n' "$R" "$N" "$*" | wrapt >&2; exit 1; }
mask(){ sed -E -e 's/[0-9a-fA-F]{16,}/‹секрет›/g' \
               -e 's/((secret|token|password)[A-Za-z_-]*[ \t]*[=:][ \t]*"?)[^" \t]+/\1‹секрет›/Ig'; }
show_logs(){ docker logs --tail 30 "$1" 2>&1 | mask | sed 's/^/     | /' || true; }
ask(){ # ask "вопрос" → 0 если «да»
  local a; [ "$YES" = 1 ] && return 0
  read -r -p "  $1 " a </dev/tty || return 1
  case "$a" in да|Да|ДА|д|Д|y|Y|yes|Yes) return 0;; *) return 1;; esac; }
ask_val(){ # ask_val "вопрос" "по умолчанию" → печатает ответ
  local a; if [ "$YES" = 1 ]; then printf '%s' "$2"; return 0; fi
  read -r -p "  $1${2:+ [$2]}: " a </dev/tty || a=""
  printf '%s' "${a:-$2}"; }

# ---------- docker compose (v2) ----------
dc(){
  if docker compose version >/dev/null 2>&1; then docker compose "$@"
  elif command -v docker-compose >/dev/null && docker-compose version 2>/dev/null | grep -qE 'v?2\.'; then docker-compose "$@"
  else die "нужен docker compose v2"; fi; }
running(){ [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
tcp_listen(){ ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q .; }

# ---------- профиль ----------
# /opt/nodus/nodus.env — без секретов: DOMAIN, PUBLIC_IP, CALLS, PROXY_MODE, NGINX_PORT, ...
# Если его нет (сервер поставлен до v2) — выводим из конфигов.
load_profile(){
  local line k v
  DOMAIN=""; PUBLIC_IP=""; PROXY_MODE=""; NGINX_PORT=""; BRAND=""; REG_MODE=""; FEDERATION=""; CALLS=""
  if [ -f "$PROFILE" ]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^([A-Z_]+)=\"?([A-Za-z0-9._:@/\ -]*)\"?$ ]] || continue
      k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
      case "$k" in DOMAIN|PUBLIC_IP|PROXY_MODE|NGINX_PORT|BRAND|REG_MODE|FEDERATION|CALLS|LE_EMAIL|NODUS_REF) printf -v "$k" '%s' "$v";; esac
    done < "$PROFILE"
  fi
  if [ -z "$DOMAIN" ] || [ -z "$NGINX_PORT" ] || [ -z "$PUBLIC_IP" ]; then
    while IFS='=' read -r k v; do
      case "$k" in DOMAIN|PUBLIC_IP|PROXY_MODE|NGINX_PORT|BRAND|REG_MODE|FEDERATION)
        [ -n "${!k}" ] || printf -v "$k" '%s' "$v";; esac
    done < <(env DOMAIN="" P_conduit="$NODUS_DIR/conduit.toml" P_coturn="$NODUS_DIR/coturn.conf" \
                 P_compose="$NODUS_DIR/docker-compose.yml" P_element="$NODUS_DIR/element-config.json" \
                 python3 -I "$PYF" derive 2>/dev/null)
  fi
  NGINX_PORT="${NGINX_PORT:-443}"
  [ -n "$DOMAIN" ] || die "не понял домен (нет $PROFILE и не читается $NODUS_DIR/conduit.toml)"
}
save_profile(){ # save_profile KEY=VAL ...  (секреты сюда НЕ писать)
  local kv; umask 077; mkdir -p "$NODUS_DIR"
  { echo "# профиль nodus — без секретов. Меняется через setup.sh / nodus"
    for kv in "$@"; do echo "${kv%%=*}=\"${kv#*=}\""; done; } > "$PROFILE.tmp"
  mv "$PROFILE.tmp" "$PROFILE"; chmod 600 "$PROFILE"
}

# ---------- HTTP-проверки (прямо в nginx на 127.0.0.1, мимо внешнего прокси) ----------
lcode(){ curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$DOMAIN:$NGINX_PORT:127.0.0.1" "https://$DOMAIN:$NGINX_PORT$1" 2>/dev/null || true; }
lbody(){ curl -sk --max-time 10 --resolve "$DOMAIN:$NGINX_PORT:127.0.0.1" "https://$DOMAIN:$NGINX_PORT$1" 2>/dev/null || true; }
pcode(){ curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN$1" 2>/dev/null || true; }
hcode(){ curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }
wait_matrix(){ local i; for i in $(seq 45); do [ "$(lcode /_matrix/client/versions)" = 200 ] && return 0; sleep 2; done; return 1; }
wait_coturn(){ local i; for i in $(seq 15); do tcp_listen 3478 && tcp_listen 5349 && return 0; sleep 2; done; return 1; }
wait_rtc(){ local i; for i in $(seq 20); do
  [ "$(hcode http://127.0.0.1:7880/)" = 200 ] && [ "$(hcode http://127.0.0.1:8080/healthz)" = 200 ] && return 0; sleep 2; done; return 1; }

# ---------- версии образов ----------
load_versions(){
  local f="$NODUS_LIB/versions.env" line k v
  [ -f "${VERSIONS_FILE:-}" ] && f="$VERSIONS_FILE"
  TUWUNEL_IMAGE=ghcr.io/matrix-construct/tuwunel:latest; ELEMENT_IMAGE=vectorim/element-web:latest
  NGINX_IMAGE=nginx:latest; COTURN_IMAGE=coturn/coturn:latest
  LK_IMAGE=livekit/livekit-server:latest; JWT_IMAGE=ghcr.io/element-hq/lk-jwt-service:latest
  [ -f "$f" ] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_]+_IMAGE)=\"?([A-Za-z0-9._:@/-]+)\"?$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; printf -v "$k" '%s' "$v"
  done < "$f"
}
