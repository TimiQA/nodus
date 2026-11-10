# shellcheck shell=bash
# =====================================================================
#  nodus: обслуживание — обновление образов (с откатом), обновление nodus,
#  сертификат, автобэкап. Подключается из tools/nodus.
# =====================================================================

# ---------- обновление образов ----------
upd_targets(){ # UPD_C — контейнеры, UPD_N — имена
  svc_list; UPD_C=(); UPD_N=(); local i
  for i in "${!SVC[@]}"; do docker inspect "${SVC[$i]}" >/dev/null 2>&1 && { UPD_C+=("${SVC[$i]}"); UPD_N+=("${SVC_NAME[$i]}"); }; done
}
upd_up(){ # пересоздать то, что поменялось (compose сам видит новые образы)
  dc -p nodus -f "${LIVE[compose]}" up -d >/dev/null 2>&1 || return 1
  if [ -f "${LIVE[lkcompose]}" ] && running "$C_LK"; then rtc_compose up -d >/dev/null 2>&1 || return 1; fi
  return 0
}
upd_verify(){ # 0 — всё поднялось
  local okk=0
  wait_matrix || { bad "Matrix не отвечает"; okk=1; }
  wait_coturn || { bad "coturn не слушает 3478/5349"; okk=1; }
  if [ "$RTC_WAS_ON" = 1 ]; then
    wait_rtc || { bad "LiveKit/lk-jwt не отвечают"; okk=1; }
    [ "$(lcode /livekit/jwt/healthz)" = 200 ] || { bad "lk-jwt не доступен через nginx"; okk=1; }
  fi
  [ "$(lcode /)" = 200 ] || { bad "Element Web не открывается"; okk=1; }
  [[ "$(lbody /_matrix/client/versions)" == *simplified_msc3575* ]] || warn "Tuwunel не объявляет sliding sync — Element X может не работать"
  return $okk
}
do_update_images(){
  step "Обновление образов"
  load_state; upd_targets
  RTC_WAS_ON=0; [ "$RTC" = on ] && RTC_WAS_ON=1
  [ "$(lcode /_matrix/client/versions)" = 200 ] || die "Matrix сейчас не отвечает — сначала разберёмся (пункт 1 на главном экране)"
  local i c img old new changed=() matrix_changed=0 bk
  echo "  Проверяю, есть ли новые версии (скачиваю, ничего не перезапускаю)..."
  declare -A OLD IMG
  for i in "${!UPD_C[@]}"; do
    c="${UPD_C[$i]}"
    IMG[$c]="$(docker inspect -f '{{.Config.Image}}' "$c")"; OLD[$c]="$(docker inspect -f '{{.Image}}' "$c")"
  done
  for img in $(printf '%s\n' "${IMG[@]}" | sort -u); do
    docker pull -q "$img" >/dev/null 2>&1 || warn "не скачался $img (пропускаю)"
  done
  for i in "${!UPD_C[@]}"; do
    c="${UPD_C[$i]}"
    new="$(docker image inspect -f '{{.Id}}' "${IMG[$c]}" 2>/dev/null || true)"; [ -n "$new" ] || new="${OLD[$c]}"
    if [ "$new" != "${OLD[$c]}" ]; then changed+=("$i"); [ "$c" = "$C_MATRIX" ] && matrix_changed=1; fi
  done
  if [ ${#changed[@]} -eq 0 ]; then ok "всё уже последней версии"; return 0; fi
  step "Есть обновления"
  for i in "${changed[@]}"; do echo "  • ${UPD_N[$i]}  (${IMG[${UPD_C[$i]}]})"; done | cutl
  echo "  Перезапустятся только они, простой — до минуты." | wrapt
  if [ "$CHECK_ONLY" = 1 ]; then ok "CHECK_ONLY: ничего не менял (новые образы скачаны, но не запущены)"; return 0; fi
  ask "Обновляем? да/нет:" || { ok "Ок, работают прежние версии."; return 0; }
  if [ $matrix_changed = 1 ] && [ "$YES" != 1 ]; then
    { echo "  ⚠ Новый Tuwunel может обновить базу так, что старая версия её уже не откроет."
      echo "    Поэтому перед ним — полный бэкап (Matrix встанет на ~3 сек)."; } | wrapt
    if ask "Сделать полный бэкап сейчас? (очень советую) да/нет:"; then nodus-backup || die "бэкап не получился — обновление отменено"; fi
  fi
  bk="$STATE_ROOT/$(date +%Y%m%d-%H%M%S)-update"; mkdir -p "$bk"
  for i in "${changed[@]}"; do c="${UPD_C[$i]}"; echo "$c|${IMG[$c]}|${OLD[$c]}" >> "$bk/rollback"; done
  for k in "${ORDER[@]}"; do [ -f "${LIVE[$k]}" ] && cp -a "${LIVE[$k]}" "$bk/$k"; done

  step "Обновляю"
  if upd_up && upd_verify; then
    ok "всё поднялось на новых версиях"
    { echo "# версии, на которых nodus работал $(date '+%F %T')"
      for i in "${!UPD_C[@]}"; do c="${UPD_C[$i]}"
        echo "${UPD_N[$i]}: $(docker inspect -f '{{.Config.Image}}' "$c") $(docker image inspect -f '{{index .RepoDigests 0}}' "$(docker inspect -f '{{.Image}}' "$c")" 2>/dev/null || true)"
      done; } > "$NODUS_DIR/versions.lock"
    ok "рабочие версии записаны в $NODUS_DIR/versions.lock"
    if ask "Удалить старые версии образов (освободит место)? да/нет:"; then
      while IFS='|' read -r c img old; do docker rmi "$old" >/dev/null 2>&1 || true; done < "$bk/rollback"
      docker image prune -f >/dev/null 2>&1 || true
      ok "старые образы удалены. Свободно: $(df -h --output=avail / | tail -1 | tr -d ' ')"
    else echo "  Старые образы оставил — можно откатиться руками: $bk/rollback" | wrapt; fi
    return 0
  fi
  step "ОТКАТ на прежние версии"
  while IFS='|' read -r c img old; do docker tag "$old" "$img" && ok "$img → прежняя версия"; done < "$bk/rollback"
  upd_up || true
  if upd_verify; then ok "откатился, всё работает на прежних версиях"
  else
    bad "после отката не всё поднялось"
    { echo "  Если не поднимается Matrix — новая версия могла обновить базу. Тогда помогает"
      echo "  восстановление из полного бэкапа. Сделай отчёт (пункт 5) и напиши Claude."; } | wrapt
  fi
  return 1
}

# ---------- обновление самого nodus ----------
do_self_update(){
  local ref="${NODUS_REF:-main}" repo="${NODUS_REPO:-TimiQA/nodus}" t
  step "Обновление nodus и nodus-backup из $repo@$ref"
  echo "  Конфиги и контейнеры не трогаются, только сами команды." | wrapt
  [ "$CHECK_ONLY" = 1 ] && { ok "CHECK_ONLY: ничего не менял"; return 0; }
  ask "Обновить? да/нет:" || return 0
  t="$(mktemp -d)"
  curl -fsSL "https://codeload.github.com/$repo/tar.gz/$ref" | tar -xz -C "$t" || die "не скачался $repo@$ref"
  local d; d="$(find "$t" -mindepth 1 -maxdepth 1 -type d | head -1)"
  NODUS_REF="$ref" NODUS_REPO="$repo" bash "$d/setup.sh" --tools --yes || die "обновление не прошло"
  rm -rf "$t"
  ok "nodus обновлён — запусти его заново: nodus"
  exit 0
}

# ---------- сертификат ----------
cert_status(){
  local f="/etc/letsencrypt/live/$DOMAIN/fullchain.pem" cd iss
  cd="$(cert_days)"
  if [ -z "$cd" ]; then warn "сертификата для $DOMAIN нет"; return 0; fi
  iss="$(openssl x509 -noout -issuer -in "$f" 2>/dev/null | sed 's/.*O *= *\([^,]*\).*/\1/')"
  [[ "$iss" == *STAGING* || "$iss" == *Fake* ]] && warn "это тестовый (staging) сертификат — браузеры ему не доверяют"
  if [ "$cd" -lt 21 ]; then warn "действует ещё $cd дн. ($iss)"; else ok "действует ещё $cd дн. ($iss)"; fi
  if systemctl is-active --quiet certbot.timer 2>/dev/null; then
    ok "автопродление: $(systemctl list-timers certbot.timer --no-legend 2>/dev/null | awk '{print "следующая проверка " $1 " " $2}' || echo включено)"
  elif [ -f /etc/cron.d/certbot ]; then ok "автопродление: через cron"
  else warn "автопродления не вижу"; fi
  [ -x /etc/letsencrypt/renewal-hooks/pre/10-stop-matrix-nginx.sh ] && ok "хуки продления на месте" || warn "хуков продления нет"
}
cert_certbot_ok(){ [ -f "/etc/letsencrypt/renewal/$DOMAIN.conf" ] || die "сертификат не от certbot (нет renewal/$DOMAIN.conf) — продлевать нечем"; }
cert_after(){
  sleep 2
  running "$C_NGINX" || { docker start "$C_NGINX" >/dev/null 2>&1 || true; warn "nginx пришлось запустить руками — проверь хук post"; }
  wait_matrix && ok "nginx снова работает, Matrix отвечает" || bad "Matrix не отвечает — nodus → Сервисы"
}
do_cert_dry_run(){
  step "Пробное продление (по-настоящему ничего не продлевает)"
  cert_certbot_ok
  echo "  Хуки остановят nginx на ~10–30 секунд: сайт и Matrix будут недоступны." | wrapt
  ask "Проверяем? да/нет:" || return 0
  local out rc=0
  out="$(certbot renew --dry-run --cert-name "$DOMAIN" 2>&1)" || rc=$?
  echo "$out" | tail -6 | sed 's/^/  | /'
  cert_after
  if [ $rc = 0 ]; then ok "пробное продление прошло — автопродление сработает"
  else bad "пробное продление не прошло — причина в строках выше"; fi
}
do_cert_renew(){
  step "Продлить сертификат сейчас"
  cert_certbot_ok
  local cd; cd="$(cert_days)"
  { echo "  Сейчас осталось ${cd:-?} дн. Обычно certbot продлевает сам за 30 дней."
    echo "  Let's Encrypt даёт ~5 продлений одного домена в неделю — без нужды не жми."
    echo "  nginx встанет на ~10–30 секунд, coturn перезапустится."; } | wrapt
  ask "Продлеваем? да/нет:" || return 0
  local out rc=0
  out="$(certbot renew --force-renewal --cert-name "$DOMAIN" 2>&1)" || rc=$?
  echo "$out" | tail -6 | sed 's/^/  | /'
  cert_after
  [ $rc = 0 ] && ok "сертификат продлён" || bad "certbot не продлил — причина в строках выше"
  wait_coturn && ok "coturn с новым сертификатом слушает 5349" || bad "coturn не слушает 5349"
  cert_status
}

# ---------- автобэкап (systemd timer) ----------
backup_schedule_status(){
  if systemctl is-enabled --quiet nodus-backup.timer 2>/dev/null; then
    local nx; nx="$(systemctl list-timers nodus-backup.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}' || true)"
    ok "автобэкап включён: $(grep -h '^OnCalendar=' /etc/systemd/system/nodus-backup.timer 2>/dev/null | sed 's/OnCalendar=//; s/Sun \*-\*-\*/по воскресеньям/; s/\*-\*-\*/каждый день/')${nx:+, следующий: $nx}"
  else echo "  автобэкап выключен"; fi
}
do_backup_schedule(){
  step "Автобэкап"
  backup_schedule_status
  { echo "  Делает полный nodus-backup ночью (Matrix встаёт на ~3 сек), хранит 3 последних."
    echo "  Скачивать к себе всё равно нужно руками."; } | wrapt
  echo; echo "   1) раз в неделю (вс, ~04:17)"; echo "   2) каждый день (~04:17)"; echo "   3) выключить"; echo "   0) назад"
  local c cal; read -r -p "  Выбор: " c </dev/tty || return 0
  case "$c" in 1) cal='Sun *-*-* 04:17:00';; 2) cal='*-*-* 04:17:00';;
    3) systemctl disable --now nodus-backup.timer >/dev/null 2>&1 || true; ok "автобэкап выключен"; return 0;;
    *) return 0;; esac
  command -v nodus-backup >/dev/null || die "нет команды nodus-backup"
  cat > /etc/systemd/system/nodus-backup.service <<'EOF'
[Unit]
Description=nodus: полный бэкап сервера
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nodus-backup
EOF
  cat > /etc/systemd/system/nodus-backup.timer <<EOF
[Unit]
Description=nodus: автобэкап

[Timer]
OnCalendar=$cal
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now nodus-backup.timer >/dev/null 2>&1 || die "systemd не включил таймер"
  backup_schedule_status
  echo "  Лог последнего автобэкапа: journalctl -u nodus-backup -n 30" | wrapt
}
