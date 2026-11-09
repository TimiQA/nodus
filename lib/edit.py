#!/usr/bin/env python3
# =====================================================================
#  nodus: генерация и правка конфигов (используют setup.sh и nodus).
#  Пути к файлам приходят через переменные окружения P_<ключ>, параметры —
#  через DOMAIN, PUBLIC_IP и т.д. Секреты генерятся здесь и на экран не печатаются.
#  Запуск: python3 -I edit.py <операция> [<операция> ...]
# =====================================================================
import os, re, sys, json, secrets, tomllib

E = os.environ
D = E.get('DOMAIN', '')
KEYS = ['compose', 'nginx', 'conduit', 'coturn', 'element', 'lkyaml', 'lkcompose']
P = {k: E.get('P_' + k, '') for k in KEYS}


def die(m):
    print('  ✘ ' + m, file=sys.stderr)
    sys.exit(2)


def rd(k):
    p = P[k]
    return open(p, encoding='utf-8').read() if p and os.path.isfile(p) else None


def need(k):
    t = rd(k)
    if t is None:
        die('нет файла ' + (P[k] or k))
    return t


def wr(k, t):
    if not P[k]:
        die('не задан путь для ' + k)
    open(P[k], 'w', encoding='utf-8').write(t)


def gen(n=32):
    return secrets.token_hex(n)


def env(name, default=None):
    v = E.get(name, default)
    if v is None or v == '':
        die('не задан параметр ' + name)
    return v


def need_domain():
    if not re.fullmatch(r'[A-Za-z0-9.-]+\.[A-Za-z]{2,}', D):
        die('кривой домен: %r' % D)


BASE_WK = '{"m.homeserver":{"base_url":"https://%s"}}' % D
FOCI_WK = ('{"m.homeserver":{"base_url":"https://%s"},"org.matrix.msc4143.rtc_foci":'
           '[{"type":"livekit","livekit_service_url":"https://%s/livekit/jwt"}]}') % (D, D)
OFF_L = '#nodus-legacy-off# '
OFF_R = '#nodus-rtc-off# '
SEALED = '# nodus-sealed: заглушка, этот секрет никто не знает (coturn никому не выдаёт доступ)'
LEG_CT = '# nodus-calls: секрет legacy-звонков (Tuwunel)'
LEG_CD = '# nodus-calls: legacy TURN'
LK_CT = '# nodus-rtc: отдельный секрет для LiveKit'
DEF_URIS = '["turns:%s:5349?transport=tcp", "turn:%s:3478?transport=udp", "turn:%s:3478?transport=tcp"]' % (D, D, D)
SEC_RE = re.compile(r'^\s*static-auth-secret\s*=\s*(\S+)\s*$')
LKT_RE = re.compile(r'(?m)^([ \t]*secret:[ \t]*)"?([^"\s]+)"?[ \t]*$')

# =====================================================================
#  ШАБЛОНЫ базовой установки (@DOMAIN@ и т.п. подставляются при генерации)
# =====================================================================
T_COMPOSE = '''services:
  matrix:
    image: @TUWUNEL_IMAGE@
    container_name: matrix-conduit
    restart: unless-stopped
    user: "0:0"
    environment:
      CONDUIT_CONFIG: "/etc/matrix-conduit/conduit.toml"
    volumes:
      - ./conduit.toml:/etc/matrix-conduit/conduit.toml:ro
      - conduit-db:/var/lib/matrix-conduit/
    networks:
      - matrix-net

  element:
    image: @ELEMENT_IMAGE@
    container_name: matrix-element
    restart: unless-stopped
    volumes:
      - ./element-config.json:/app/config.json:ro
    networks:
      - matrix-net

  nginx:
    image: @NGINX_IMAGE@
    container_name: matrix-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "@NGINX_BIND@"
      - "8448:8448"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    networks:
      - matrix-net
    depends_on:
      - matrix
      - element

  coturn:
    image: @COTURN_IMAGE@
    container_name: matrix-coturn
    restart: unless-stopped
    network_mode: host
    user: root
    volumes:
      - ./coturn.conf:/etc/coturn/turnserver.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    command: [ "turnserver", "-c", "/etc/coturn/turnserver.conf", "-v" ]

networks:
  matrix-net:
    driver: bridge

volumes:
  conduit-db:
'''

T_NGINX = '''events {}

http {
    server {
        listen 80;
        server_name @DOMAIN@;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        listen 8448 ssl;
        http2 on;
        server_name @DOMAIN@;

        ssl_certificate /etc/letsencrypt/live/@DOMAIN@/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/@DOMAIN@/privkey.pem;

        client_max_body_size 20M;

        location / {
            proxy_pass http://matrix-element:80;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
        }

        location /.well-known/matrix/client {
            default_type application/json;
            add_header Access-Control-Allow-Origin *;
            return 200 '@BASE_WK@';
        }

        location /.well-known/matrix/server {
            default_type application/json;
            add_header Access-Control-Allow-Origin *;
            return 200 '{"m.server":"@DOMAIN@:443"}';
        }

        location /_matrix/ {
            proxy_pass http://matrix-conduit:6167;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_read_timeout 600;
        }
    }
}
'''

T_CONDUIT_HEAD = '''[global]
server_name = "@DOMAIN@"
address = "0.0.0.0"
port = 6167
database_backend = "rocksdb"
database_path = "/var/lib/matrix-conduit/"
max_request_size = 20000000
allow_registration = @ALLOW_REG@
@REG_TOKEN_LINE@allow_encryption = true
allow_federation = @FEDERATION@
@TURN_BLOCK@
[global.media]
backend = "filesystem"

[[global.media.retention]]
space = "10GB"

[[global.media.retention]]
scope = "remote"
accessed = "14d"
created = "30d"

[[global.media.retention]]
scope = "local"
accessed = "30d"

[[global.media.retention]]
scope = "thumbnail"
space = "500MB"
'''

T_TURN_BLOCK = '''turn_uris = [
  "turns:@DOMAIN@:5349?transport=tcp",
  "turn:@DOMAIN@:3478?transport=udp",
  "turn:@DOMAIN@:3478?transport=tcp"
]
turn_secret = "@TURN_SECRET@"
'''

T_COTURN = '''use-auth-secret
@SECRET_LINES@realm=@DOMAIN@

listening-port=3478
tls-listening-port=5349
cert=/etc/letsencrypt/live/@DOMAIN@/fullchain.pem
pkey=/etc/letsencrypt/live/@DOMAIN@/privkey.pem
cipher-list=HIGH

min-port=49152
max-port=49200

external-ip=@PUBLIC_IP@
no-cli
'''

T_LKYAML = '''# сгенерировано nodus
port: 7880
rtc:
  tcp_port: 7881
  port_range_start: 50100
  port_range_end: 50200
  use_external_ip: false
  node_ip: @PUBLIC_IP@
  turn_servers:
    - host: @DOMAIN@
      port: 5349
      protocol: tls
      secret: "@LK_TURN@"
room:
  auto_create: false
turn:
  enabled: false
keys:
  @LK_KEY@: @LK_SECRET@
logging:
  level: info
'''

T_LKCOMPOSE = '''# сгенерировано nodus — отдельный проект, /opt/nodus не трогает
name: nodus-rtc
services:
  livekit:
    image: @LK_IMAGE@
    container_name: matrix-livekit
    network_mode: host
    restart: unless-stopped
    command: --config /etc/livekit.yaml
    volumes:
      - ./livekit.yaml:/etc/livekit.yaml:ro
    mem_limit: 512m
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
  lk-jwt:
    image: @JWT_IMAGE@
    container_name: matrix-lk-jwt
    network_mode: host
    restart: unless-stopped
    depends_on: [livekit]
    environment:
      LIVEKIT_URL: "wss://@DOMAIN@/livekit/sfu"
      LIVEKIT_KEY: "@LK_KEY@"
      LIVEKIT_SECRET: "@LK_SECRET@"
      LIVEKIT_FULL_ACCESS_HOMESERVERS: "@DOMAIN@"
      LIVEKIT_JWT_BIND: "0.0.0.0:8080"
    mem_limit: 128m
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
'''

T_NGINX_RTC = '''# nodus-rtc BEGIN: MatrixRTC (lk-jwt + LiveKit на хосте)
location ^~ /livekit/jwt/ {
    proxy_pass http://@GW@:8080/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_connect_timeout 5s;
    proxy_read_timeout 30s;
}
location ^~ /livekit/sfu/ {
    proxy_pass http://@GW@:7880/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $nodus_rtc_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_connect_timeout 5s;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
# nodus-rtc END'''


def fill(t, **kw):
    for k, v in kw.items():
        t = t.replace('@' + k + '@', v)
    left = re.findall(r'@[A-Z_]+@', t)
    if left:
        die('в шаблоне не подставлено: ' + ', '.join(sorted(set(left))))
    return t


# ---------- coturn ----------
def ct_secrets(t):
    return [m.group(1) for m in map(SEC_RE.match, t.split('\n')) if m]


def ct_insert(L, val, comment):
    idx = [i for i, l in enumerate(L) if SEC_RE.match(l)]
    if idx:
        pos = idx[-1] + 1
    else:
        u = [i for i, l in enumerate(L) if re.match(r'\s*use-auth-secret\b', l)]
        if not u:
            die('в coturn.conf нет use-auth-secret')
        pos = u[0] + 1
    return L[:pos] + [comment, 'static-auth-secret=' + val] + L[pos:]


def ct_replace(t, old, new):
    L = t.split('\n'); n = 0
    for i, l in enumerate(L):
        m = SEC_RE.match(l)
        if m and m.group(1) == old:
            L[i] = 'static-auth-secret=' + new; n += 1
    if n == 0:
        die('в coturn.conf нет строки с текущим секретом — конфиги рассинхронизированы')
    return '\n'.join(L)


def ct_remove(t, val=None, after=None):
    out = []
    for l in t.split('\n'):
        m = SEC_RE.match(l)
        if m and ((val is not None and m.group(1) == val) or (after and out and out[-1].startswith(after))):
            if out and out[-1].startswith('# nodus-'):
                out.pop()
            continue
        out.append(l)
    if not any(SEC_RE.match(l) for l in out):
        out = ct_insert(out, gen(), SEALED)   # coturn без секрета не оставляем
    return '\n'.join(out)


def ct_add(t, val, comment):
    out = []; drop = False
    for l in t.split('\n'):
        if l.startswith('# nodus-sealed'):
            drop = True; continue
        if drop and SEC_RE.match(l):
            drop = False; continue
        drop = False; out.append(l)
    return '\n'.join(ct_insert(out, val, comment))


def ct_set_ip(t, ip):
    t2, n = re.subn(r'(?m)^external-ip=.*$', 'external-ip=' + ip, t)
    if n != 1:
        die('в coturn.conf ждал одну строку external-ip, нашёл %d' % n)
    return t2


# ---------- conduit.toml ----------
def toml(t):
    try:
        return tomllib.loads(t)
    except Exception as e:
        die('conduit.toml не парсится: %s' % e)


def glob(t):
    g = toml(t).get('global', {})
    if D and g.get('server_name') != D:
        die('в conduit.toml server_name не %s' % D)
    return g


def greg(L):
    s = None
    for i, l in enumerate(L):
        if s is None:
            if re.match(r'\s*\[global\]\s*(#.*)?$', l):
                s = i + 1
        elif re.match(r'\s*\[', l):
            return s, i
    if s is None:
        die('в conduit.toml нет секции [global]')
    return s, len(L)


def turn_spans(L):
    s, e = greg(L); sp = []; i = s
    while i < e:
        m = re.match(r'\s*turn_\w+\s*=\s*(.*)$', L[i])
        if m:
            j = i; depth = m.group(1).count('[') - m.group(1).count(']')
            while depth > 0 and j + 1 < e:
                j += 1; depth += L[j].count('[') - L[j].count(']')
            sp.append((i, j)); i = j + 1
        else:
            i += 1
    return sp


def legacy_state(t):
    g = glob(t)
    if g.get('turn_secret'):
        return 'on'
    if any(k.startswith('turn_') for k in g):
        return 'other'
    if OFF_L in t:
        return 'off'
    return 'removed'


def set_turn_secret(t, new):
    t2, n = re.subn(r'(?m)^([ \t]*turn_secret[ \t]*=[ \t]*)("[^"\n]*"|\'[^\'\n]*\')',
                    lambda m: m.group(1) + '"' + new + '"', t)
    if n != 1:
        die('ждал ровно одну строку turn_secret, нашёл %d' % n)
    return t2


# ---------- nginx ----------
def ng_foci(t, on):
    a, b = (BASE_WK, FOCI_WK) if on else (FOCI_WK, BASE_WK)
    if t.count(a) == 0 and t.count(b) == 1:
        return t
    if t.count(a) != 1:
        die('в nginx.conf не нашёл ожидаемую строку /.well-known/matrix/client')
    return t.replace(a, b)


def ng_remove_blocks(t):
    out = []; inside = False
    for l in t.split('\n'):
        s = l.strip()
        if s.startswith('# nodus-rtc BEGIN'):
            if inside:
                die('nginx.conf: BEGIN без END')
            inside = True; continue
        if s.startswith('# nodus-rtc END'):
            if not inside:
                die('nginx.conf: END без BEGIN')
            inside = False; continue
        if not inside:
            out.append(l)
    if inside:
        die('nginx.conf: BEGIN без END')
    t2 = '\n'.join(out)
    if 'nodus_rtc_upgrade' in t2 or '/livekit/' in t2:
        die('в nginx.conf остались куски nodus-rtc вне блоков — руками')
    return t2


def ng_add_blocks(t, gw):
    if 'nodus-rtc' in t:
        die('в nginx.conf уже есть блок nodus-rtc')
    L = t.split('\n')
    loc = [i for i, l in enumerate(L) if re.match(r'\s*location\s+(?:\^~\s+|=\s+)?/_matrix/?\s*\{', l)]
    http = [i for i, l in enumerate(L) if re.match(r'\s*http\s*\{', l)]
    if len(loc) != 1:
        die('ждал ровно 1 "location /_matrix/ {", нашёл %d' % len(loc))
    if len(http) != 1:
        die('ждал ровно 1 "http {", нашёл %d' % len(http))
    ind = re.match(r'\s*', L[loc[0]]).group(0)
    blk = fill(T_NGINX_RTC, GW=gw).split('\n')
    L[loc[0]:loc[0]] = [ind + x if x else x for x in blk]
    hind = re.match(r'\s*', L[http[0]]).group(0) + '    '
    L[http[0] + 1:http[0] + 1] = [hind + '# nodus-rtc BEGIN',
                                  hind + "map $http_upgrade $nodus_rtc_upgrade { default upgrade; '' close; }",
                                  hind + '# nodus-rtc END']
    return ng_foci('\n'.join(L), True)


# ---------- element ----------
def el_set(t, on):
    d = json.loads(t); o = json.loads(t)
    if on:
        d.setdefault('element_call', {})['use_exclusively'] = True
    else:
        ec = d.get('element_call')
        if isinstance(ec, dict):
            ec.pop('use_exclusively', None)
            if not ec:
                d.pop('element_call')
    return t if d == o else json.dumps(d, ensure_ascii=False, indent=2) + '\n'


# ---------- conduit: новые звонки ----------
def cd_rtc(t, mode):
    L = t.split('\n')
    if mode == 'off':
        t2 = '\n'.join(OFF_R + l if re.match(r'\s*livekit_url\s*=', l) else l for l in L)
        if 'livekit_url' in glob(t2).get('well_known', {}):
            die('не смог выключить livekit_url')
    elif mode == 'on':
        t2 = '\n'.join(l[len(OFF_R):] if l.startswith(OFF_R) else l for l in L)
        wk = glob(t2).get('well_known', {})
        if 'livekit_url' not in wk:
            if wk:
                die('в [global.well_known] нет livekit_url — разберёмся руками')
            t2 = t2.rstrip('\n') + ('\n\n# nodus-rtc BEGIN\n[global.well_known]\nclient = "https://%s"\n'
                                    'livekit_url = "https://%s/livekit/jwt"\n# nodus-rtc END\n') % (D, D)
    else:
        out = []; inside = False
        for l in L:
            s = l.strip()
            if s.startswith('# nodus-rtc BEGIN'):
                inside = True; continue
            if s.startswith('# nodus-rtc END'):
                inside = False; continue
            if inside or l.startswith(OFF_R):
                continue
            out.append(l)
        t2 = '\n'.join(out).rstrip('\n') + '\n'
        if 'livekit_url' in glob(t2).get('well_known', {}):
            die('livekit_url в conduit.toml не из блока nodus-rtc — руками')
    glob(t2)
    return t2


# =====================================================================
#  ОПЕРАЦИИ
# =====================================================================
def op_state():
    t = need('conduit'); c = rd('coturn') or ''; n = rd('nginx') or ''; y = rd('lkyaml'); e = rd('element')
    ls = legacy_state(t); secs = ct_secrets(c)
    sync = ('1' if glob(t)['turn_secret'] in secs else '0') if ls == 'on' else '-'
    lks = '-'
    if y is not None:
        m = LKT_RE.search(y); lks = '1' if m and m.group(2) in secs else '0'
    wk = glob(t).get('well_known', {})
    cd = 'on' if 'livekit_url' in wk else ('off' if OFF_R in t else 'none')
    el = '0'
    if e:
        ec = json.loads(e).get('element_call')
        el = '1' if isinstance(ec, dict) and ec.get('use_exclusively') is True else '0'
    print('LEGACY=%s\nLEGACY_SYNC=%s\nLK_TURN_SYNC=%s\nRTC_NGINX=%d\nRTC_FOCI=%d\nRTC_CONDUIT=%s\nRTC_ELEMENT=%s\nCT_SEALED=%d' % (
        ls, sync, lks, 'nodus-rtc BEGIN: MatrixRTC' in n, FOCI_WK in n, cd, el, '# nodus-sealed' in c))


def op_derive():
    """Профиль из существующих конфигов (для серверов, поставленных до v2)."""
    out = {}
    t = rd('conduit')
    if t:
        g = toml(t).get('global', {})
        out['DOMAIN'] = g.get('server_name', '')
        out['FEDERATION'] = 'true' if g.get('allow_federation') else 'false'
        out['REG_MODE'] = 'closed' if not g.get('allow_registration') else ('token' if g.get('registration_token') else 'open')
    c = rd('coturn')
    if c:
        m = re.search(r'(?m)^external-ip=(\S+)', c)
        if m:
            out['PUBLIC_IP'] = m.group(1)
    dc = rd('compose')
    if dc:
        m = re.search(r'"127\.0\.0\.1:(\d+):443"', dc)
        if m:
            out['PROXY_MODE'] = 'behind'; out['NGINX_PORT'] = m.group(1)
        elif re.search(r'"(0\.0\.0\.0:)?443:443"', dc):
            out['PROXY_MODE'] = 'direct'; out['NGINX_PORT'] = '443'
    e = rd('element')
    if e:
        try:
            out['BRAND'] = json.loads(e).get('brand', '')
        except Exception:
            pass
    for k, v in out.items():
        if re.fullmatch(r'[A-Za-z0-9._: -]*', str(v)):   # только безопасные значения
            print('%s=%s' % (k, v))


def op_render_base():
    """Свежие конфиги для новой установки. Пишет compose, nginx, conduit, coturn, element."""
    need_domain()
    ip = env('PUBLIC_IP')
    if not re.fullmatch(r'\d{1,3}(\.\d{1,3}){3}', ip):
        die('кривой IP: %r' % ip)
    calls = env('CALLS')
    if calls not in ('legacy', 'new', 'both'):
        die('CALLS: legacy | new | both')
    reg = env('REG_MODE')
    if reg not in ('token', 'open', 'closed'):
        die('REG_MODE: token | open | closed')
    port = env('NGINX_PORT')
    bind = '443:443' if env('PROXY_MODE') == 'direct' else '127.0.0.1:%s:443' % port
    brand = E.get('BRAND') or 'Nodus'
    turn = E.get('TURN_SECRET') or gen(16)
    legacy = calls in ('legacy', 'both')

    wr('compose', fill(T_COMPOSE, TUWUNEL_IMAGE=env('TUWUNEL_IMAGE'), ELEMENT_IMAGE=env('ELEMENT_IMAGE'),
                       NGINX_IMAGE=env('NGINX_IMAGE'), COTURN_IMAGE=env('COTURN_IMAGE'), NGINX_BIND=bind))
    wr('nginx', fill(T_NGINX, DOMAIN=D, BASE_WK=BASE_WK))
    cd = fill(T_CONDUIT_HEAD, DOMAIN=D,
              ALLOW_REG='false' if reg == 'closed' else 'true',
              REG_TOKEN_LINE=('registration_token = "%s"\n' % env('REG_TOKEN')) if reg == 'token' else '',
              FEDERATION='true' if E.get('FEDERATION') == 'true' else 'false',
              TURN_BLOCK=fill(T_TURN_BLOCK, DOMAIN=D, TURN_SECRET=turn) if legacy else '')
    g = glob(cd)
    if legacy and g.get('turn_secret') != turn:
        die('turn_secret не собрался')
    wr('conduit', cd)
    secret_lines = ('static-auth-secret=%s\n' % turn) if legacy else (SEALED + '\nstatic-auth-secret=%s\n' % gen())
    wr('coturn', fill(T_COTURN, DOMAIN=D, PUBLIC_IP=ip, SECRET_LINES=secret_lines))
    el = {'default_server_config': {'m.homeserver': {'base_url': 'https://' + D, 'server_name': D}},
          'disable_custom_urls': True, 'disable_guests': True, 'disable_3pid_login': True,
          'brand': brand, 'default_theme': 'dark'}
    wr('element', json.dumps(el, ensure_ascii=False, indent=2) + '\n')


def op_rtc_add():
    """Добавить новые звонки (LiveKit + lk-jwt) к существующим конфигам."""
    need_domain()
    ip = env('PUBLIC_IP'); gw = env('GW')
    if not re.fullmatch(r'\d{1,3}(\.\d{1,3}){3}', gw):
        die('кривой адрес шлюза docker: %r' % gw)
    n = need('nginx'); t = need('conduit'); c = need('coturn'); e = need('element')
    key, sec, turn = 'nodus' + gen(4), gen(32), gen(32)
    wr('lkyaml', fill(T_LKYAML, PUBLIC_IP=ip, DOMAIN=D, LK_TURN=turn, LK_KEY=key, LK_SECRET=sec))
    wr('lkcompose', fill(T_LKCOMPOSE, LK_IMAGE=env('LK_IMAGE'), JWT_IMAGE=env('JWT_IMAGE'),
                         DOMAIN=D, LK_KEY=key, LK_SECRET=sec))
    wr('nginx', ng_add_blocks(n, gw))
    wr('conduit', cd_rtc(t, 'on'))
    wr('coturn', ct_add(c, turn, LK_CT))
    wr('element', el_set(e, True))


def op_legacy_rotate():
    t = need('conduit'); c = need('coturn')
    old = glob(t).get('turn_secret') or die('turn_secret не задан')
    if old not in ct_secrets(c):
        die('в coturn.conf нет текущего turn_secret — конфиги рассинхронизированы')
    new = gen(); t2 = set_turn_secret(t, new)
    if glob(t2).get('turn_secret') != new:
        die('turn_secret не поменялся')
    wr('conduit', t2); wr('coturn', ct_replace(c, old, new))


def op_legacy_off(remove):
    t = need('conduit'); c = need('coturn'); st = legacy_state(t)
    L = t.split('\n'); old = None
    if st == 'on':
        old = glob(t)['turn_secret']
        for a, b in reversed(turn_spans(L)):
            if remove:
                del L[a:b + 1]
            else:
                for k in range(a, b + 1):
                    L[k] = OFF_L + L[k]
    if remove:
        L = [l for l in L if not l.startswith(OFF_L) and not l.startswith(LEG_CD)]
    t2 = '\n'.join(L)
    if any(k.startswith('turn_') for k in glob(t2)):
        die('после правки в [global] остались turn_* — руками')
    wr('conduit', t2)
    if old:
        wr('coturn', ct_remove(c, val=old))


def op_legacy_on():
    t = need('conduit'); c = need('coturn')
    if legacy_state(t) == 'on':
        die('legacy уже включены')
    new = gen()
    if OFF_L in t:
        t2 = '\n'.join(l[len(OFF_L):] if l.startswith(OFF_L) else l for l in t.split('\n'))
        if 'turn_secret' not in glob(t2):
            die('в выключенном блоке нет turn_secret — руками')
        t2 = set_turn_secret(t2, new)
    else:
        L = t.split('\n'); s, e = greg(L); k = e
        while k > s and L[k - 1].strip() == '':
            k -= 1
        L[k:k] = ['', LEG_CD, 'turn_uris = ' + DEF_URIS, 'turn_secret = "%s"' % new]
        t2 = '\n'.join(L)
    g = glob(t2)
    if g.get('turn_secret') != new or not g.get('turn_uris'):
        die('не собрал turn_* в conduit.toml')
    wr('conduit', t2); wr('coturn', ct_add(c, new, LEG_CT))


def op_lkturn_rotate():
    y = need('lkyaml'); c = need('coturn')
    ms = list(LKT_RE.finditer(y))
    if len(ms) != 1:
        die('в livekit.yaml ждал ровно один secret у turn_servers, нашёл %d' % len(ms))
    m = ms[0]; old = m.group(2); new = gen()
    if old not in ct_secrets(c):
        die('в coturn.conf нет TURN-секрета LiveKit — конфиги рассинхронизированы')
    wr('lkyaml', y[:m.start()] + m.group(1) + '"' + new + '"' + y[m.end():])
    wr('coturn', ct_replace(c, old, new))


def op_lkapi_rotate():
    y = need('lkyaml'); dc = need('lkcompose')
    m = re.search(r'(?m)^keys:[ \t]*\n([ \t]+)([A-Za-z0-9_-]+):[ \t]*"?([^"\s]+)"?[ \t]*$', y)
    if not m:
        die('в livekit.yaml не нашёл keys:')
    nk = 'nodus' + gen(4); ns = gen(32)
    y2 = y[:m.start()] + 'keys:\n' + m.group(1) + nk + ': ' + ns + y[m.end():]
    dc2, n1 = re.subn(r'(?m)^([ \t]*LIVEKIT_KEY:[ \t]*).*$', lambda x: x.group(1) + '"%s"' % nk, dc)
    dc2, n2 = re.subn(r'(?m)^([ \t]*LIVEKIT_SECRET:[ \t]*).*$', lambda x: x.group(1) + '"%s"' % ns, dc2)
    if n1 != 1 or n2 != 1:
        die('в compose lk-jwt не нашёл LIVEKIT_KEY/LIVEKIT_SECRET')
    wr('lkyaml', y2); wr('lkcompose', dc2)


def op_rtc(mode):
    n = need('nginx'); t = need('conduit'); e = need('element')
    if mode == 'on':
        if 'nodus-rtc BEGIN: MatrixRTC' not in n:
            die('в nginx.conf нет блока /livekit — ставь заново: nodus rtc-install')
        n = ng_foci(n, True)
    else:
        n = ng_foci(n, False)
        if mode == 'remove':
            n = ng_remove_blocks(n)
    wr('nginx', n); wr('conduit', cd_rtc(t, mode)); wr('element', el_set(e, mode == 'on'))
    if mode == 'remove':
        c = need('coturn'); y = rd('lkyaml'); k = None
        if y is not None:
            m = LKT_RE.search(y); k = m.group(2) if m else None
        wr('coturn', ct_remove(c, val=k, after='# nodus-rtc'))


def op_set_ip():
    """Новый публичный IP (переезд): coturn external-ip и livekit node_ip."""
    ip = env('PUBLIC_IP')
    if not re.fullmatch(r'\d{1,3}(\.\d{1,3}){3}', ip):
        die('кривой IP: %r' % ip)
    wr('coturn', ct_set_ip(need('coturn'), ip))
    y = rd('lkyaml')
    if y is not None:
        y2, n = re.subn(r'(?m)^([ \t]*node_ip:[ \t]*).*$', lambda m: m.group(1) + ip, y)
        if n != 1:
            die('в livekit.yaml ждал одну строку node_ip')
        wr('lkyaml', y2)


OPS = {'state': op_state, 'derive': op_derive, 'render-base': op_render_base, 'rtc-add': op_rtc_add,
       'set-ip': op_set_ip, 'legacy-rotate': op_legacy_rotate,
       'legacy-off': lambda: op_legacy_off(False), 'legacy-remove': lambda: op_legacy_off(True),
       'legacy-on': op_legacy_on, 'lkturn-rotate': op_lkturn_rotate, 'lkapi-rotate': op_lkapi_rotate,
       'rtc-off': lambda: op_rtc('off'), 'rtc-on': lambda: op_rtc('on'), 'rtc-remove': lambda: op_rtc('remove')}

if __name__ == '__main__':
    for op in sys.argv[1:]:
        if op not in OPS:
            die('неизвестная операция ' + op)
        OPS[op]()
