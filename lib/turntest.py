#!/usr/bin/env python3
# =====================================================================
#  nodus: настоящий тест TURN (RFC 5766) — Allocate с временным паролем,
#  как у клиентов (TURN REST: username = "<срок>:имя",
#  password = base64(HMAC-SHA1(секрет, username))).
#  Секреты читаются из конфигов и никуда не печатаются.
#  Вывод: строки  RESULT|<что>|ok|<подробности>  или  RESULT|<что>|fail|<причина>
# =====================================================================
import os, re, ssl, sys, hmac, time, base64, socket, struct, hashlib, secrets, tomllib

MAGIC = 0x2112A442
ALLOCATE, ALLOCATE_OK, ALLOCATE_ERR, REFRESH = 0x0003, 0x0103, 0x0113, 0x0004
A_USERNAME, A_MI, A_ERROR, A_LIFETIME, A_REALM, A_NONCE, A_XOR_RELAYED, A_REQ_TRANSPORT = \
    0x0006, 0x0008, 0x0009, 0x000D, 0x0014, 0x0015, 0x0016, 0x0019
TIMEOUT = 6


def attr(t, v):
    return struct.pack('!HH', t, len(v)) + v + b'\0' * ((4 - len(v) % 4) % 4)


def build(mtype, attrs, key=None):
    tid = secrets.token_bytes(12)
    body = b''.join(attrs)
    if key is not None:   # MESSAGE-INTEGRITY: длина в заголовке уже учитывает сам атрибут (24 байта)
        hdr = struct.pack('!HHI', mtype, len(body) + 24, MAGIC) + tid
        body += attr(A_MI, hmac.new(key, hdr + body, hashlib.sha1).digest())
    return struct.pack('!HHI', mtype, len(body), MAGIC) + tid + body


def parse(data):
    if len(data) < 20:
        raise ValueError('короткий ответ')
    t, l, m = struct.unpack('!HHI', data[:8])
    if m != MAGIC:
        raise ValueError('это не STUN/TURN')
    a = {}; i = 20
    while i + 4 <= 20 + l:
        at, al = struct.unpack('!HH', data[i:i + 4])
        a[at] = data[i + 4:i + 4 + al]
        i += 4 + al + ((4 - al % 4) % 4)
    return t, a


def err_text(a):
    v = a.get(A_ERROR, b'\0\0\0\0')
    return '%d %s' % ((v[2] & 7) * 100 + v[3], v[4:].decode('utf-8', 'replace'))


def xor_addr(v):
    port = struct.unpack('!H', v[2:4])[0] ^ (MAGIC >> 16)
    ip = bytes(b ^ m for b, m in zip(v[4:8], struct.pack('!I', MAGIC)))
    return '%s:%d' % (socket.inet_ntoa(ip), port)


class Conn:
    def __init__(self, proto, host, port, sni=None):
        self.proto = proto
        if proto == 'udp':
            self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.s.settimeout(TIMEOUT); self.addr = (host, port)
        else:
            raw = socket.create_connection((host, port), timeout=TIMEOUT)
            if proto == 'tls':
                ctx = ssl.create_default_context()
                raw = ctx.wrap_socket(raw, server_hostname=sni or host)
            self.s = raw; self.s.settimeout(TIMEOUT)

    def ask(self, data):
        if self.proto == 'udp':
            for _ in range(3):
                self.s.sendto(data, self.addr)
                try:
                    return parse(self.s.recvfrom(4096)[0])
                except socket.timeout:
                    continue
            raise socket.timeout('нет ответа по UDP')
        self.s.sendall(data)
        hdr = self._read(20)
        return parse(hdr + self._read(struct.unpack('!H', hdr[2:4])[0]))

    def _read(self, n):
        b = b''
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c:
                raise ConnectionError('сервер закрыл соединение')
            b += c
        return b

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def allocate(proto, host, port, secret, sni=None):
    c = None
    try:
        c = Conn(proto, host, port, sni)
        req = [attr(A_REQ_TRANSPORT, b'\x11\0\0\0')]          # relay по UDP
        t, a = c.ask(build(ALLOCATE, req))
        if t != ALLOCATE_ERR or A_REALM not in a or A_NONCE not in a:
            return False, 'странный первый ответ (ждал 401 с realm/nonce)'
        realm, nonce = a[A_REALM], a[A_NONCE]
        user = '%d:nodus-test' % (int(time.time()) + 600)
        pw = base64.b64encode(hmac.new(secret.encode(), user.encode(), hashlib.sha1).digest()).decode()
        key = hashlib.md5(('%s:%s:%s' % (user, realm.decode(), pw)).encode()).digest()
        auth = [attr(A_USERNAME, user.encode()), attr(A_REALM, realm), attr(A_NONCE, nonce)]
        t, a = c.ask(build(ALLOCATE, req + auth, key))
        if t == ALLOCATE_OK and A_XOR_RELAYED in a:
            relay = xor_addr(a[A_XOR_RELAYED])
            try:   # сразу освобождаем relay
                c.ask(build(REFRESH, [attr(A_LIFETIME, struct.pack('!I', 0))] + auth, key))
            except Exception:
                pass
            return True, 'relay выдан: ' + relay
        if t == ALLOCATE_ERR:
            e = err_text(a)
            if e.startswith('401'):
                return False, 'coturn не принял пароль (401) — секрет не совпадает или часы сервера сбиты'
            return False, 'coturn отказал: ' + e
        return False, 'неожиданный ответ 0x%04x' % t
    except ssl.SSLCertVerificationError as e:
        return False, 'сертификат на 5349 не прошёл проверку: %s' % e.verify_message
    except (socket.timeout, TimeoutError):
        return False, 'нет ответа (порт закрыт или coturn лежит)'
    except ConnectionRefusedError:
        return False, 'соединение отклонено (coturn не слушает порт)'
    except (ConnectionError, OSError, ValueError) as e:
        return False, str(e)
    finally:
        if c:
            c.close()


def main():
    D = os.environ.get('DOMAIN', ''); ip = os.environ.get('PUBLIC_IP', '') or D
    tests = []
    p = os.environ.get('P_conduit', '')
    if p and os.path.isfile(p):
        s = tomllib.loads(open(p, encoding='utf-8').read()).get('global', {}).get('turn_secret')
        if s:
            tests += [('старые звонки · UDP 3478', 'udp', ip, 3478, s),
                      ('старые звонки · TLS 5349', 'tls', D, 5349, s)]
    p = os.environ.get('P_lkyaml', '')
    if p and os.path.isfile(p):
        m = re.search(r'(?m)^[ \t]*secret:[ \t]*"?([^"\s]+)"?[ \t]*$', open(p, encoding='utf-8').read())
        if m:
            tests += [('новые звонки (LiveKit) · TLS 5349', 'tls', D, 5349, m.group(1))]
    if not tests:
        print('RESULT|TURN|fail|нечего проверять: нет ни turn_secret, ни livekit.yaml')
        return
    for label, proto, host, port, sec in tests:
        good, detail = allocate(proto, host, port, sec, sni=D)
        print('RESULT|%s|%s|%s' % (label, 'ok' if good else 'fail', detail.replace('|', '/')))


if __name__ == '__main__':
    main()
