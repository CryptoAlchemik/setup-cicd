# CI/CD Setup — biohacker-bot

Этот каталог содержит артефакты CI/CD: SSH-ключи деплоя, `.env` файлы стейджей и лог-файлы настройки.  
**Каталог добавлен в `.gitignore` — никогда не коммитить.**

---

## Содержимое каталога

```
.cicd/
├── README.md               # этот файл
├── config.md               # конфиг setup-скрипта (хосты, пароли, статус фаз)
├── deploy_test             # SSH приватный ключ для деплоя на test
├── deploy_test.pub         # SSH публичный ключ (test)
├── deploy_prod             # SSH приватный ключ для деплоя на prod
├── deploy_prod.pub         # SSH публичный ключ (prod)
├── .env.test               # переменные окружения для test-сервера
├── .env.prod               # переменные окружения для prod-сервера
└── setup_<timestamp>.log   # лог каждого запуска setup-скрипта
```

---

## Скрипты

Проект содержит два скрипта в корне репозитория. Оба запускаются в WSL/Linux.

### `setup-cicd.sh` — полная автоматизация CI/CD

Главный скрипт. Проходит через 10 фаз (см. ниже), настраивает сервер, генерирует файлы,
создаёт GitHub Secrets и запускает деплой. Хранит прогресс в `config.md` — при повторном
запуске предлагает продолжить с незавершённой фазы.

```bash
# Из корня репозитория, в WSL:
bash setup-cicd.sh
```

При повторном запуске скрипт находит `config.md` и предлагает:
1. **Продолжить** — с последней незавершённой фазы
2. **Выбрать фазу** — сбросить и перезапустить с конкретного шага
3. **Начать заново** — архивировать конфиг и пройти всё с нуля

### `setup-nginx.sh` — nginx reverse proxy

Отдельный скрипт для настройки nginx на сервере. Вызывается автоматически из `setup-cicd.sh`
в фазе 6.5, но можно запустить вручную — интерактивно или с параметрами.

```bash
# Интерактивный режим (запросит всё сам):
bash setup-nginx.sh

# С параметрами: <ssh_host> <domain_or_ip> [external_port] [app_port] [--ssl]
bash setup-nginx.sh 164.215.97.195 dairy.example.com 80 8000 --ssl
bash setup-nginx.sh 164.215.97.195 164.215.97.195 8888 8000
```

Что делает скрипт:
- Находит SSH-ключ автоматически (по IP из `config.md` или `~/.ssh/id_ed25519`)
- Устанавливает nginx, если не установлен
- Пишет vhost-конфиг (`/etc/nginx/sites-available/biohacker-bot`)
- Удаляет nginx default-сайт, если он конфликтует на том же порту
- Запрашивает SSL через certbot (флаг `--ssl`), пропускает для IP-адресов
- Настраивает firewall (ufw или iptables)
- Проверяет доступность через SSH-подключение к серверу (не внешний curl — надёжнее при Cloudflare)

#### WEB_URL и порты — важно

`WEB_URL` в `.env` — это адрес, который бот показывает пользователям в `/start`.
Его нужно задавать правильно:

| Конфигурация | WEB_URL |
|---|---|
| Домен + SSL (certbot/Cloudflare) | `https://domain.com` |
| Домен + HTTP (порт 80) | `http://domain.com` |
| Домен + HTTP (нестандартный порт, nginx слушает на 8888) | `http://domain.com:8888` |
| Только IP без домена | `http://1.2.3.4:8080` |

> **Правило:** если домен обслуживается через стандартный порт (80/443), порт в URL не нужен.
> Дополнительный открытый порт (напр. прямой docker-порт) — это отдельная сущность, не WEB_URL.

---

## Фазы `setup-cicd.sh`

| # | Название | Что делает |
|---|---|---|
| 1 | Prerequisites | Проверяет наличие git, ssh, gh и других инструментов |
| 2 | Repository detection | Определяет `owner/repo` из git remote, создаёт `.gitignore`/`.dockerignore` |
| 3 | Configure stages | Запрашивает список стейджей (test, prod), хосты и способ авторизации |
| 4 | Provision server | Создаёт пользователя `deployer`, добавляет его в группу `docker`, создаёт `/opt/<repo>` |
| 5 | Collect .env | Запрашивает переменные окружения для каждого стейджа, копирует `.env` на сервер |
| 6 | Generate docker-compose | Генерирует `docker-compose.<stage>.yml`, копирует на сервер |
| 6.5 | Nginx per stage | Вызывает `setup-nginx.sh`, сохраняет `WEB_URL` в `.env` и загружает на сервер |
| 7 | Generate workflow | Генерирует `.github/workflows/pipeline.yml` |
| 8 | GitHub secrets & environments | Создаёт GitHub Environments и секреты (`SSH_HOST_*`, `SSH_PRIVATE_KEY_*`) |
| 9 | Commit & push | Коммитит сгенерированные файлы, пушит `main`, создаёт ветку `develop` |
| 10 | Smoke test | Проверяет SSH-подключение деплоера, статус контейнеров, собирает docker logs |

---

## Архитектура пайплайна

### Ветки → среды

Деплой управляется веткой, в которую сделан push. Каждая ветка привязана к своей среде:

```
develop ──── push ────▶  CI  ──── success ────▶  Deploy → test
  │
  │  (PR / merge)
  ▼
main    ──── push ────▶  CI  ──── success ────▶  Deploy → prod
```

Деплои на `test` и `prod` **независимы** — оба ждут только CI, не друг друга.  
Это значит: провальный деплой на test не блокирует экстренный push в main.

### Workflow разработки

```bash
# Вся разработка ведётся в develop:
git checkout develop

# После изменений — пуш автоматически деплоит на тест:
git push origin develop

# Когда готово к проду — мержим в main:
git checkout main
git merge develop
git push origin main        # → автодеплой на прод

# Или через Pull Request на GitHub (рекомендуется):
# develop → main → Merge PR → деплой на прод
```

> **Защита main**: в GitHub Settings → Branches можно добавить branch protection rule  
> на `main` с **Required reviewers** — тогда любой merge в прод требует ручного approve.

### Что деплоится куда

| Ветка | Образ | Сервер |
|---|---|---|
| `develop` | `:test-latest`, `:test-<sha>` | test-сервер |
| `main` | `:prod-latest`, `:prod-<sha>` | prod-сервер |

CI (lint + docker build smoke-test) запускается при push в **обе** ветки и на PR в `main`.

---

## Как устроен деплой

### SSH аутентификация

- Ключи генерируются скриптом: `~/.ssh/cicd_<repo>_<stage>` (ed25519)
- Публичный ключ прописывается в `authorized_keys` пользователя `deployer` на сервере
- Приватный ключ хранится в GitHub Secret `SSH_PRIVATE_KEY_<STAGE>`
- В pipeline используется [`webfactory/ssh-agent`](https://github.com/webfactory/ssh-agent) — надёжная обработка multi-line ключей

### Docker pull с GHCR

Образ тянется с `ghcr.io` через `secrets.GITHUB_TOKEN` — автоматический токен пайплайна.  
**Отдельный PAT не нужен.** Токен передаётся через `stdin`, не через аргументы командной строки.

### Команды на сервере

Выполняются через SSH heredoc с `set -e` — при любой ошибке деплой прерывается:

```bash
ssh deployer@$HOST bash << EOF
  set -e
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u $ACTOR --password-stdin
  cd /opt/<repo>
  docker compose -f docker-compose.<stage>.yml pull
  docker compose -f docker-compose.<stage>.yml up -d --remove-orphans
  docker image prune -f
EOF
```

---

## Структура на сервере

```
/opt/<repo-name>/
├── docker-compose.test.yml   # или prod
├── .env                      # переменные окружения приложения
└── (docker volume: bot_data) # данные SQLite базы → /app/data/biohacker.db
```

Пользователь `deployer`:
- Группа `docker` — может управлять контейнерами без `sudo`
- Домашний каталог: `/home/deployer`
- SSH ключ: `/home/deployer/.ssh/authorized_keys`

### Переменные окружения (`.env`)

Шаблон: `.env.example` в корне репозитория. Ключевые параметры:

| Переменная | Описание |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Токен бота от @BotFather (отдельный для test и prod!) |
| `TELEGRAM_SECRET_KEY` | Тот же токен — используется для верификации WebApp initData |
| `DATABASE_URL` | `sqlite+aiosqlite:////app/data/biohacker.db` (абсолютный путь в контейнере) |
| `JWT_SECRET_KEY` | Минимум 32 символа, уникальный для каждого стейджа |
| `WEB_URL` | Публичный URL панели (`https://...`) — бот показывает его в `/start` |

> **`DATABASE_URL` — четыре слеша**: `sqlite+aiosqlite:////app/data/biohacker.db`  
> Три — часть схемы URI, четвёртый — начало абсолютного пути `/app/data/...`.  
> Два слеша (`///./`) создадут файл относительно рабочей директории — в контейнере это `/app/biohacker.db`, который не переживёт перезапуск (не в volume).

---

## GitHub Secrets

| Secret | Уровень | Описание |
|---|---|---|
| `SSH_HOST_TEST` | repo | IP-адрес test-сервера |
| `SSH_PRIVATE_KEY_TEST` | repo | Приватный SSH-ключ деплоя (test) |
| `SSH_HOST_PROD` | repo | IP-адрес prod-сервера |
| `SSH_PRIVATE_KEY_PROD` | repo | Приватный SSH-ключ деплоя (prod) |

> **Не хранить** порт и имя пользователя как секреты — GitHub маскирует короткие значения
> (например `22`) везде в логах, что ломает выполнение. Порт `22` и пользователь `deployer`
> захардкодены в pipeline.

---

## Управление ключами

Ключи хранятся в `~/.ssh/` (Linux-файловая система WSL), а не в проекте.  
`chmod 600` корректно работает только там — на NTFS (`/mnt/d/...`) права не применяются.

```bash
# Ручное подключение к серверу (для диагностики):
ssh -i ~/.ssh/cicd_biohacker-bot_test deployer@<host>
ssh -i ~/.ssh/cicd_biohacker-bot_prod  deployer@<host>

# Проверить authorized_keys на сервере:
ssh deployer@<host> "cat ~/.ssh/authorized_keys"
```

---

## Nginx — особенности серверов

### Конфликт с FastPanel (managed hosting)

На серверах с **FastPanel** nginx управляется панелью. Это создаёт конфликты:

- `/etc/nginx/conf.d/parking.conf` — FastPanel создаёт "parking" блок для всех доменов,
  в том числе с `server_name <твой_домен>` и собственными SSL-блоками (certbot).
- `/etc/nginx/conf.d/reuseport.conf` — FastPanel биндит `217.x.x.x:443 reuseport` как
  основной приёмник соединений.
- `sites-enabled/biohacker-bot` с `listen 443 ssl;` (все интерфейсы) **не работает**
  рядом с `listen 217.x.x.x:443;` (конкретный IP) — это разные сокеты в nginx, SNI
  не переключается между ними.

**Решение для FastPanel-серверов**: добавлять proxy_pass прямо в `parking.conf` в блок
`server_name <домен>`, а не в отдельный файл `sites-enabled`. Использовать
`listen 217.x.x.x:443 ssl;` (конкретный IP), а не `listen 443 ssl;`.

```nginx
# /etc/nginx/conf.d/parking.conf — добавить блок:
server {
    listen 217.177.46.72:443 ssl;
    server_name dairy.biohacking.biz;

    ssl_certificate /etc/letsencrypt/live/dairy.biohacking.biz/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dairy.biohacking.biz/privkey.pem;

    include /etc/nginx/fastpanel2-includes/letsencrypt.conf;

    location / {
        proxy_pass http://127.0.0.1:8000;
        ...
    }
}
```

### Cloudflare — certbot и проверка доступности

Если домен за **Cloudflare** (оранжевое облако):

- **certbot не работает** с HTTP-challenge — Cloudflare перехватывает запрос и возвращает
  своей ACME-страницей. Certbot не получает ответ от сервера → ошибка.
- **Решение**: либо временно выключить Cloudflare proxy (серое облако) на время выпуска
  сертификата, либо использовать DNS-01 challenge (`certbot --preferred-challenges dns`),
  либо использовать сертификат от самого Cloudflare (Flexible/Full SSL в дашборде).
- На `dairy.biohacking.biz` certbot успел выпустить сертификат (FastPanel сделал это до
  включения Cloudflare proxy) — поэтому `/etc/letsencrypt/live/dairy.biohacking.biz/` есть
  на сервере.

**Cloudflare SSL Mode**: для корректной работы нужен режим **Full** или **Full (Strict)**
в Cloudflare Dashboard → SSL/TLS. При **Flexible** Cloudflare подключается к origin по HTTP,
а наш nginx отдаёт 301 → redirect loop.

**Проверка доступности при Cloudflare**: внешний `curl https://domain` возвращает
ответ от Cloudflare (301 "Always Use HTTPS" или 404 "origin недоступен") — не от nginx.
Надёжнее проверять напрямую: `ssh root@host "curl -s localhost:8000/health"`.

### Heredoc и экранирование переменных nginx

При записи nginx-конфига через SSH heredoc переменные вида `$host`, `$remote_addr`
**разворачиваются bash'ем** прежде чем попасть в конфиг:

```bash
# ❌ Неправильно — $host исчезнет (станет пустой строкой):
ssh root@host "cat > /etc/nginx/... << EOF
    proxy_set_header Host $host;
EOF"

# ✓ Правильно — записать файл локально, затем scp:
cat > /tmp/nginx.conf << 'EOF'
    proxy_set_header Host $host;
EOF
scp /tmp/nginx.conf root@host:/etc/nginx/sites-available/biohacker-bot
```

Одинарные кавычки вокруг `'EOF'` отключают интерпретацию в локальном heredoc.
При передаче через SSH двойные кавычки не защищают — используй `scp`.

---

## Диагностика

### Посмотреть логи последнего запуска скрипта

```bash
cat .cicd/setup_<timestamp>.log
```

### Проверить статус пайплайна

```bash
gh run list --limit 5
gh run view <run-id> --log-failed
```

### Проверить контейнер на сервере

```bash
# Через deployer (SSH-ключ):
ssh -i ~/.ssh/cicd_biohacker-bot_test deployer@<host> \
  "docker ps && docker compose -f /opt/biohacker-bot/docker-compose.test.yml logs --tail=50"

# Проверить health endpoint напрямую (минуя nginx/Cloudflare):
ssh -i ~/.ssh/cicd_biohacker-bot_prod deployer@<host> \
  "curl -s http://localhost:8000/health"
```

### Проверить nginx

```bash
ssh root@<host> "nginx -t && systemctl status nginx"
ssh root@<host> "tail -50 /var/log/nginx/biohacker-bot.error.log"
ssh root@<host> "tail -50 /var/log/nginx/biohacker-bot.access.log"

# Какой SSL-сертификат отдаёт сервер для домена:
echo | openssl s_client -connect <host_ip>:443 -servername <domain> 2>&1 | grep 'subject='
```

### Пересоздать GitHub Secrets вручную

```bash
# SSH ключ (через WSL — сохраняет корректные LF окончания строк):
wsl -e bash -c "gh secret set SSH_PRIVATE_KEY_TEST \
  --repo <owner>/<repo> \
  --body \"\$(cat ~/.ssh/cicd_biohacker-bot_test)\""

# Хост (через --body, без stdin — нет trailing newline):
gh secret set SSH_HOST_TEST --repo <owner>/<repo> --body "1.2.3.4"
```

### Обновить `.env` на сервере вручную

```bash
# Через root (deployer не имеет права на перезапись файла, созданного root):
sshpass -p 'ROOT_PASSWORD' scp -o StrictHostKeyChecking=no \
  .cicd/.env.prod root@<host>:/opt/biohacker-bot/.env

# Перезапустить контейнер (подхватит новый .env):
ssh -i ~/.ssh/cicd_biohacker-bot_prod deployer@<host> \
  "cd /opt/biohacker-bot && docker compose -f docker-compose.prod.yml up -d"
```

---

## Известные проблемы и решения

| Проблема | Причина | Решение |
|---|---|---|
| `error in libcrypto` | SSH-ключ записан с CRLF или через Git Bash | Записывать секрет через WSL: `wsl -e bash -c "..."` |
| `hostname contains invalid characters` | Trailing `\n` в значении секрета | `gh secret set --body "value"` вместо stdin |
| `Bad port '***'` / значения замаскированы | GitHub маскирует короткие секреты (напр. `22`) | Не хранить порт/пользователя как секреты |
| `denied: denied` при docker pull | Истёкший PAT | Использовать `secrets.GITHUB_TOKEN` — он всегда актуален |
| `chmod 600` не работает на ключах | NTFS не поддерживает unix permissions | Хранить ключи в `~/.ssh/` (Linux FS), не в `/mnt/d/...` |
| nginx config correct but wrong cert served | FastPanel `reuseport.conf` + `default_server` поглощает SNI | Добавлять блок в `parking.conf` с `listen IP:443`, а не в `sites-enabled` с `listen 443` |
| `nginx -t` OK, но сайт не работает | Конфиг загружен без переменных nginx (`$host` пуст) | Писать конфиг локально + scp, не через heredoc по SSH |
| certbot: `Challenge did not pass` | Домен за Cloudflare — HTTP challenge перехватывается | Отключить Cloudflare proxy на время выпуска, или DNS-01 challenge |
| Cloudflare 404 на HTTPS | SSL Mode = Flexible, nginx отдаёт 301 → redirect loop | Установить Cloudflare SSL Mode = Full или Full (Strict) |
| `scp: Permission denied` на `.env` | Файл на сервере создан от root, deployer не может перезаписать | Копировать через root: `sshpass -p '...' scp ... root@host:/opt/...` |
| Telegram `InvalidToken` в тест-стейдже | Неверный или истёкший токен бота | Создать нового бота через @BotFather, обновить `.env.test` |
| Контейнер падает при невалидном Telegram токене | Ошибка пробрасывается до `asyncio.run()` | Retry 10x с экспоненциальным backoff (5→10→20…с), затем graceful degradation — панель работает без бота |
