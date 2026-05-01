# 🛠️ Manual Installation Guide / Руководство по ручной установке: Sovereign Matrix

ENG: This section explains how to reproduce the infrastructure from scratch without using the automated deployment script.  
RU: В этом разделе описан ручной способ развертывания инфраструктуры с нуля без использования скрипта автоматической установки.

---

## Prerequisites / Требования

- A fresh Debian 12 (Bookworm) server.  
  Чистый сервер на базе Debian 12.

- A registered domain pointing to the server's public IP.  
  Зарегистрированный домен, направленный на публичный IP сервера.

---

## Step 1: System Prep & OS-Level Hardening / Подготовка системы и Firewall

RU: Установите базовые утилиты и настройте UFW так, чтобы разрешить только нужные порты для веб-трафика и WebRTC-звонков.

```bash
sudo apt update && sudo apt install -y curl git ufw htop btop certbot docker.io docker-compose dnsutils

# Allow management, web, Matrix APIs, and WebRTC (TURN/TURNS) ports
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 8448/tcp
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp         # TURNS port for TLS transport
sudo ufw allow 49152:49200/udp  # Extended WebRTC media range

sudo ufw --force enable
````

---

## Step 2: SSL/TLS Provisioning / Получение SSL-сертификатов

RU: Получите бесплатный сертификат от Let's Encrypt для безопасного HTTPS-соединения.

Make sure port 80 is free before running `certbot --standalone`.

```bash
sudo certbot certonly --standalone -d example.ru \
  --non-interactive --agree-tos -m admin@example.ru
```

---

## Step 3: Deployment / Развертывание (Docker Compose)

RU: Создайте рабочую директорию и разместите в ней следующие файлы.

### `docker-compose.yml`

```yaml
services:
  matrix:
    image: registry.gitlab.com/famedly/conduit/matrix-conduit:latest
    container_name: matrix-conduit
    restart: unless-stopped
    environment:
      CONDUIT_CONFIG: "/etc/matrix-conduit/conduit.toml"
    volumes:
      - ./conduit.toml:/etc/matrix-conduit/conduit.toml:ro
      - conduit-db:/var/lib/matrix-conduit/
    networks:
      - matrix-net

  element:
    image: vectorim/element-web:latest
    container_name: matrix-element
    restart: unless-stopped
    volumes:
      - ./element-config.json:/app/config.json:ro
    networks:
      - matrix-net

  nginx:
    image: nginx:latest
    container_name: matrix-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
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
    image: coturn/coturn:latest
    container_name: matrix-coturn
    restart: unless-stopped
    network_mode: host
    user: root
    volumes:
      - ./coturn.conf:/etc/coturn/turnserver.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    command: ["turnserver", "-c", "/etc/coturn/turnserver.conf", "-v"]

networks:
  matrix-net:
    driver: bridge

volumes:
  conduit-db:
```

---

## Step 4: Web Client Configuration / Настройка веб-клиента (Element Web)

RU: Файл `element-config.json` жёстко привязывает веб-интерфейс к вашему серверу и отключает возможность выбора других узлов.

### `element-config.json`

```json
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://example.ru",
      "server_name": "example.ru"
    }
  },
  "disable_custom_urls": true,
  "disable_guests": true,
  "disable_3pid_login": true,
  "brand": "Sovereign Matrix",
  "default_theme": "dark"
}
```

---

## Step 5: Conduit Configuration / Настройка сервера Conduit

RU: Файл `conduit.toml`. Медиафайлы будут автоматически ограничиваться для экономии места. Регистрация открыта. Не забудьте сгенерировать и вписать надёжный `turn_secret`.

### `conduit.toml`

```toml
[global]
server_name = "example.ru"
address = "0.0.0.0"
port = 6167
database_backend = "rocksdb"
database_path = "/var/lib/matrix-conduit/"
max_request_size = 20000000
allow_registration = true
allow_encryption = true
allow_federation = true
turn_uris = [
  "turns:example.ru:5349?transport=tcp",
  "turn:example.ru:3478?transport=udp",
  "turn:example.ru:3478?transport=tcp"
]
turn_secret = "TURN_SECRET_HERE"

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
```

---

## Step 6: TURN Configuration / Настройка TURN (звонки и устойчивость к фильтрации)

RU: Файл `coturn.conf`. Обязательно укажите ваш публичный IP-адрес в параметре `external-ip`.

### `coturn.conf`

```text
use-auth-secret
static-auth-secret=TURN_SECRET_HERE
realm=example.ru

listening-port=3478
tls-listening-port=5349
cert=/etc/letsencrypt/live/example.ru/fullchain.pem
pkey=/etc/letsencrypt/live/example.ru/privkey.pem
cipher-list=HIGH

min-port=49152
max-port=49200

external-ip=YOUR_SERVER_PUBLIC_IP
no-cli
```

---

## Step 7: Reverse Proxy / Настройка Nginx

RU: Файл `nginx.conf`. Nginx маршрутизирует трафик на Conduit и раздаёт веб-интерфейс Element.

### `nginx.conf`

```nginx
events {}

http {
    server {
        listen 80;
        server_name example.ru;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        listen 8448 ssl http2;
        server_name example.ru;

        ssl_certificate /etc/letsencrypt/live/example.ru/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/example.ru/privkey.pem;

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
            return 200 '{"m.homeserver":{"base_url":"https://example.ru"}}';
        }

        location /.well-known/matrix/server {
            default_type application/json;
            add_header Access-Control-Allow-Origin *;
            return 200 '{"m.server":"example.ru:443"}';
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
```

---

## 🧪 QA & System Verification / Проверка работоспособности системы

RU: После создания всех файлов запустите стек и проверьте статус компонентов.

```bash
# Start containers
sudo docker-compose up -d

# 1. Check container status
echo "--- 1. CONTAINER STATUS ---" && sudo docker-compose ps

# 2. Check API reachability through Nginx
# Wait 10-15 seconds after startup for database initialisation
echo -e "\n--- 2. MESSENGER API CHECK ---" && curl -I -s https://example.ru/_matrix/client/versions | head -n 1

# 3. Check .well-known discovery
echo -e "\n--- 3. WELL-KNOWN CHECK ---" && curl -I -s https://example.ru/.well-known/matrix/client | head -n 1

# 4. Check listening TURN ports
echo -e "\n--- 4. TURN SERVER LISTENING PORTS ---" && sudo ss -ulnp | grep 3478 && sudo ss -tlnp | grep 5349
```

---

## Notes

* The baseline deployment prioritises reliability and low resource consumption.
* Media retention is intentionally capped to keep disk usage predictable.
* The stack can be extended later with a dedicated web client or additional integration layers.
