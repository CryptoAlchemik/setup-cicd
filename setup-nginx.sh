#!/usr/bin/env bash
# =============================================================
#  setup-nginx.sh  —  Nginx reverse proxy для biohacker-bot
#
#  Запуск: bash setup-nginx.sh
#  Или с параметрами: bash setup-nginx.sh <ssh_host> <domain_or_ip> [external_port] [app_port] [--ssl]
#
#  Примеры:
#    bash setup-nginx.sh                                      # интерактивный режим
#    bash setup-nginx.sh 164.215.97.195 164.215.97.195 8888   # test, нестандартный порт
#    bash setup-nginx.sh 217.177.46.72 diary.biohacking.biz 80 8000 --ssl
# =============================================================
set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────
R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'
W=$'\033[1m';    C=$'\033[0;36m'; N=$'\033[0m'

log()    { printf "  ${W}▶${N} %s\n" "$*"; }
ok()     { printf "  ${G}✓${N} %s\n" "$*"; }
warn()   { printf "  ${Y}⚠${N}  %s\n" "$*"; }
die()    { printf "\n  ${R}✗${N} %s\n" "$*" >&2; exit 1; }
prompt() { printf "${W}%s${N}: " "$1" > /dev/tty; read -re _r < /dev/tty; printf '%s' "${_r%$'\r'}"; }
prompt_default() { printf "${W}%s${N} [${C}%s${N}]: " "$1" "$2" > /dev/tty; read -re _r < /dev/tty; _r="${_r%$'\r'}"; printf '%s' "${_r:-$2}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.cicd/config.md"

# ── Параметры: CLI или интерактив ────────────────────────────
if [[ $# -ge 2 ]]; then
  HOST="$1"
  DOMAIN="$2"
  EXTERNAL_PORT="${3:-80}"
  APP_PORT="${4:-8000}"
  [[ "${5:-}" == "--ssl" ]] && USE_SSL=true || USE_SSL=false
else
  printf "${W}${C}"
  printf "╔═══════════════════════════════════════╗\n"
  printf "║   Nginx Reverse Proxy Setup           ║\n"
  printf "╚═══════════════════════════════════════╝\n"
  printf "${N}\n"

  HOST=$(prompt "SSH хост сервера (IP или hostname)")
  [[ -z "$HOST" ]] && die "Хост не указан"

  DOMAIN=$(prompt_default "Домен или IP для nginx server_name" "$HOST")

  EXTERNAL_PORT=$(prompt_default "Внешний порт nginx (80 = стандартный HTTP)" "80")

  APP_PORT=$(prompt_default "Порт приложения внутри сервера (app_port)" "8000")

  SSL_CHOICE=$(prompt_default "Получить SSL через certbot? (только для домена, не IP)" "n")
  [[ "$SSL_CHOICE" =~ ^[Yy] ]] && USE_SSL=true || USE_SSL=false

  echo
fi

# ── Поиск SSH ключа ──────────────────────────────────────────
if [[ -z "${SSH_KEY:-}" ]]; then
  if [[ -f "$CONFIG_FILE" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^STAGE_HOST_([^=]+)=(.+)$ ]]; then
        _stage="${BASH_REMATCH[1],,}"; _host="${BASH_REMATCH[2]}"
        if [[ "$_host" == "$HOST" ]]; then
          candidate="$HOME/.ssh/cicd_biohacker-bot_${_stage}"
          [[ -f "$candidate" ]] && SSH_KEY="$candidate" && break
        fi
      fi
    done < "$CONFIG_FILE"
  fi
  if [[ -z "${SSH_KEY:-}" ]]; then
    for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
      [[ -f "$candidate" ]] && SSH_KEY="$candidate" && break
    done
  fi
fi
[[ -z "${SSH_KEY:-}" ]] && die "SSH ключ не найден. Укажи явно: SSH_KEY=/path/to/key bash $0"
ok "SSH ключ: $SSH_KEY"

# ── Поиск root-пароля из конфига ─────────────────────────────
ROOT_PASS=""
if [[ -f "$CONFIG_FILE" ]]; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^STAGE_HOST_([^=]+)=(.+)$ ]]; then
      _stage="${BASH_REMATCH[1],,}"; _host="${BASH_REMATCH[2]}"
      if [[ "$_host" == "$HOST" ]]; then
        ROOT_PASS=$(grep "^STAGE_ROOT_PASS_${_stage}=" "$CONFIG_FILE" | sed "s/.*=//;s/'//g" || true)
        break
      fi
    fi
  done < "$CONFIG_FILE"
fi

# ── SSH helper (root) ─────────────────────────────────────────
_ssh() {
  if [[ -n "$ROOT_PASS" ]] && command -v sshpass &>/dev/null; then
    sshpass -p "$ROOT_PASS" ssh -o StrictHostKeyChecking=no "root@${HOST}" "$@" 2>&1
  else
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY" "root@${HOST}" "$@" 2>&1
  fi
}

# ── Проверка подключения ──────────────────────────────────────
log "Проверяю подключение к ${HOST}..."
_ssh "echo ok" > /dev/null || die "Не могу подключиться к root@${HOST}"
ok "Подключение установлено (root@${HOST})"

# ── Установка nginx ───────────────────────────────────────────
log "Устанавливаю nginx (если не установлен)..."
_ssh "apt-get update -qq && apt-get install -y -qq nginx" || true
ok "nginx готов"

# ── Nginx конфиг ─────────────────────────────────────────────
log "Создаю nginx конфиг: ${DOMAIN}:${EXTERNAL_PORT} → localhost:${APP_PORT}..."

# Формируем listen директивы
if [[ "$EXTERNAL_PORT" == "80" ]]; then
  LISTEN_LINES="    listen 80;\n    listen [::]:80;"
elif [[ "$EXTERNAL_PORT" == "443" ]]; then
  LISTEN_LINES="    listen 443 ssl;\n    listen [::]:443 ssl;"
else
  LISTEN_LINES="    listen ${EXTERNAL_PORT};\n    listen [::]:${EXTERNAL_PORT};"
fi

_ssh "cat > /etc/nginx/sites-available/biohacker-bot << 'NGINX_EOF'
server {
$(printf '%b' "$LISTEN_LINES")
    server_name ${DOMAIN};

    access_log /var/log/nginx/biohacker-bot.access.log;
    error_log  /var/log/nginx/biohacker-bot.error.log;

    location / {
        proxy_pass         http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \"upgrade\";

        proxy_connect_timeout  60s;
        proxy_send_timeout     60s;
        proxy_read_timeout     60s;
    }

    location /health {
        proxy_pass http://127.0.0.1:${APP_PORT}/health;
        access_log off;
    }
}
NGINX_EOF"

# Включаем сайт
_ssh "ln -sf /etc/nginx/sites-available/biohacker-bot /etc/nginx/sites-enabled/biohacker-bot"

# Удаляем default только если он конфликтует на том же порту
if _ssh "grep -q \"listen ${EXTERNAL_PORT}.*default_server\" /etc/nginx/sites-enabled/default 2>/dev/null || \
         grep -q \"listen \[::\]:${EXTERNAL_PORT}.*default_server\" /etc/nginx/sites-enabled/default 2>/dev/null"; then
  _ssh "rm -f /etc/nginx/sites-enabled/default"
  warn "Удалён nginx default (конфликтовал на порту ${EXTERNAL_PORT})"
fi

# Проверка конфига
_ssh "nginx -t" && ok "nginx конфиг валиден"

# Перезапуск
_ssh "systemctl enable nginx && systemctl reload nginx"
ok "nginx перезапущен"

# ── SSL через certbot ─────────────────────────────────────────
if [[ "$USE_SSL" == "true" ]]; then
  if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "--ssl указан, но '${DOMAIN}' — IP-адрес. SSL требует домен. Пропускаю."
  else
    log "Получаю SSL сертификат для ${DOMAIN}..."
    _ssh "apt-get install -y -qq certbot python3-certbot-nginx"
    _ssh "certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN} --redirect" \
      && ok "SSL сертификат получен, nginx переключён на HTTPS" \
      || warn "certbot не смог получить сертификат — проверь DNS и открытость порта 80"
  fi
fi

# ── Firewall ──────────────────────────────────────────────────
log "Настраиваю firewall..."
if _ssh "which ufw > /dev/null 2>&1"; then
  _ssh "ufw allow ${EXTERNAL_PORT}/tcp comment 'nginx biohacker-bot' > /dev/null 2>&1 || true"
  [[ "$USE_SSL" == "true" ]] && _ssh "ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1 || true"
  _ssh "ufw --force enable > /dev/null 2>&1 || true"
  ok "ufw: открыт порт ${EXTERNAL_PORT}"
elif _ssh "which iptables > /dev/null 2>&1"; then
  _ssh "iptables -C INPUT -p tcp --dport ${EXTERNAL_PORT} -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport ${EXTERNAL_PORT} -j ACCEPT"
  ok "iptables: открыт порт ${EXTERNAL_PORT}"
else
  warn "firewall не найден — убедись что порт ${EXTERNAL_PORT} открыт вручную"
fi

# ── Проверка доступности (через localhost, минуя Cloudflare и редиректы) ──
log "Проверяю доступность..."
sleep 2
if [[ "$EXTERNAL_PORT" == "80" || "$EXTERNAL_PORT" == "443" ]]; then
  PROTO=$([[ "$EXTERNAL_PORT" == "443" ]] && echo "https" || echo "http")
  CHECK_URL="${PROTO}://${DOMAIN}"
else
  CHECK_URL="http://${DOMAIN}:${EXTERNAL_PORT}"
fi

# Проверяем напрямую через SSH — это надёжнее, чем внешний curl (обходит Cloudflare/редиректы)
APP_PORT="${APP_PORT:-8000}"
LOCAL_CODE=$(_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:${APP_PORT}/health 2>/dev/null" 2>/dev/null || echo "000")
if [[ "$LOCAL_CODE" == "200" ]]; then
  ok "Приложение отвечает на сервере (http://localhost:${APP_PORT}/health → HTTP 200)"
  ok "Внешний URL: ${CHECK_URL}"
else
  # Fallback: внешняя проверка
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$CHECK_URL" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
    ok "${CHECK_URL} отвечает (HTTP ${HTTP_CODE})"
  else
    warn "Приложение не отвечает (local: ${LOCAL_CODE}, external: ${HTTP_CODE}) — возможно контейнер ещё не запущен"
  fi
fi

# ── Итог ─────────────────────────────────────────────────────
echo
printf "${G}${W}Готово!${N}\n"
echo
printf "  ${C}URL:${N}      ${CHECK_URL}\n"
printf "  ${C}API docs:${N} ${CHECK_URL}/docs\n"
[[ "$USE_SSL" == "true" && ! "$DOMAIN" =~ ^[0-9] ]] && \
  printf "  ${C}HTTPS:${N}    https://${DOMAIN}\n"
echo
printf "  Логи:    ${W}ssh root@${HOST} 'tail -f /var/log/nginx/biohacker-bot.access.log'${N}\n"
printf "  Статус:  ${W}ssh root@${HOST} 'systemctl status nginx'${N}\n"
echo
