# shellcheck shell=bash
# =====================================================================
#  nodus: диагностика — быстрый статус, полная проверка, логи, сервисы,
#  тест TURN, отчёт. Подключается из tools/nodus (нужны LIVE, load_state).
# =====================================================================

bad(){ printf '  %s✘%s %s\n' "$R" "$N" "$*" | wrapt; }
maskf(){ sed -u -E -e 's/[0-9a-fA-F]{16,}/‹секрет›/g' \
                   -e 's/((secret|token|password)[A-Za-z_-]*[ \t]*[=:][ \t]*"?)[^" \t]+/\1‹секрет›/Ig'; }

svc_list(){ # SVC — контейнеры nodus, SVC_NAME — человеческие имена
  SVC=("$C_MATRIX" "$C_NGINX" "$C_ELEMENT" "$C_TURN"); SVC_NAME=(Matrix nginx "Element Web" coturn)
  if [ -f "${LIVE[lkcompose]}" ]; then SVC+=("$C_LK" "$C_JWT"); SVC_NAME+=(LiveKit lk-jwt); fi
}
cert_days(){
  local f="/etc/letsencrypt/live/$DOMAIN/fullchain.pem" end
  [ -f "$f" ] || return 0
  end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)" || return 0
  [ -n "$end" ] && echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  return 0
}
last_backup(){ ls -1t "$BACKUP_ROOT"/nodus-backup-*.tar* 2>/dev/null | grep -v '\.sha256$' | head -1 || true; }
backup_days(){ local f; f="$(last_backup)"; [ -n "$f" ] && echo $(( ( $(date +%s) - $(stat -c %Y "$f") ) / 86400 )); return 0; }
mark(){ if [ "$1" = 1 ]; then printf '✅'; else printf '❌'; fi; }

# ---------- быстрый статус (шапка главного меню) ----------
quick_status(){
  load_state; svc_list
  local i probs=() cd bd up=() line
  for i in "${!SVC[@]}"; do
    case "${SVC[$i]}" in "$C_LK"|"$C_JWT") [ "$RTC" = off ] && continue;; esac
    running "${SVC[$i]}" || probs+=("${SVC_NAME[$i]} не работает")
  done
  [ "$RTC" = partial ] && probs+=("новые звонки включены не полностью")
  [ "$LEGACY_SYNC" = 0 ] && probs+=("секрет старых звонков не совпадает")
  [ "$LK_TURN_SYNC" = 0 ] && probs+=("секрет LiveKit не совпадает")
  cd="$(cert_days)"; bd="$(backup_days)"
  [ -n "$cd" ] && [ "$cd" -lt 14 ] && probs+=("сертификату осталось $cd дн.")
  if [ -z "$bd" ]; then probs+=("нет полного бэкапа"); elif [ "$bd" -gt 7 ]; then probs+=("бэкапу $bd дн."); fi
  if [ ${#probs[@]} -eq 0 ]; then step "$DOMAIN — всё в порядке ✅"
  else step "$DOMAIN — ⚠ проблем: ${#probs[@]} → пункт 1"; fi
  line="  Matrix $(running "$C_MATRIX" && mark 1 || mark 0)  coturn $(running "$C_TURN" && mark 1 || mark 0)"
  case "$RTC" in on|partial) line+="  LiveKit $(running "$C_LK" && running "$C_JWT" && mark 1 || mark 0)";; esac
  echo "$line"
  echo "  Звонки: старые $(short_state "$LEGACY")  новые $(short_state "$RTC")"
  local ct="?" bt="нет"; [ -n "$cd" ] && ct="ещё $cd дн."; [ -n "$bd" ] && bt="$bd дн. назад"
  echo "  Сертификат: $ct   Бэкап: $bt"
  if [ ${#probs[@]} -gt 0 ]; then for i in "${probs[@]}"; do warn "$i"; done; fi
  return 0
}
short_state(){ case "$1" in on) echo "✅";; off) echo "⏸ выкл";; removed) echo "— нет";; partial) echo "⚠ частично";; *) echo "⚠";; esac; }

# ---------- полная проверка ----------
CK_OK=0; CK_WARN=0; CK_BAD=0; HINTS=()
c_ok(){ ok "$1"; CK_OK=$((CK_OK+1)); }
c_warn(){ warn "$1"; CK_WARN=$((CK_WARN+1)); [ -z "${2:-}" ] || HINTS+=("⚠ $1 → $2"); }
c_bad(){ bad "$1"; CK_BAD=$((CK_BAD+1)); [ -z "${2:-}" ] || HINTS+=("✘ $1 → $2"); }

do_check(){
  CK_OK=0; CK_WARN=0; CK_BAD=0; HINTS=()
  load_state; svc_list
  local i c st rc code body cd dns used mem swt swu ntp

  step "Контейнеры"
  for i in "${!SVC[@]}"; do
    c="${SVC[$i]}"
    case "$c" in "$C_LK"|"$C_JWT") [ "$RTC" = off ] && { ok "${SVC_NAME[$i]} — выключен (так задумано)"; continue; };; esac
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo нет)"
    rc="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)"
    case "$st" in
      running) if [ "$rc" -gt 3 ]; then c_warn "${SVC_NAME[$i]} работает, но перезапускался $rc раз" "глянь логи ${SVC_NAME[$i]}: nodus → Логи"
               else c_ok "${SVC_NAME[$i]} работает"; fi;;
      restarting) c_bad "${SVC_NAME[$i]} падает и перезапускается по кругу" "nodus → Логи → ${SVC_NAME[$i]} → только ошибки";;
      нет) c_bad "${SVC_NAME[$i]}: контейнера нет" "контейнер $c пропал — напиши Claude с отчётом (пункт 5)";;
      *) c_bad "${SVC_NAME[$i]}: $st" "запусти: nodus → Сервисы";;
    esac
  done

  step "Matrix"
  code="$(lcode /_matrix/client/versions)"
  [ "$code" = 200 ] && c_ok "Matrix отвечает через nginx" || c_bad "Matrix не отвечает через nginx (код $code)" "nodus → Логи → Matrix и nginx"
  code="$(pcode /_matrix/client/versions)"
  [ "$code" = 200 ] && c_ok "снаружи https://$DOMAIN открывается" \
    || c_warn "https://$DOMAIN с самого сервера не открылся (код $code)" "проверь с телефона; если и там не открывается — DNS или прокси на 443"
  body="$(lbody /.well-known/matrix/client)"
  if [[ "$body" == *'"m.homeserver"'* ]]; then c_ok "well-known отдаётся"; else c_bad "well-known не отдаётся" "клиенты не найдут сервер — nodus → Логи → nginx"; fi
  if [ "$RTC" = on ]; then
    [[ "$body" == *rtc_foci* ]] && c_ok "well-known сообщает про новые звонки (rtc_foci)" || c_bad "в well-known нет rtc_foci" "Element X не увидит звонки — nodus → Расширенные → Звонки"
  fi
  body="$(lbody /_matrix/client/versions)"
  [[ "$body" == *simplified_msc3575* ]] && c_ok "Tuwunel поддерживает Element X (sliding sync)" \
    || c_warn "Tuwunel не объявляет sliding sync — Element X может не синхронизироваться" "если недавно обновлялся Tuwunel — откати образ (Расширенные → Обновления)"
  if [ "$RTC" = on ]; then
    code="$(lcode '/_matrix/federation/v1/openid/userinfo?access_token=nodus-probe')"
    case "$code" in 401|403) c_ok "openid работает — lk-jwt может проверять пользователей";;
      *) c_bad "openid/userinfo вернул $code" "без него Element X не войдёт в звонок";; esac
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://matrix.org/_matrix/push/v1/notify 2>/dev/null || true)"
  case "$code" in 2??|4??) c_ok "пуш-шлюз matrix.org доступен — звонки дойдут на заблокированный телефон";;
    *) c_bad "пуш-шлюз matrix.org недоступен (код ${code:-000})" "без пушей звонок не придёт на заблокированный телефон — проверь исходящий интернет сервера";; esac

  step "Сертификат и DNS"
  dns="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  if [ -n "$PUBLIC_IP" ] && [[ " $dns " == *" $PUBLIC_IP "* ]]; then c_ok "DNS: $DOMAIN → $PUBLIC_IP"
  else c_warn "DNS: $DOMAIN → ${dns:-ничего}, а сервер ${PUBLIC_IP:-?}" "проверь A-запись домена"; fi
  cd="$(cert_days)"
  if [ -z "$cd" ]; then c_bad "сертификата /etc/letsencrypt/live/$DOMAIN нет" "Расширенные → Сертификат"
  elif [ "$cd" -lt 7 ]; then c_bad "сертификат истекает через $cd дн." "Расширенные → Сертификат → продлить сейчас"
  elif [ "$cd" -lt 21 ]; then c_warn "сертификату осталось $cd дн. (обычно продлевается за 30)" "Расширенные → Сертификат → пробное продление"
  else c_ok "сертификат действует ещё $cd дн."; fi
  if systemctl is-active --quiet certbot.timer 2>/dev/null || [ -f /etc/cron.d/certbot ]; then c_ok "автопродление certbot включено"
  else c_warn "не вижу автопродления certbot (ни certbot.timer, ни cron)" "без него сертификат протухнет через 90 дней"; fi
  if [ -x /etc/letsencrypt/renewal-hooks/pre/10-stop-matrix-nginx.sh ] && [ -x /etc/letsencrypt/renewal-hooks/post/10-start-matrix-nginx.sh ]; then
    c_ok "хуки продления на месте"
  else c_warn "нет хуков продления (stop/start nginx)" "продление упрётся в занятый порт 80"; fi

  step "Звонки"
  tcp_listen 3478 && c_ok "coturn слушает 3478/tcp" || c_bad "coturn не слушает 3478/tcp" "nodus → Логи → coturn"
  ss -Hlun "( sport = :3478 )" 2>/dev/null | grep -q . && c_ok "coturn слушает 3478/udp" || c_bad "coturn не слушает 3478/udp" "nodus → Логи → coturn"
  tcp_listen 5349 && c_ok "coturn слушает TLS 5349" || c_bad "coturn не слушает TLS 5349" "часто это сертификат: nodus → Логи → coturn"
  case "$LEGACY_SYNC" in 1) c_ok "секрет старых звонков: Tuwunel = coturn";; 0) c_bad "секрет старых звонков в Tuwunel и coturn разный" "Расширенные → Секреты → сменить секрет legacy";; esac
  case "$LK_TURN_SYNC" in 1) c_ok "секрет LiveKit = coturn";; 0) c_bad "TURN-секрет LiveKit и coturn разный" "Расширенные → Секреты → сменить TURN-секрет LiveKit";; esac
  if [ "$RTC" = on ] || [ "$RTC" = partial ]; then
    [ "$(hcode http://127.0.0.1:7880/)" = 200 ] && c_ok "LiveKit отвечает" || c_bad "LiveKit не отвечает" "nodus → Логи → LiveKit"
    [ "$(hcode http://127.0.0.1:8080/healthz)" = 200 ] && c_ok "lk-jwt отвечает" || c_bad "lk-jwt не отвечает" "nodus → Логи → lk-jwt"
    [ "$(lcode /livekit/jwt/healthz)" = 200 ] && c_ok "lk-jwt доступен через nginx" || c_bad "lk-jwt не доступен через nginx" "nodus → Логи → nginx"
    code="$(pcode /livekit/jwt/healthz)"
    [ "$code" = 200 ] && c_ok "lk-jwt доступен снаружи" || c_warn "lk-jwt снаружи: код $code" "проверь с телефона https://$DOMAIN/livekit/jwt/healthz"
  fi
  turn_results check

  step "Система"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    local u; u="$(ufw status 2>/dev/null)"
    if grep -q '3478' <<<"$u" && grep -q '5349' <<<"$u" && grep -q '49152:49200' <<<"$u"; then c_ok "UFW включён, порты звонков открыты"
    else c_warn "UFW включён, но не вижу правил для 3478/5349/49152:49200" "без них звонки через relay не пройдут"; fi
  else c_warn "UFW выключен" "сервер без файрвола: LiveKit 7880/8080 видны из интернета"; fi
  used="$(df -P / | awk 'NR==2{print $5+0}')"
  if [ "$used" -ge 90 ]; then c_bad "диск занят на $used%" "Расширенные → Бэкапы → удалить старые; Обновления чистят старые образы"
  elif [ "$used" -ge 80 ]; then c_warn "диск занят на $used%" "почисти старые бэкапы"
  else c_ok "диск занят на $used%"; fi
  mem="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
  [ "$mem" -ge 150 ] && c_ok "свободно RAM: $mem МБ" || c_warn "свободно RAM всего $mem МБ" "что-то ест память — nodus → Сервисы"
  swt="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"; swu="$(awk '/SwapFree/{print $2}' /proc/meminfo)"
  if [ "${swt:-0}" -gt 0 ]; then swu=$(( (swt - swu) * 100 / swt ))
    [ "$swu" -lt 80 ] && c_ok "swap занят на $swu%" || c_warn "swap занят на $swu%" "серверу тесно по памяти"; fi
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  [ "$ntp" = yes ] && c_ok "часы синхронизированы" || c_warn "часы не синхронизированы (NTP)" "пароли TURN зависят от времени: timedatectl set-ntp true"
  local bd; bd="$(backup_days)"
  if [ -z "$bd" ]; then c_warn "полных бэкапов нет" "Расширенные → Бэкапы → полный"
  elif [ "$bd" -gt 7 ]; then c_warn "последнему полному бэкапу $bd дн." "Расширенные → Бэкапы → полный, и скачай к себе"
  else c_ok "последний полный бэкап: $bd дн. назад"; fi
  if systemctl is-enabled --quiet nodus-backup.timer 2>/dev/null; then c_ok "автобэкап включён"
  else c_warn "автобэкап выключен" "Расширенные → Бэкапы → автобэкап"; fi

  step "Итого"
  echo "  ✅ $CK_OK   ⚠ $CK_WARN   ✘ $CK_BAD"
  if [ ${#HINTS[@]} -gt 0 ]; then
    echo; echo "  Что сделать:"
    printf '%s\n' "${HINTS[@]}" | awk '!s[$0]++' | sed 's/^/   /' | wrapt
  else ok "всё в порядке"; fi
  return 0
}

# ---------- тест TURN ----------
turn_results(){ # turn_results [check] — печатает итог; в режиме check считает в общий счёт
  local mode="${1:-}" line label res det
  local py_lk=""; [ -f "${LIVE[lkyaml]}" ] && py_lk="${LIVE[lkyaml]}"
  while IFS='|' read -r line label res det; do
    [ "$line" = RESULT ] || continue
    if [ "$res" = ok ]; then
      if [ "$mode" = check ]; then c_ok "TURN $label: $det"; else ok "$label: $det"; fi
    else
      if [ "$mode" = check ]; then c_bad "TURN $label: $det" "Тест TURN не прошёл — звонки через relay не заработают"; else bad "$label: $det"; fi
    fi
  done < <(env DOMAIN="$DOMAIN" PUBLIC_IP="$PUBLIC_IP" P_conduit="${LIVE[conduit]}" P_lkyaml="$py_lk" \
             python3 -I "$NODUS_LIB/lib/turntest.py" 2>&1 || true)
}
do_turn_test(){
  step "Тест TURN: настоящий запрос relay, как у клиентов"
  echo "  (секреты берутся из конфигов и не показываются)"
  turn_results
  echo
  echo "  ✅ = coturn выдал relay: звонки через него пройдут. ✘ 401 = не совпадает секрет или сбиты часы." | wrapt
}

# ---------- логи ----------
pick_service(){ # → PICK (контейнер), PICK_NAME
  svc_list; local i c
  echo; for i in "${!SVC[@]}"; do printf '   %d) %s\n' $((i+1)) "${SVC_NAME[$i]}"; done; echo "   0) назад"
  read -r -p "  Какой сервис? " c </dev/tty || return 1
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#SVC[@]} ] || return 1
  PICK="${SVC[$((c-1))]}"; PICK_NAME="${SVC_NAME[$((c-1))]}"
}
do_logs(){
  step "Логи"
  pick_service || return 0
  docker inspect "$PICK" >/dev/null 2>&1 || die "контейнера $PICK нет"
  local m; echo; echo "   1) последние 100 строк"; echo "   2) только ошибки за сутки"; echo "   3) живой поток (Ctrl+C — выход)"
  read -r -p "  Как показать? [1] " m </dev/tty || return 0
  case "${m:-1}" in
    1) step "$PICK_NAME — последние 100 строк"; docker logs --tail 100 "$PICK" 2>&1 | mask;;
    2) step "$PICK_NAME — ошибки и предупреждения за 24 часа"
       local e; e="$(docker logs --since 24h "$PICK" 2>&1 | grep -iE 'error|warn|fail|panic|fatal|crit|denied|refused|timeout' | tail -60 | mask || true)"
       if [ -n "$e" ]; then echo "$e"; else ok "за сутки ни одной ошибки"; fi;;
    3) step "$PICK_NAME — живой поток (Ctrl+C — выход в меню)"; docker logs -f --tail 20 "$PICK" 2>&1 | maskf || true;;
    *) warn "нет такого режима";;
  esac
}

# ---------- сервисы ----------
human_age(){ local s=$(( $(date +%s) - $(date -d "$1" +%s 2>/dev/null || date +%s) ))
  if [ $s -lt 3600 ]; then echo "$((s/60)) мин"; elif [ $s -lt 86400 ]; then echo "$((s/3600)) ч"; else echo "$((s/86400)) дн"; fi; }
show_services(){
  svc_list; local i c st up rc
  step "Сервисы nodus"
  for i in "${!SVC[@]}"; do
    c="${SVC[$i]}"
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo нет)"
    rc="$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo -)"
    up=""; [ "$st" = running ] && up="$(human_age "$(docker inspect -f '{{.State.StartedAt}}' "$c")")"
    if [ "$NARROW" = 1 ]; then printf '  %d) %-11s %s %s\n' $((i+1)) "${SVC_NAME[$i]}" "$([ "$st" = running ] && echo "✅ $up" || echo "❌ $st")" "$([ "$rc" != 0 ] && [ "$rc" != - ] && echo "↻$rc")"
    else printf '  %d) %-12s %-10s %-8s перезапусков: %s\n' $((i+1)) "${SVC_NAME[$i]}" "$st" "${up:--}" "$rc"; fi
  done
  local others; others="$(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | grep -vE "^($C_MATRIX|$C_NGINX|$C_ELEMENT|$C_TURN|$C_LK|$C_JWT)\|" || true)"
  if [ -n "$others" ]; then
    echo; echo "  Другие контейнеры (только смотрю):"
    while IFS='|' read -r c st; do printf '     %s — %s\n' "$c" "$st"; done <<<"$others" | cutl
  fi
}
restart_one(){ # restart_one <контейнер> <имя>
  local c="$1" n="$2"
  docker restart "$c" >/dev/null || die "не перезапустился $n"
  case "$c" in
    "$C_MATRIX"|"$C_NGINX") wait_matrix && ok "$n перезапущен, Matrix отвечает" || bad "$n перезапущен, но Matrix не отвечает";;
    "$C_TURN") wait_coturn && ok "coturn перезапущен, слушает 3478/5349" || bad "coturn не слушает порты";;
    "$C_LK"|"$C_JWT") wait_rtc && ok "$n перезапущен, LiveKit и lk-jwt отвечают" || bad "LiveKit/lk-jwt не отвечают";;
    *) sleep 2; running "$c" && ok "$n перезапущен" || bad "$n не запустился";;
  esac
}
do_services(){
  show_services
  local c; echo
  read -r -p "  Номер — перезапустить сервис, «все» — перезапустить всё, Enter — назад: " c </dev/tty || return 0
  case "$c" in
    "") return 0;;
    все|all|a)
      echo "  Matrix, звонки и сайт будут недоступны ~10–30 секунд." | wrapt
      ask "Перезапускаем всё? да/нет:" || return 0
      dc -p nodus -f "${LIVE[compose]}" restart >/dev/null 2>&1 || die "не перезапустилось"
      if [ "$RTC" = on ] || [ "$RTC" = partial ]; then rtc_compose restart >/dev/null 2>&1 || true; fi
      wait_matrix && ok "Matrix отвечает" || bad "Matrix не отвечает"
      wait_coturn && ok "coturn слушает 3478/5349" || bad "coturn не слушает порты"
      if [ "$RTC" = on ]; then wait_rtc && ok "LiveKit и lk-jwt отвечают" || bad "LiveKit/lk-jwt не отвечают"; fi;;
    *) [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#SVC[@]} ] || { warn "нет такого номера"; return 0; }
       ask "Перезапустить ${SVC_NAME[$((c-1))]}? да/нет:" || return 0
       restart_one "${SVC[$((c-1))]}" "${SVC_NAME[$((c-1))]}";;
  esac
}

# ---------- отчёт ----------
do_report(){
  local f; f="/root/nodus-report-$(date +%Y%m%d-%H%M).txt"
  step "Собираю отчёт (без секретов)"
  rmask(){ mask | sed -E 's/^(  )[a-z]+[0-9a-f]{8}:/\1‹ключ›:/; s/(LIVEKIT_KEY: ")[^"]*/\1‹ключ›/'; }
  ( set +e   # отчёт собираем всегда, даже если часть команд падает
    echo "nodus report $(date '+%F %T')  ref=$(cat "$NODUS_LIB/REF" 2>/dev/null || echo ?)"
    uname -a; grep PRETTY /etc/os-release 2>/dev/null || true
    echo; echo "########## СТАТУС"; ( R=; G=; Y=; B=; N=; NARROW=0; quick_status ) 2>&1
    echo; echo "########## ПРОВЕРКА"; ( R=; G=; Y=; B=; N=; NARROW=0; do_check ) 2>&1
    echo; echo "########## КОНТЕЙНЕРЫ"; docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1
    echo; echo "########## ОБРАЗЫ"; docker images --digests 2>&1 | grep -E 'REPOSITORY|tuwunel|element|nginx|coturn|livekit|lk-jwt' || true
    for k in "${ORDER[@]}"; do
      [ -f "${LIVE[$k]}" ] || continue
      echo; echo "########## ${LIVE[$k]}"; rmask < "${LIVE[$k]}"
    done
    [ -f "$PROFILE" ] && { echo; echo "########## $PROFILE"; grep -v LE_EMAIL "$PROFILE" || true; }
    echo; echo "########## UFW"; ufw status numbered 2>&1
    echo; echo "########## ПОРТЫ"; ss -lntup 2>&1 | awk '{print $1, $5, $7}'
    echo; echo "########## СИСТЕМА"; df -h / 2>&1; free -m 2>&1; timedatectl 2>&1 | head -7
    echo; echo "########## СЕРТИФИКАТ"; openssl x509 -noout -subject -issuer -enddate -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" 2>&1
    systemctl list-timers --all --no-pager 2>/dev/null | grep -E 'certbot|nodus' || true
    svc_list
    for i in "${!SVC[@]}"; do echo; echo "########## ЛОГИ ${SVC_NAME[$i]} (последние 60)"; docker logs --tail 60 "${SVC[$i]}" 2>&1 | rmask; done
  ) > "$f" 2>&1 || true
  chmod 600 "$f"
  ok "готово: $f ($(du -h "$f" | cut -f1))"
  echo "  Скачай по SFTP и пришли Claude. Секреты и ключи замазаны; домен и IP внутри есть." | wrapt
}
