# 🛡️ Project Nodus: Sovereign Matrix Deployment

![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)
![Rust](https://img.shields.io/badge/rust-%23000000.svg?style=for-the-badge&logo=rust&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-A81D33?style=for-the-badge&logo=debian&logoColor=white)
![Nginx](https://img.shields.io/badge/nginx-%23009639.svg?style=for-the-badge&logo=nginx&logoColor=white)
![Matrix](https://img.shields.io/badge/Matrix-000000?style=for-the-badge&logo=matrix&logoColor=white)

---

## 🇬🇧 Project Overview

**Project Nodus** is an automated deployment toolkit that provisions a **Sovereign Matrix** — a self-hosted communication node for small and medium private groups, designed to remain usable under unstable or strict corporate NAT network conditions.

The reference deployment targets **up to 50–70 users depending on available hardware, network conditions, and workload**.

### ⚙️ Key Engineering Solutions & Constraints

* **Autonomous Onboarding:** Some mobile clients may attempt to reach external services such as `matrix.org` during startup, which can be unavailable or introduce a single point of failure (SPOF).  
  **Solution:** A custom self-hosted web frontend is deployed with external integrations disabled in its `config.json`. Users register through this isolated web UI, minimising reliance on external infrastructure during onboarding. Mobile apps are then initialised via deep links that point directly to the local node.

* **Reference Hardware Limits:** The reference deployment is designed for **1 vCPU, 2 GB RAM, and 30 GB NVMe** to keep the stack cheap and predictable on low-tier VPS instances.

* **WebRTC Optimisation & NAT Traversal:** **Coturn runs in `network_mode: host`**. Bypassing `docker-proxy` allows direct UDP port mapping, reducing CPU overhead and minimising VoIP latency. To ensure media stability across strict firewalls and mobile carrier NATs, **TURNS (TURN over TLS)** is configured so media traffic can be carried over standard TLS transport.

### 🏗️ Architecture Decision: Why Conduit?

**Synapse** is the official Matrix homeserver, but it is relatively resource-heavy and can be impractical on constrained infrastructure.

This node is built on **Conduit**, a lightweight Matrix homeserver written in Rust.

* **Trade-offs:** Conduit is not intended for large public deployments with thousands of users or enterprise-grade load balancing.
* **Why it fits this project:** The goal is to run a reliable messenger for a small private circle on the cheapest practical VPS without running into avoidable memory pressure or crash-prone behaviour.

---

## 🇷🇺 Описание проекта

**Проект Nodus** — это инструментарий для автоматического развертывания **Sovereign Matrix**, self-hosted узла связи для небольших и средних закрытых групп. Он спроектирован для автономной работы в условиях нестабильной сети или строгого корпоративного NAT.

Референсная конфигурация рассчитана на **50–70 пользователей в зависимости от мощности сервера, сетевых условий и нагрузки**.

### ⚙️ Ключевые решения и ограничения

* **Автономная инициализация:** Некоторые мобильные клиенты при старте пытаются обращаться к внешним сервисам вроде `matrix.org`, что создает единую точку отказа (SPOF) при падении внешних DNS или магистральных провайдеров.  
  **Решение:** Развернут собственный веб-клиент, в котором в `config.json` отключены внешние интеграции. Регистрация проходит через этот изолированный web UI, обеспечивая полную независимость узла. Дальнейший вход со смартфонов идёт через deep links напрямую на локальный сервер.

* **Референсные ограничения по ресурсам:** Базовое развертывание рассчитано на **1 vCPU, 2 ГБ RAM и 30 ГБ NVMe**, чтобы сделать стек предсказуемым и недорогим на слабых VPS.

* **Оптимизация WebRTC и прохождение NAT:** **Coturn использует `network_mode: host`**. Это убирает `docker-proxy`, снижает накладные расходы и уменьшает задержки связи. Поскольку мобильные операторы часто используют жесткий NAT и режут нестандартный UDP-трафик, для обеспечения стабильности аудио и видео медиатрафик заворачивается в TLS (TURNS).

### 🏗️ Архитектурный выбор: почему Conduit?

**Synapse** — официальный Matrix homeserver, но он заметно тяжелее по ресурсам и хуже подходит для ограниченной инфраструктуры.

Этот проект собран на **Conduit** — лёгком Matrix homeserver на Rust.

* **Ограничения:** Conduit не рассчитан на публичные инсталляции с тысячами пользователей и не даёт enterprise-функций балансировки.
* **Почему он подходит здесь:** Цель проекта — стабильный мессенджер для узкого круга людей на самом доступном VPS без излишней нагрузки на память и без лишних точек отказа.

---

## ⚡ Quick Install / Быстрая установка

**ENG:** The stack can be deployed automatically on a fresh Debian 12 server. The setup script handles package installation, firewall configuration, certificate provisioning, and container orchestration.  
**RU:** Стек можно развернуть автоматически на чистом Debian 12. Скрипт установит пакеты, настроит firewall, получит SSL-сертификаты и запустит контейнеры.

### Before you begin / Подготовка

1. Use a clean **Debian 12 (Bookworm)** server.  
2. Point your domain to the server's public IP and wait for DNS propagation.

### Run the installation / Запуск установки

Run the command as root. The script will prompt for your domain, email, and public IP:
```bash
curl -sSL https://raw.githubusercontent.com/TimiQA/nodus/main/setup.sh | sudo bash
```

> **Note on local testing:** If you deploy behind NAT, your router must forward ports `80`, `443`, `8448`, `3478`, and `5349` to the server, otherwise certificate issuance and external connectivity may fail.

---

## 🛠️ Manual Installation / Ручная установка

**ENG:** If you prefer to deploy the infrastructure step by step and inspect each configuration, use the [Manual Installation Guide](MANUAL_SETUP.md).  
**RU:** Если вы предпочитаете разворачивать инфраструктуру пошагово и контролировать каждый конфигурационный файл, используйте [Руководство по ручной установке](MANUAL_SETUP.md).

---

## 🌐 Autonomous Onboarding / Автономная инициализация

**ENG:** Some mobile clients may try to reach external services during startup. To ensure complete autonomy and eliminate single points of failure (SPOF):  
**RU:** Некоторые мобильные клиенты при старте пытаются связаться с внешними сервисами. Для обеспечения полной автономности и устранения единой точки отказа (SPOF):

1. **Registration:** Users register via a self-hosted web client on your domain.
2. **Login:** Users open the web client or a deep link that points directly to your custom homeserver.

Example homeserver deep link (useful for iOS):
```text
https://mobile.element.io/?hs_url=https://example.ru
```

---
### iOS: Element Classic
*RU: Используйте диплинк из раздела выше для быстрого входа в один клик.*  
[![Element on App Store](https://img.shields.io/badge/App_Store-Element_Classic-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/app/element-messenger/id1083446067)  
🔗 **App Store:** `https://apps.apple.com/app/element-messenger/id1083446067`

### Android: SchildiChat
*RU: Диплинк не нужен. При запуске просто выберите «Custom Server» (Свой сервер) и введите адрес вашего узла.*  
[![SchildiChat on Google Play](https://img.shields.io/badge/Google_Play-SchildiChat-009A61?style=for-the-badge&logo=google-play&logoColor=white)](https://play.google.com/store/apps/details?id=de.spiritcroc.riotx)  
[![SchildiChat on F-Droid](https://img.shields.io/badge/F--Droid-SchildiChat-19407C?style=for-the-badge&logo=f-droid&logoColor=white)](https://f-droid.org/packages/de.spiritcroc.riotx/)  
🔗 **Google Play:** `https://play.google.com/store/apps/details?id=de.spiritcroc.riotx`  
🔗 **F-Droid:** `https://f-droid.org/packages/de.spiritcroc.riotx/`
