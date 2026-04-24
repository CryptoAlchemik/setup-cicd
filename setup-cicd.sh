#!/usr/bin/env bash
# ================================================================
#  setup-cicd.sh  v1.0
#  Universal CI/CD bootstrap — GitHub Actions + Docker + GHCR
#
#  Что делает:
#    1. Проверяет prerequisites (git, ssh, gh CLI, ...)
#    2. Определяет GitHub репо из git remote
#    3. Настраивает N stage'ей (test, prod, ...)
#    4. Подключается к каждому серверу как root:
#       — устанавливает Docker
#       — создаёт пользователя deployer
#       — генерирует SSH keypair для GitHub Actions
#    5. Собирает .env для каждого stage и загружает на сервер
#    6. Генерирует docker-compose.<stage>.yml
#    7. Генерирует .github/workflows/pipeline.yml
#    8. Создаёт GitHub Environments и Secrets
#    9. Коммитит и пушит конфиги
#   10. Smoke-test SSH как deployer
#   11. Печатает итоговую таблицу
#
#  Usage:  bash setup-cicd.sh
#  Requires: git, ssh, ssh-keygen, scp, gh (GitHub CLI), sed
#  Optional: sshpass (для root-auth по паролю)
# ================================================================
set -euo pipefail

# ── Constants ────────────────────────────────────────────────
SCRIPT_VERSION="1.0.0"
CICD_DIR=".cicd"                   # локальная папка артефактов (gitignored)
DEPLOY_USER="deployer"             # системный пользователь на сервере
DEPLOY_DIR_BASE="/opt"             # /opt/<repo-name> на сервере
CONFIG_FILE=""                     # заполняется после detect_repo
SSH_BASE_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -o LogLevel=ERROR
)

# Stage data (associative arrays)
declare -a STAGES=()
declare -A STAGE_HOST STAGE_PORT STAGE_AUTH STAGE_ROOT_KEY STAGE_ROOT_PASS STAGE_CONTAINER_ID STAGE_DOMAIN
declare -A STAGE_DB_MODE STAGE_DB_HOST STAGE_DB_PORTNUM STAGE_DB_NAME STAGE_DB_USER STAGE_DB_PASSWORD
declare -A STAGE_DB_ALLOWED_CIDR STAGE_DB_SSH_HOST STAGE_DB_SSH_PORT STAGE_DB_SSH_AUTH STAGE_DB_SSH_KEY STAGE_DB_SSH_PASS
declare -A STAGE_IS_LOCAL

REPO_OWNER="" REPO_NAME="" REPO_FULL=""
GHCR_TOKEN_SAVED=""   # GitHub PAT read:packages — сохраняется в конфиг
SSHPASS_AVAILABLE=false

# Telegram notifications (optional, phase 7.5)
TG_BOT_TOKEN=""
TG_ADMIN_CHAT_ID=""
TG_NOTIFICATIONS=false

# ── Colors (actual ESC chars via $'...' so printf/echo work without -e) ──────
R=$'\033[0;31m' G=$'\033[0;32m' Y=$'\033[1;33m'
B=$'\033[0;34m' C=$'\033[0;36m' W=$'\033[1m'  N=$'\033[0m'

log()  { printf "${B}▶${N} %s\n" "$*"; }
ok()   { printf "${G}✓${N} %s\n" "$*"; }
warn() { printf "${Y}⚠${N}  %s\n" "$*"; }
die()  { printf "\n${R}✗ FATAL:${N} %s\n\n" "$*" >&2; exit 1; }
step() { printf "\n${W}${C}━━━ %s ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n\n" "$*"; }

# Readline non-printable markers: wrap color codes so readline
# doesn't count them in cursor-position calculations.
# Without these, backspace and line-redraw corrupt the display.
_S=$'\001'  # RL_PROMPT_START_IGNORE
_E=$'\002'  # RL_PROMPT_END_IGNORE
_rW="${_S}${W}${_E}"   # bold        (readline-safe)
_rN="${_S}${N}${_E}"   # reset       (readline-safe)
_rC="${_S}${C}${_E}"   # cyan        (readline-safe)

# ── Input helpers ────────────────────────────────────────────
# prompt VAR "Question" [default]
prompt() {
  local _v=$1 _q=$2 _d=${3-} _i
  if [[ -n $_d ]]; then
    printf "${_rW}%s${_rN} [${_rC}%s${_rN}]: " "$_q" "$_d" > /dev/tty
    read -r _i < /dev/tty
    _i="${_i%$'\r'}"
    _i=${_i:-$_d}
  else
    printf "${_rW}%s${_rN}: " "$_q" > /dev/tty
    read -r _i < /dev/tty
    _i="${_i%$'\r'}"
  fi
  printf -v "$_v" '%s' "$_i"
}

# prompt_secret VAR "Question"  (hidden — for passwords / tokens)
prompt_secret() {
  printf "${W}%s${N} (hidden): " "$2" > /dev/tty
  read -rs _s < /dev/tty
  _s="${_s%$'\r'}"
  printf "\n" > /dev/tty
  printf -v "$1" '%s' "$_s"
}

# yn "Question" [default=y] → 0=yes 1=no
yn() {
  local _d=${2:-y} _o="[Y/n]" _a
  [[ $_d == n ]] && _o="[y/N]"
  read -re -p "${_rW}$1${_rN} ${_o}: " _a
  _a="${_a%$'\r'}"
  _a=${_a:-$_d}
  [[ ${_a,,} == y* ]]
}

run_local_root() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    sudo -H "$@"
  fi
}

run_local_user_shell() {
  local user=$1; shift
  local cmd=$1
  if [[ $(id -u) -eq 0 ]]; then
    su -s /bin/bash "$user" -c "$cmd"
  else
    sudo -u "$user" bash -lc "$cmd"
  fi
}

configure_stage_database() {
  local stage=$1
  local db_choice db_mode db_host db_port db_name db_user db_password
  local allowed_cidr bootstrap_host bootstrap_port bootstrap_auth bootstrap_key bootstrap_pass

  echo
  echo "  ${W}Database placement${N}"
  echo "    1. PostgreSQL in Docker Compose container"
  echo "    2. PostgreSQL on the same host as the app container"
  echo "    3. PostgreSQL on a remote host"

  while true; do
    prompt db_choice "  Choose database mode [1/2/3]" "${STAGE_DB_MODE[$stage]:-2}"
    case "$db_choice" in
      1|container)
        db_mode="container"
        db_host="postgres"
        db_port="${STAGE_DB_PORTNUM[$stage]:-5432}"
        allowed_cidr=""
        bootstrap_host=""
        bootstrap_port=""
        bootstrap_auth=""
        bootstrap_key=""
        bootstrap_pass=""
        break
        ;;
      2|host)
        db_mode="host"
        db_host="host.docker.internal"
        db_port="${STAGE_DB_PORTNUM[$stage]:-5432}"
        prompt allowed_cidr "  CIDR allowed in pg_hba.conf" "${STAGE_DB_ALLOWED_CIDR[$stage]:-172.16.0.0/12}"
        bootstrap_host="${STAGE_HOST[$stage]:-}"
        bootstrap_port="${STAGE_PORT[$stage]:-22}"
        bootstrap_auth="${STAGE_AUTH[$stage]:-pass}"
        bootstrap_key="${STAGE_ROOT_KEY[$stage]:-}"
        bootstrap_pass="${STAGE_ROOT_PASS[$stage]:-}"
        break
        ;;
      3|remote)
        db_mode="remote"
        prompt db_host "  Remote PostgreSQL host" "${STAGE_DB_HOST[$stage]:-}"
        prompt db_port "  Remote PostgreSQL port" "${STAGE_DB_PORTNUM[$stage]:-5432}"
        prompt allowed_cidr "  CIDR allowed in pg_hba.conf" "${STAGE_DB_ALLOWED_CIDR[$stage]:-${STAGE_HOST[$stage]:-}/32}"
        prompt bootstrap_host "  SSH host for PostgreSQL bootstrap" "${STAGE_DB_SSH_HOST[$stage]:-$db_host}"
        prompt bootstrap_port "  SSH port for PostgreSQL bootstrap" "${STAGE_DB_SSH_PORT[$stage]:-22}"
        read -re -p "  ${_rW}Root auth for PostgreSQL host${_rN} [key/${_rC}pass${_rN}]: " bootstrap_auth
        bootstrap_auth="${bootstrap_auth%$'\r'}"
        bootstrap_auth=${bootstrap_auth:-${STAGE_DB_SSH_AUTH[$stage]:-pass}}
        if [[ $bootstrap_auth == pass ]] && ! $SSHPASS_AVAILABLE; then
          warn "Password auth requires sshpass; switching PostgreSQL bootstrap auth to key."
          bootstrap_auth="key"
        fi
        case "$bootstrap_auth" in
          key)
            prompt bootstrap_key "  Root SSH key for PostgreSQL host" "${STAGE_DB_SSH_KEY[$stage]:-$HOME/.ssh/id_rsa}"
            [[ -f $bootstrap_key ]] || die "Key file not found: $bootstrap_key"
            bootstrap_pass=""
            ;;
          pass)
            prompt_secret bootstrap_pass "  Root password for PostgreSQL host ${bootstrap_host}"
            bootstrap_key=""
            ;;
          *)
            die "Unknown PostgreSQL host auth: ${bootstrap_auth}"
            ;;
        esac
        break
        ;;
      *)
        warn "Unknown database mode: ${db_choice}. Use 1, 2 or 3."
        ;;
    esac
  done

  prompt db_name "  Database name" "${STAGE_DB_NAME[$stage]:-biohacker}"
  prompt db_user "  Database user" "${STAGE_DB_USER[$stage]:-biohacker}"
  prompt_secret db_password "  Database password for ${db_user}"

  STAGE_DB_MODE["$stage"]="$db_mode"
  STAGE_DB_HOST["$stage"]="$db_host"
  STAGE_DB_PORTNUM["$stage"]="$db_port"
  STAGE_DB_NAME["$stage"]="$db_name"
  STAGE_DB_USER["$stage"]="$db_user"
  STAGE_DB_PASSWORD["$stage"]="$db_password"
  STAGE_DB_ALLOWED_CIDR["$stage"]="$allowed_cidr"
  STAGE_DB_SSH_HOST["$stage"]="$bootstrap_host"
  STAGE_DB_SSH_PORT["$stage"]="$bootstrap_port"
  STAGE_DB_SSH_AUTH["$stage"]="$bootstrap_auth"
  STAGE_DB_SSH_KEY["$stage"]="$bootstrap_key"
  STAGE_DB_SSH_PASS["$stage"]="$bootstrap_pass"

  ok "Database for '${stage}' → mode=${db_mode}, host=${db_host}, db=${db_name}, user=${db_user}"
}

stage_database_url() {
  local stage=$1
  local mode="${STAGE_DB_MODE[$stage]:-host}"
  local host="${STAGE_DB_HOST[$stage]:-host.docker.internal}"
  local port="${STAGE_DB_PORTNUM[$stage]:-5432}"
  local name="${STAGE_DB_NAME[$stage]:-biohacker}"
  local user="${STAGE_DB_USER[$stage]:-biohacker}"
  local password="${STAGE_DB_PASSWORD[$stage]:-}"

  case "$mode" in
    container) host="postgres" ;;
    host)      host="host.docker.internal" ;;
    remote)    : ;;
  esac

  printf 'postgresql+asyncpg://%s:%s@%s:%s/%s' \
    "$user" "$password" "$host" "$port" "$name"
}

# Deploy-ключи хранятся в ~/.ssh/ — там chmod 600 работает корректно
# (в т.ч. в WSL, где файлы проекта на NTFS и chmod не действует).
SSH_DIR="$HOME/.ssh"
deploy_key() { echo "${SSH_DIR}/cicd_${REPO_NAME}_${1}"; }

_init_ssh_dir() {
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
}

fix_key_perms() {
  chmod 600 "$1"
}

# Мигрирует ключи из старого .cicd/deploy_<stage> в ~/.ssh/ если нужно
_migrate_deploy_keys() {
  for stage in "${STAGES[@]}"; do
    local new_key old_key
    new_key=$(deploy_key "$stage")
    # Возможные старые пути (проектный .ssh/ или .cicd/)
    local old_proj=".ssh/deploy_${stage}"
    local old_cicd="${CICD_DIR}/deploy_${stage}"
    if [[ ! -f "$new_key" ]]; then
      local old_key=""
      [[ -f "$old_proj" ]] && old_key="$old_proj"
      [[ -z "$old_key" && -f "$old_cicd" ]] && old_key="$old_cicd"
      if [[ -n "$old_key" ]]; then
        cp "$old_key"       "$new_key"
        cp "${old_key}.pub" "${new_key}.pub" 2>/dev/null || true
        fix_key_perms "$new_key"
        ok "Ключ мигрирован: ${old_key} → ${new_key}"
      else
        warn "Deploy-ключ не найден для stage '${stage}': ${new_key}"
        warn "Запусти скрипт заново — phase 4 перегенерирует ключ."
      fi
    fi
  done
}

# ── SSH / SCP helpers ─────────────────────────────────────────

# Логирует команду и её вывод. Используй вместо прямых вызовов SSH.
_ssh_log() {        # _ssh_log <user@host> <cmd_label> <output> <exit_code>
  local target=$1 label=$2 output=$3 rc=$4
  printf "  ${W}[ssh %s]${N} %s\n" "$target" "$label"
  if [[ -n "$output" ]]; then
    while IFS= read -r line; do
      printf "    %s\n" "$line"
    done <<< "$output"
  fi
  if [[ $rc -ne 0 ]]; then
    printf "  ${R}  exit code: %d${N}\n" "$rc"
  fi
}

_root_ssh() {       # _root_ssh STAGE cmd...
  local s=$1; shift
  local h="${STAGE_HOST[$s]}" p="${STAGE_PORT[$s]}"
  local cmd_label="${*:0:80}"
  local out rc
  if [[ "${STAGE_IS_LOCAL[$s]:-false}" == "true" ]]; then
    out=$(run_local_root "$@" 2>&1); rc=$?
    _ssh_log "local-root" "$cmd_label" "$out" "$rc"
    echo "$out"
    return $rc
  fi
  case "${STAGE_AUTH[$s]}" in
    key)
      out=$(ssh "${SSH_BASE_OPTS[@]}" -p "$p" -i "${STAGE_ROOT_KEY[$s]}" "root@${h}" "$@" 2>&1); rc=$?
      ;;
    pass)
      out=$(sshpass -p "${STAGE_ROOT_PASS[$s]}" \
            ssh "${SSH_BASE_OPTS[@]}" -p "$p" "root@${h}" "$@" 2>&1); rc=$?
      ;;
  esac
  _ssh_log "root@${h}" "$cmd_label" "$out" "$rc"
  echo "$out"
  return $rc
}

_root_scp() {       # _root_scp STAGE local_file remote_path
  local s=$1 src=$2 dst=$3
  local h="${STAGE_HOST[$s]}" p="${STAGE_PORT[$s]}"
  local out rc
  if [[ "${STAGE_IS_LOCAL[$s]:-false}" == "true" ]]; then
    printf "  ${W}[cp local-root]${N} %s → %s\n" "$src" "$dst"
    out=$(run_local_root mkdir -p "$(dirname "$dst")" && run_local_root cp "$src" "$dst" 2>&1); rc=$?
    [[ -n "$out" ]] && printf "    %s\n" "$out"
    [[ $rc -ne 0 ]] && printf "  ${R}  exit code: %d${N}\n" "$rc"
    return $rc
  fi
  printf "  ${W}[scp root@%s]${N} %s → %s\n" "$h" "$src" "$dst"
  case "${STAGE_AUTH[$s]}" in
    key)
      out=$(scp "${SSH_BASE_OPTS[@]}" -P "$p" -i "${STAGE_ROOT_KEY[$s]}" "$src" "root@${h}:${dst}" 2>&1); rc=$?
      ;;
    pass)
      out=$(sshpass -p "${STAGE_ROOT_PASS[$s]}" \
            scp "${SSH_BASE_OPTS[@]}" -P "$p" "$src" "root@${h}:${dst}" 2>&1); rc=$?
      ;;
  esac
  [[ -n "$out" ]] && printf "    %s\n" "$out"
  [[ $rc -ne 0 ]] && printf "  ${R}  exit code: %d${N}\n" "$rc"
  return $rc
}

_deployer_ssh() {   # _deployer_ssh STAGE cmd...
  local s=$1; shift
  local h="${STAGE_HOST[$s]}" p="${STAGE_PORT[$s]}"
  local cmd_label="${*:0:80}"
  local out rc
  if [[ "${STAGE_IS_LOCAL[$s]:-false}" == "true" ]]; then
    out=$(run_local_user_shell "${DEPLOY_USER}" "$*" 2>&1); rc=$?
    _ssh_log "local-${DEPLOY_USER}" "$cmd_label" "$out" "$rc"
    echo "$out"
    return $rc
  fi
  out=$(ssh "${SSH_BASE_OPTS[@]}" \
    -o BatchMode=yes \
    -o PasswordAuthentication=no \
    -p "$p" -i "$(deploy_key "$s")" \
    "${DEPLOY_USER}@${h}" "$@" 2>&1); rc=$?
  _ssh_log "${DEPLOY_USER}@${h}" "$cmd_label" "$out" "$rc"
  echo "$out"
  return $rc
}

# ================================================================
#  CONFIG — save / load / archive / phase tracking
# ================================================================

# phase_done "3"          → true если фаза завершена
# phase_done "4_test"     → true если фаза 4 для stage test завершена
phase_done() {
  local var="PHASE_${1}_DONE"
  [[ "${!var:-}" == "true" ]]
}

mark_phase_done() {
  eval "PHASE_${1}_DONE=true"
}

# Сохраняет ВСЁ: stages, пароли, .env переменные, статус фаз
save_config() {
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  {
    printf "# ============================================================\n"
    printf "# CI/CD Setup Config  —  saved: %s\n" "$ts"
    printf "# Repo: %s\n" "${REPO_FULL:-unknown}"
    printf "# ============================================================\n"
    printf "# Содержит пароли — не коммитить (.cicd/ в .gitignore)\n\n"

    printf "REPO_OWNER=%q\nREPO_NAME=%q\nREPO_FULL=%q\n\n" \
      "${REPO_OWNER}" "${REPO_NAME}" "${REPO_FULL}"
    printf "GHCR_TOKEN_SAVED=%q\n\n" "${GHCR_TOKEN_SAVED:-}"

    printf "# Telegram notifications\n"
    printf "TG_NOTIFICATIONS=%q\n"    "${TG_NOTIFICATIONS:-false}"
    printf "TG_BOT_TOKEN=%q\n"        "${TG_BOT_TOKEN:-}"
    printf "TG_ADMIN_CHAT_ID=%q\n\n"  "${TG_ADMIN_CHAT_ID:-}"

    printf "STAGES=(%s)\n" "${STAGES[*]:-}"

    for stage in "${STAGES[@]:-}"; do
      printf "\n# ── Stage: %s\n" "$stage"
      printf "STAGE_HOST_%s=%q\n"          "$stage" "${STAGE_HOST[$stage]:-}"
      printf "STAGE_PORT_%s=%q\n"          "$stage" "${STAGE_PORT[$stage]:-}"
      printf "STAGE_IS_LOCAL_%s=%q\n"      "$stage" "${STAGE_IS_LOCAL[$stage]:-false}"
      printf "STAGE_AUTH_%s=%q\n"          "$stage" "${STAGE_AUTH[$stage]:-}"
      printf "STAGE_ROOT_KEY_%s=%q\n"      "$stage" "${STAGE_ROOT_KEY[$stage]:-}"
      printf "STAGE_ROOT_PASS_%s=%q\n"     "$stage" "${STAGE_ROOT_PASS[$stage]:-}"
      printf "STAGE_CONTAINER_ID_%s=%q\n"  "$stage" "${STAGE_CONTAINER_ID[$stage]:-}"
      printf "STAGE_DOMAIN_%s=%q\n"        "$stage" "${STAGE_DOMAIN[$stage]:-}"
      printf "STAGE_DB_MODE_%s=%q\n"       "$stage" "${STAGE_DB_MODE[$stage]:-}"
      printf "STAGE_DB_HOST_%s=%q\n"       "$stage" "${STAGE_DB_HOST[$stage]:-}"
      printf "STAGE_DB_PORTNUM_%s=%q\n"    "$stage" "${STAGE_DB_PORTNUM[$stage]:-}"
      printf "STAGE_DB_NAME_%s=%q\n"       "$stage" "${STAGE_DB_NAME[$stage]:-}"
      printf "STAGE_DB_USER_%s=%q\n"       "$stage" "${STAGE_DB_USER[$stage]:-}"
      printf "STAGE_DB_PASSWORD_%s=%q\n"   "$stage" "${STAGE_DB_PASSWORD[$stage]:-}"
      printf "STAGE_DB_ALLOWED_CIDR_%s=%q\n" "$stage" "${STAGE_DB_ALLOWED_CIDR[$stage]:-}"
      printf "STAGE_DB_SSH_HOST_%s=%q\n"   "$stage" "${STAGE_DB_SSH_HOST[$stage]:-}"
      printf "STAGE_DB_SSH_PORT_%s=%q\n"   "$stage" "${STAGE_DB_SSH_PORT[$stage]:-}"
      printf "STAGE_DB_SSH_AUTH_%s=%q\n"   "$stage" "${STAGE_DB_SSH_AUTH[$stage]:-}"
      printf "STAGE_DB_SSH_KEY_%s=%q\n"    "$stage" "${STAGE_DB_SSH_KEY[$stage]:-}"
      printf "STAGE_DB_SSH_PASS_%s=%q\n"   "$stage" "${STAGE_DB_SSH_PASS[$stage]:-}"

      # .env переменные для stage (из .cicd/.env.<stage>)
      local envfile="${CICD_DIR}/.env.${stage}"
      if [[ -f "$envfile" ]]; then
        printf "\n# .env: %s\n" "$stage"
        while IFS= read -r eline; do
          eline="${eline%$'\r'}"
          [[ $eline =~ ^[[:space:]]*# ]] && continue
          [[ -z ${eline// } ]]            && continue
          local ekey="${eline%%=*}" eval="${eline#*=}"
          printf "STAGE_ENV_%s_%s=%q\n" "$stage" "$ekey" "$eval"
        done < "$envfile"
      fi
    done

    # Статус завершённых фаз
    printf "\n# Phase completion\n"
    while IFS= read -r var; do
      printf "%s=%q\n" "$var" "${!var}"
    done < <(compgen -v "PHASE_" 2>/dev/null || true)

  } > "$CONFIG_FILE"
  ok "Конфиг сохранён: ${CONFIG_FILE}"
}

# Загружает конфиг и восстанавливает ассоциативные массивы
load_config() {
  # source внутри функции создаёт переменные только в локальном скоупе.
  # Используем declare -g чтобы они стали глобальными.
  while IFS= read -r _line; do
    _line="${_line%$'\r'}"
    [[ $_line =~ ^[[:space:]]*# ]] && continue   # комментарий
    [[ -z ${_line// }            ]] && continue   # пустая строка
    [[ $_line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue  # не присваивание
    local _vname="${_line%%=*}"
    local _vval="${_line#*=}"
    eval "declare -g ${_vname}=${_vval}"  # глобальная переменная
  done < "$CONFIG_FILE"

  for stage in "${STAGES[@]}"; do
    local _h="STAGE_HOST_${stage}"           && STAGE_HOST[$stage]="${!_h:-}"
    local _p="STAGE_PORT_${stage}"           && STAGE_PORT[$stage]="${!_p:-}"
    local _l="STAGE_IS_LOCAL_${stage}"       && STAGE_IS_LOCAL[$stage]="${!_l:-false}"
    local _a="STAGE_AUTH_${stage}"           && STAGE_AUTH[$stage]="${!_a:-}"
    local _k="STAGE_ROOT_KEY_${stage}"       && STAGE_ROOT_KEY[$stage]="${!_k:-}"
    local _r="STAGE_ROOT_PASS_${stage}"      && STAGE_ROOT_PASS[$stage]="${!_r:-}"
    local _c="STAGE_CONTAINER_ID_${stage}"   && STAGE_CONTAINER_ID[$stage]="${!_c:-}"
    local _d="STAGE_DOMAIN_${stage}"         && STAGE_DOMAIN[$stage]="${!_d:-}"
    local _dm="STAGE_DB_MODE_${stage}"       && STAGE_DB_MODE[$stage]="${!_dm:-}"
    local _dh="STAGE_DB_HOST_${stage}"       && STAGE_DB_HOST[$stage]="${!_dh:-}"
    local _dp="STAGE_DB_PORTNUM_${stage}"    && STAGE_DB_PORTNUM[$stage]="${!_dp:-}"
    local _dn="STAGE_DB_NAME_${stage}"       && STAGE_DB_NAME[$stage]="${!_dn:-}"
    local _du="STAGE_DB_USER_${stage}"       && STAGE_DB_USER[$stage]="${!_du:-}"
    local _dw="STAGE_DB_PASSWORD_${stage}"   && STAGE_DB_PASSWORD[$stage]="${!_dw:-}"
    local _dc="STAGE_DB_ALLOWED_CIDR_${stage}" && STAGE_DB_ALLOWED_CIDR[$stage]="${!_dc:-}"
    local _sh="STAGE_DB_SSH_HOST_${stage}"   && STAGE_DB_SSH_HOST[$stage]="${!_sh:-}"
    local _sp="STAGE_DB_SSH_PORT_${stage}"   && STAGE_DB_SSH_PORT[$stage]="${!_sp:-}"
    local _sa="STAGE_DB_SSH_AUTH_${stage}"   && STAGE_DB_SSH_AUTH[$stage]="${!_sa:-}"
    local _sk="STAGE_DB_SSH_KEY_${stage}"    && STAGE_DB_SSH_KEY[$stage]="${!_sk:-}"
    local _sw="STAGE_DB_SSH_PASS_${stage}"   && STAGE_DB_SSH_PASS[$stage]="${!_sw:-}"
  done

  # Восстанавливаем .cicd/.env.<stage> из конфига если файл отсутствует
  for stage in "${STAGES[@]}"; do
    local envfile="${CICD_DIR}/.env.${stage}"
    [[ -f "$envfile" ]] && continue
    local vars=()
    mapfile -t vars < <(compgen -v "STAGE_ENV_${stage}_" 2>/dev/null || true)
    if [[ ${#vars[@]} -gt 0 ]]; then
      : > "$envfile"
      for var in "${vars[@]}"; do
        local ekey="${var#STAGE_ENV_${stage}_}"
        printf "%s=%s\n" "$ekey" "${!var}" >> "$envfile"
      done
      ok "Восстановлен ${envfile} из конфига"
    fi
  done
}

archive_config() {
  local ts; ts=$(date '+%Y%m%d_%H%M%S')
  local dst="${CONFIG_FILE%.md}_${ts}.md"
  mv "$CONFIG_FILE" "$dst"
  ok "Старый конфиг → ${dst}"
}

# Сбрасывает фазу и все последующие (чтобы они перезапустились)
# _reset_phases_from IDX  где IDX — индекс в PHASE_ORDER (0-based)
_reset_phases_from() {
  local from=$1
  local stages_snapshot=("${STAGES[@]}")
  # Полный упорядоченный список всех phase-ключей
  local -a PHASE_ORDER=("3")
  for s in "${stages_snapshot[@]}"; do PHASE_ORDER+=("4_${s}"); done
  for s in "${stages_snapshot[@]}"; do PHASE_ORDER+=("45_${s}"); done
  for s in "${stages_snapshot[@]}"; do PHASE_ORDER+=("5_${s}"); done
  for s in "${stages_snapshot[@]}"; do PHASE_ORDER+=("6_${s}"); done
  for s in "${stages_snapshot[@]}"; do PHASE_ORDER+=("65_${s}"); done
  PHASE_ORDER+=("7" "75" "8" "9")

  # Помечаем все фазы ДО выбранной как выполненные —
  # чтобы main loop не перезапускал незавершённые предыдущие фазы.
  for (( i=0; i<from; i++ )); do
    local key="${PHASE_ORDER[$i]}"
    local var="PHASE_${key}_DONE"
    eval "declare -g ${var}=true"
    sed -i "s/^PHASE_${key}_DONE=.*$/PHASE_${key}_DONE='true'/" "$CONFIG_FILE" 2>/dev/null || true
  done

  # Сбрасываем выбранную фазу и все последующие.
  for (( i=from; i<${#PHASE_ORDER[@]}; i++ )); do
    local key="${PHASE_ORDER[$i]}"
    local var="PHASE_${key}_DONE"
    eval "declare -g ${var}=''"
    sed -i "s/^PHASE_${key}_DONE=.*$/PHASE_${key}_DONE=''/" "$CONFIG_FILE" 2>/dev/null || true
  done
}

# Показывает найденный конфиг и спрашивает: продолжить / с шага / заново
# Возвращает 0 = конфиг загружен, 1 = новая настройка
init_config() {
  [[ ! -f "$CONFIG_FILE" ]] && return 1

  local saved_date stages_line
  saved_date=$(grep '^# CI/CD Setup Config' "$CONFIG_FILE" \
    | sed 's/.*saved: //' || echo "неизвестно")
  stages_line=$(grep '^STAGES=' "$CONFIG_FILE" \
    | sed "s/^STAGES=(\(.*\))/\1/" || echo "?")

  # Аннотации фаз
  declare -A _PHASE_DESC=(
    [3]="Configure stages"
    [7]="Generate GitHub Actions workflow"
    [8]="Setup GitHub secrets & environments"
    [9]="Commit & push"
  )
  _phase_label() {   # _phase_label KEY  →  "4_test — Provision server (test)"
    local k=$1
    if [[ -v _PHASE_DESC[$k] ]]; then
      echo "${k} — ${_PHASE_DESC[$k]}"
    elif [[ $k =~ ^4_(.+)$ ]];  then echo "${k} — Provision server (${BASH_REMATCH[1]})"
    elif [[ $k =~ ^45_(.+)$ ]]; then echo "${k} — Bootstrap PostgreSQL (${BASH_REMATCH[1]})"
    elif [[ $k =~ ^5_(.+)$ ]];  then echo "${k} — Collect .env (${BASH_REMATCH[1]})"
    elif [[ $k =~ ^6_(.+)$ ]];  then echo "${k} — Generate docker-compose (${BASH_REMATCH[1]})"
    elif [[ $k =~ ^65_(.+)$ ]]; then echo "${k} — Nginx reverse proxy (${BASH_REMATCH[1]})"
    else echo "$k"
    fi
  }

  echo
  log "Найден конфиг от: ${saved_date}"
  printf "  ${W}Stages:${N} %s\n" "$stages_line"
  echo
  printf "  ${W}Статус фаз:${N}\n"
  # Фазы 1 и 2 не сохраняются в конфиг — они всегда выполняются при старте
  printf "    ${G}✓${N} 1 — Prerequisites\n"
  printf "    ${G}✓${N} 2 — Repository detection\n"
  while IFS= read -r _pline; do
    local pkey; pkey=$(echo "$_pline" | sed 's/PHASE_//;s/_DONE=.*//')
    local done_val; done_val=$(echo "$_pline" | sed 's/.*_DONE=//')
    if [[ "$done_val" == "true" ]]; then
      printf "    ${G}✓${N} %s\n" "$(_phase_label "$pkey")"
    else
      printf "    ${Y}·${N} %s\n" "$(_phase_label "$pkey")"
    fi
  done < <(grep '^PHASE_.*_DONE=' "$CONFIG_FILE" 2>/dev/null | sort || true)
  echo
  printf "  ${W}1)${N} Продолжить с последней незавершённой фазы\n"
  printf "  ${W}2)${N} Выбрать конкретную фазу для перезапуска\n"
  printf "  ${W}3)${N} Начать заново (архивировать конфиг)\n"
  echo

  local choice
  prompt choice "Выбор [1/2/3]"
  choice="${choice:-1}"

  case "$choice" in
    2)
      load_config
      _migrate_deploy_keys

      # Строим меню фаз (1 и 2 всегда выполняются, не хранятся в конфиге)
      local -a PHASE_LABELS=(
        "1 — Prerequisites"
        "2 — Repository detection"
        "3 — Configure stages"
      )
      for s in "${STAGES[@]}"; do PHASE_LABELS+=("4_${s} — Provision server (${s})"); done
      for s in "${STAGES[@]}"; do PHASE_LABELS+=("45_${s} — Bootstrap PostgreSQL (${s})"); done
      for s in "${STAGES[@]}"; do PHASE_LABELS+=("5_${s} — Collect .env (${s})"); done
      for s in "${STAGES[@]}"; do PHASE_LABELS+=("6_${s} — Generate docker-compose (${s})"); done
      for s in "${STAGES[@]}"; do PHASE_LABELS+=("65_${s} — Nginx reverse proxy (${s})"); done
      PHASE_LABELS+=(
        "7 — Generate GitHub Actions workflow"
        "75 — Telegram notifications setup (optional)"
        "8 — Setup GitHub secrets & environments"
        "9 — Commit & push"
      )

      echo
      log "Выбери фазу для перезапуска (эта фаза и все последующие будут сброшены):"
      for (( i=0; i<${#PHASE_LABELS[@]}; i++ )); do
        local pkey="${PHASE_LABELS[$i]%% *}"
        local done_mark
        # Фазы 1 и 2 всегда выполнены (запускаются при каждом старте)
        if [[ "$pkey" == "1" || "$pkey" == "2" ]]; then
          done_mark=" ${G}✓${N}"
        else
          local var="PHASE_${pkey}_DONE"
          done_mark=""; [[ "${!var:-}" == "true" ]] && done_mark=" ${G}✓${N}"
        fi
        printf "  ${W}%2d)${N} %s%s\n" "$((i+1))" "${PHASE_LABELS[$i]}" "$done_mark"
      done
      echo

      local pnum
      prompt pnum "Номер фазы"
      if [[ "$pnum" =~ ^[0-9]+$ ]] && (( pnum >= 1 && pnum <= ${#PHASE_LABELS[@]} )); then
        # PHASE_ORDER в _reset_phases_from начинается с фазы 3 (индекс 0).
        # PHASE_LABELS: 1=idx0, 2=idx1, 3=idx2, 4_x=idx3...
        # Поэтому: reset_idx = max(0, pnum - 3)
        local reset_idx=$(( pnum <= 3 ? 0 : pnum - 3 ))
        _reset_phases_from "$reset_idx"
        ok "Фазы начиная с #${pnum} сброшены — перезапустятся при следующем шаге"
      else
        warn "Неверный ввод — продолжаем с последней незавершённой фазы"
      fi
      ;;
    3)
      archive_config
      return 1
      ;;
    *)
      load_config
      _migrate_deploy_keys
      ;;
  esac



  ok "Конфиг загружен"
  return 0
}

# ================================================================
#  PHASE 1 — Prerequisites
# ================================================================
check_prereqs() {
  step "Phase 1 — Prerequisites"

  local missing=()
  for cmd in git ssh ssh-keygen scp gh sed; do
    if command -v "$cmd" &>/dev/null; then ok "$cmd"; else
      warn "$cmd not found"; missing+=("$cmd")
    fi
  done

  if command -v sshpass &>/dev/null; then
    SSHPASS_AVAILABLE=true; ok "sshpass (password auth available)"
  else
    warn "sshpass not found — only SSH key auth for root will be available"
    warn "Install: sudo apt install sshpass   or   choco install sshpass"
  fi

  [[ ${#missing[@]} -gt 0 ]] && \
    die "Install missing tools and re-run: ${missing[*]}"

  if ! gh auth status &>/dev/null; then
    warn "GitHub CLI not authenticated. Launching gh auth login..."
    gh auth login
  fi
  ok "GitHub CLI authenticated as: $(gh api user --jq .login)"
}

# ================================================================
#  PHASE 2 — Repo detection
# ================================================================
detect_repo() {
  step "Phase 2 — Repository detection"

  [[ -d .git ]] || die "Not a git repository. Run from repo root."

  local remote
  remote=$(git remote get-url origin 2>/dev/null || echo "")
  [[ -z $remote ]] && die "No 'origin' remote. Push to GitHub first."

  if [[ $remote =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    REPO_OWNER="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
  else
    die "Remote doesn't look like GitHub URL: $remote"
  fi

  REPO_FULL="${REPO_OWNER}/${REPO_NAME}"
  ok "Repository : ${C}${REPO_FULL}${N}"
  ok "GHCR prefix: ${C}ghcr.io/${REPO_FULL}${N}"

  mkdir -p "$CICD_DIR"
  CONFIG_FILE="${CICD_DIR}/config.md"

  # .gitignore
  if ! grep -qxF "${CICD_DIR}/" .gitignore 2>/dev/null; then
    echo "${CICD_DIR}/" >> .gitignore
    ok "Added ${CICD_DIR}/ to .gitignore"
  fi

  # .dockerignore
  if [[ ! -f .dockerignore ]]; then
    cat > .dockerignore <<'DIGN'
.venv/
__pycache__/
*.pyc
*.pyo
.env
.env.*
!.env.example
.git/
.github/
.cicd/
*.db
*.sqlite
logs/
*.log
DIGN
    ok "Created .dockerignore"
  fi
}

# ================================================================
#  PHASE 3 — Stage configuration
# ================================================================
configure_stages() {
  step "Phase 3 — Stage configuration"

  local n
  prompt n "Number of deployment stages" "2"

  local defaults=("test" "prod")

  for (( i=0; i<n; i++ )); do
    local def="${defaults[$i]:-stage$((i+1))}"
    echo -e "\n${W}── Stage $((i+1)) / ${n} ──────────────────────────────${N}"

    local sname shost sport sauth use_local
    prompt sname "  Stage name"         "$def"
    prompt use_local "  Use current machine for this stage? (y/n)" "${STAGE_IS_LOCAL[$def]:-n}"
    prompt shost "  Server IP / hostname" ""
    prompt sport "  SSH port"           "22"

    STAGES+=("$sname")
    STAGE_HOST["$sname"]="$shost"
    STAGE_PORT["$sname"]="$sport"
    if [[ "${use_local,,}" == y* ]]; then
      STAGE_IS_LOCAL["$sname"]="true"
      STAGE_AUTH["$sname"]="local"
      STAGE_ROOT_KEY["$sname"]=""
      STAGE_ROOT_PASS["$sname"]=""
      ok "Stage '${sname}' will be provisioned on the current machine"
    else
      STAGE_IS_LOCAL["$sname"]="false"

      # Auth method — always ask, check sshpass only if pass chosen
      read -re -p "  ${_rW}Root auth method${_rN} [key/${_rC}pass${_rN}]: " sauth
      sauth="${sauth%$'\r'}"
      sauth=${sauth:-pass}

      if [[ $sauth == pass ]] && ! $SSHPASS_AVAILABLE; then
        echo
        warn "Password auth requires sshpass, which is not installed."
        warn "Install it and re-run:"
        warn "  Linux : sudo apt install sshpass"
        warn "  Mac   : brew install hudochenkov/sshpass/sshpass"
        warn "  Windows (choco): choco install sshpass"
        echo
        if yn "  Switch to key-based auth instead?" "y"; then
          sauth="key"
        else
          die "Cannot continue without sshpass. Install it first."
        fi
      fi

      STAGE_AUTH["$sname"]="$sauth"

      case $sauth in
        key)
          local kf
          prompt kf "  Root SSH key path" "$HOME/.ssh/id_rsa"
          [[ -f $kf ]] || die "Key file not found: $kf"
          STAGE_ROOT_KEY["$sname"]="$kf"
          STAGE_ROOT_PASS["$sname"]=""
          ;;
        pass)
          local rp
          prompt_secret rp "  Root password for $shost"
          STAGE_ROOT_PASS["$sname"]="$rp"
          STAGE_ROOT_KEY["$sname"]=""
          ;;
        *) die "Unknown auth: $sauth (use 'key' or 'pass')" ;;
      esac
    fi

    configure_stage_database "$sname"

    ok "Stage '${sname}' → ${shost}:${sport} (auth: ${STAGE_AUTH[$sname]})"
  done
}

# ================================================================
#  PHASE 4 — Server provisioning
# ================================================================
provision_server() {
  local stage=$1
  local host="${STAGE_HOST[$stage]}"
  local project_dir="${DEPLOY_DIR_BASE}/${REPO_NAME}"

  step "Phase 4 — Provisioning server: ${stage} (${host})"

  # Generate deploy keypair locally
  _init_ssh_dir
  local keyfile; keyfile=$(deploy_key "$stage")
  if [[ ! -f $keyfile ]]; then
    ssh-keygen -t ed25519 -f "$keyfile" -N "" \
      -C "cicd-${stage}-${REPO_NAME}" -q
    fix_key_perms "$keyfile"
    ok "Deploy keypair: ${keyfile}"
  else
    fix_key_perms "$keyfile"   # fix permissions on re-run
    ok "Deploy keypair already exists: ${keyfile}"
  fi

  local pubkey
  pubkey=$(cat "${keyfile}.pub")

  log "Connecting to ${host} as root..."

  # Run provisioning on remote server
  _root_ssh "$stage" bash << REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "──────────────────────────────────────────"
echo "  Provisioning: ${stage} @ \$(hostname)"
echo "──────────────────────────────────────────"

# ── Docker ────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
  echo "✓ Docker already installed: \$(docker --version)"
else
  echo "▶ Installing Docker..."
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker --now
  echo "✓ Docker installed: \$(docker --version)"
fi

# ── Docker Compose plugin check ───────────────────────────────
if docker compose version &>/dev/null; then
  echo "✓ Docker Compose: \$(docker compose version)"
else
  echo "▶ Installing Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin
fi

# ── Deployer user ─────────────────────────────────────────────
if id ${DEPLOY_USER} &>/dev/null; then
  echo "✓ User '${DEPLOY_USER}' already exists"
else
  echo "▶ Creating user '${DEPLOY_USER}'..."
  useradd -m -s /bin/bash ${DEPLOY_USER}
fi
usermod -aG docker ${DEPLOY_USER}

# ── SSH authorized_keys ───────────────────────────────────────
echo "▶ Installing deploy public key..."
mkdir -p /home/${DEPLOY_USER}/.ssh
touch /home/${DEPLOY_USER}/.ssh/authorized_keys
# Remove old key for this stage (idempotent re-runs)
grep -v "cicd-${stage}-${REPO_NAME}" \
  /home/${DEPLOY_USER}/.ssh/authorized_keys > /tmp/_ak || true
echo "${pubkey}" >> /tmp/_ak
mv /tmp/_ak /home/${DEPLOY_USER}/.ssh/authorized_keys
chmod 700  /home/${DEPLOY_USER}/.ssh
chmod 600  /home/${DEPLOY_USER}/.ssh/authorized_keys
chown -R ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh
echo "✓ Authorized key installed"

# ── Project directory ─────────────────────────────────────────
echo "▶ Creating ${project_dir}..."
mkdir -p ${project_dir}
chown ${DEPLOY_USER}:${DEPLOY_USER} ${project_dir}
echo "✓ Directory ready: ${project_dir}"

echo "──────────────────────────────────────────"
echo "  Done provisioning ${stage}"
echo "──────────────────────────────────────────"
REMOTE

  ok "Server '${stage}' provisioned"
}

# ================================================================
#  PHASE 4.5 — PostgreSQL bootstrap on target host
# ================================================================
bootstrap_stage_database() {
  local stage=$1
  local mode="${STAGE_DB_MODE[$stage]:-host}"

  step "Phase 4.5 — PostgreSQL bootstrap: ${stage}"

  if [[ "$mode" == "container" ]]; then
    ok "Stage '${stage}': DB mode is 'container' — host PostgreSQL bootstrap skipped"
    return
  fi

  local ssh_host ssh_port ssh_auth ssh_key ssh_pass allowed_cidr
  ssh_host="${STAGE_DB_SSH_HOST[$stage]:-${STAGE_HOST[$stage]:-}}"
  ssh_port="${STAGE_DB_SSH_PORT[$stage]:-${STAGE_PORT[$stage]:-22}}"
  ssh_auth="${STAGE_DB_SSH_AUTH[$stage]:-${STAGE_AUTH[$stage]:-pass}}"
  ssh_key="${STAGE_DB_SSH_KEY[$stage]:-${STAGE_ROOT_KEY[$stage]:-}}"
  ssh_pass="${STAGE_DB_SSH_PASS[$stage]:-${STAGE_ROOT_PASS[$stage]:-}}"
  allowed_cidr="${STAGE_DB_ALLOWED_CIDR[$stage]:-172.16.0.0/12}"

  log "Bootstrapping PostgreSQL for stage '${stage}' on ${ssh_host}:${ssh_port} ..."
  local -a bootstrap_cmd=(bash "$(dirname "$0")/setup-postgres-host.sh")
  if [[ "${STAGE_IS_LOCAL[$stage]:-false}" == "true" && "$mode" == "host" ]]; then
    bootstrap_cmd+=(--local)
  else
    bootstrap_cmd+=(--host "$ssh_host" --port "$ssh_port" --auth "$ssh_auth")
    [[ -n "$ssh_key"  ]] && bootstrap_cmd+=(--key-file "$ssh_key")
    [[ -n "$ssh_pass" ]] && bootstrap_cmd+=(--root-password "$ssh_pass")
  fi
  bootstrap_cmd+=(
    --db-name "${STAGE_DB_NAME[$stage]}"
    --db-user "${STAGE_DB_USER[$stage]}"
    --db-password "${STAGE_DB_PASSWORD[$stage]}"
    --allowed-cidr "$allowed_cidr"
  )
  "${bootstrap_cmd[@]}"

  ok "PostgreSQL bootstrap done for stage '${stage}'"
}

# ================================================================
#  PHASE 5 — .env collection & upload
# ================================================================
collect_env() {
  local stage=$1
  local envfile="${CICD_DIR}/.env.${stage}"
  local project_dir="${DEPLOY_DIR_BASE}/${REPO_NAME}"
  local computed_db_url

  computed_db_url="$(stage_database_url "$stage")"

  step "Phase 5 — .env for stage: ${stage}"

  if [[ ! -f .env.example ]]; then
    warn "No .env.example found — skipping env collection for ${stage}"
    return
  fi

  echo
  if ! yn "Configure .env for stage '${stage}' now?" "y"; then
    cp .env.example "$envfile"
    warn "Skipped — заполни ${envfile} и загрузи на сервер вручную"
    warn "  scp ${envfile} ${DEPLOY_USER}@${STAGE_HOST[$stage]}:${DEPLOY_DIR_BASE}/${REPO_NAME}/.env"
    return
  fi

  echo
  echo "Press ENTER to keep the example/default value."
  echo

  : > "$envfile"

  # Load file into array first — keeps stdin free for user input (no redirect needed)
  local -a _lines
  mapfile -t _lines < .env.example

  for line in "${_lines[@]}"; do
    line="${line%$'\r'}"   # strip Windows CRLF

    # Pass through comments and blank lines unchanged
    if [[ $line =~ ^[[:space:]]*# ]] || [[ -z ${line// } ]]; then
      echo "$line" >> "$envfile"
      continue
    fi

    local key="${line%%=*}"
    local current="${line#*=}"
    local val

    if [[ "$key" == "DATABASE_URL" ]]; then
      current="$computed_db_url"
    fi

    prompt val "  ${key}" "${current}"

    if [[ -n $val ]]; then
      echo "${key}=${val}" >> "$envfile"
    else
      echo "$line" >> "$envfile"
    fi
  done

  ok ".env.${stage} saved locally in ${CICD_DIR}/"

  log "Uploading .env to ${STAGE_HOST[$stage]}:${project_dir}/.env ..."
  _root_scp "$stage" "$envfile" "${project_dir}/.env"
  _root_ssh "$stage" "chown ${DEPLOY_USER}:${DEPLOY_USER} ${project_dir}/.env && chmod 600 ${project_dir}/.env"
  ok ".env uploaded and secured (chmod 600)"
}

# ================================================================
#  PHASE 6 — docker-compose per stage
# ================================================================
generate_compose() {
  local stage=$1
  local image="ghcr.io/${REPO_FULL,,}:${stage}-latest"
  local outfile="docker-compose.${stage}.yml"
  local project_dir="${DEPLOY_DIR_BASE}/${REPO_NAME}"
  local source_file=""
  local db_mode="${STAGE_DB_MODE[$stage]:-host}"

  step "Phase 6 — docker-compose for stage: ${stage}"

  if [[ "$db_mode" == "container" && -f docker-compose.yml ]]; then
    source_file="docker-compose.yml"
    log "Using docker-compose.yml as source because DB mode is 'container'"
  elif [[ -f "${outfile}" ]]; then
    source_file="${outfile}"
    log "Using explicit stage compose from repo: ${source_file}"
  elif [[ -f docker-compose.yml ]]; then
    source_file="docker-compose.yml"
    log "Transforming ${source_file} → ${outfile}..."
  fi

  if [[ -n "$source_file" ]]; then
    if [[ "$source_file" == "$outfile" ]]; then
      tmp_out="${outfile}.generated"
    else
      tmp_out="$outfile"
    fi

    # 1. Replace "build: ." with "image: <ghcr-image>"
    # 2. Remove host-bind volume mounts like "- .:/app" or "- ./src:/foo"
    # 3. Remove "volumes:" keys left empty after step 2 (invalid yaml — must be array)
    sed \
      -e "s|build:[[:space:]]*\.[[:space:]]*$|image: ${image}|g" \
      -e '/^[[:space:]]*-[[:space:]]*\.\//d' \
      -e '/^[[:space:]]*-[[:space:]]*\.:/d' \
      "$source_file" \
    | awk '
      /^[[:space:]]+volumes:[[:space:]]*$/ { buf=$0; held=1; next }
      held {
        held=0
        # следующая строка — элемент списка → volumes: не пустой, оставляем
        if (/^[[:space:]]+-/) { print buf }
        # иначе — volumes: пустой, молча пропускаем buf
        print; next
      }
      { print }
    ' > "$tmp_out"

    if [[ "$db_mode" == "remote" ]]; then
      sed -i '/^[[:space:]]*extra_hosts:/,/^[[:space:]]*[^[:space:]-]/d' "$tmp_out"
    elif [[ "$db_mode" == "host" ]]; then
      grep -q 'host.docker.internal:host-gateway' "$tmp_out" || sed -i '/^[[:space:]]*env_file:[[:space:]]*.env[[:space:]]*$/a\    extra_hosts:\n      - "host.docker.internal:host-gateway"' "$tmp_out"
    fi

    if [[ "$source_file" == "$outfile" ]]; then
      mv "$tmp_out" "$outfile"
      ok "${outfile} normalized from explicit stage compose"
    else
      ok "${outfile} generated from ${source_file}"
    fi
  else
    warn "No suitable compose source found — generating minimal template"
    if [[ "$db_mode" == "container" ]]; then
      cat > "$outfile" << MINIMAL_COMPOSE
version: "3.9"

services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${STAGE_DB_USER[$stage]}
      POSTGRES_PASSWORD: ${STAGE_DB_PASSWORD[$stage]}
      POSTGRES_DB: ${STAGE_DB_NAME[$stage]}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${STAGE_DB_USER[$stage]}"]
      interval: 5s
      timeout: 5s
      retries: 5

  bot:
    image: ${image}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file: .env
    ports:
      - "8000:8000"
volumes:
  postgres_data:
MINIMAL_COMPOSE
    else
      cat > "$outfile" << MINIMAL_COMPOSE
version: "3.9"

services:
  bot:
    image: ${image}
    restart: unless-stopped
    env_file: .env
$( [[ "$db_mode" == "host" ]] && printf '    extra_hosts:\n      - "host.docker.internal:host-gateway"\n' )
    ports:
      - "8000:8000"
MINIMAL_COMPOSE
    fi
    ok "${outfile} created (minimal template)"
  fi

  log "Uploading ${outfile} to ${STAGE_HOST[$stage]}:${project_dir}/ ..."
  _root_scp "$stage" "$outfile" "${project_dir}/${outfile}"
  _root_ssh "$stage" "chown ${DEPLOY_USER}:${DEPLOY_USER} ${project_dir}/${outfile}"
  ok "${outfile} uploaded"
}

# ================================================================
#  PHASE 6.5 — Nginx reverse proxy per stage
# ================================================================
setup_nginx_stage() {
  local stage=$1
  local host="${STAGE_HOST[$stage]}"
  local envfile="${CICD_DIR}/.env.${stage}"
  local project_dir="${DEPLOY_DIR_BASE}/${REPO_NAME}"

  step "Phase 6.5 — Nginx for stage: ${stage}"

  echo
  log "Настройка nginx: внешний доступ к панели для стейджа '${stage}'"
  log "Сервер: ${host}"
  echo

  # Запрашиваем домен или IP
  local domain_input
  prompt domain_input \
    "Домен для панели (напр: dairy.example.com) или Enter — IP" ""

  local external_port web_url

  if [[ -n "$domain_input" ]]; then
    # ── Домен ──────────────────────────────────────────────────
    # Порт nginx (на котором слушает nginx на сервере, по умолчанию 80)
    prompt external_port "Порт nginx на сервере" "80"

    local use_ssl_input
    prompt use_ssl_input "Получить SSL сертификат через certbot? (y/n)" "y"

    # WEB_URL зависит только от SSL — порт в URL не нужен для стандартных 80/443
    local ssl_flag=""
    if [[ "$use_ssl_input" =~ ^[Yy] || "$external_port" == "443" ]]; then
      ssl_flag="--ssl"
      web_url="https://${domain_input}"
    else
      web_url="http://${domain_input}"
      # Указываем порт в URL только если nginx сам слушает на нестандартном порту
      [[ "$external_port" != "80" ]] && web_url="${web_url}:${external_port}"
    fi

    STAGE_DOMAIN[$stage]="$domain_input"

    log "Запускаю setup-nginx.sh для ${domain_input} (порт ${external_port})..."
    if bash "$(dirname "$0")/setup-nginx.sh" "$host" "$domain_input" "$external_port" "8000" $ssl_flag; then
      ok "Nginx настроен: ${web_url}"
    else
      warn "Nginx setup завершился с ошибкой — проверь вручную"
      warn "bash setup-nginx.sh ${host} ${domain_input} ${external_port} 8000 ${ssl_flag}"
    fi
  else
    # ── IP — nginx на нестандартном порту ──────────────────────
    prompt external_port "Внешний порт nginx" "8080"
    web_url="http://${host}:${external_port}"
    STAGE_DOMAIN[$stage]="${host}:${external_port}"

    log "Запускаю setup-nginx.sh для ${host}:${external_port}..."
    if bash "$(dirname "$0")/setup-nginx.sh" "$host" "$host" "$external_port" "8000"; then
      ok "Nginx настроен: ${web_url}"
    else
      warn "Nginx setup завершился с ошибкой — проверь вручную"
      warn "bash setup-nginx.sh ${host} ${host} ${external_port} 8000"
    fi
  fi

  # Сохраняем WEB_URL в .env стейджа
  if [[ -f "$envfile" ]]; then
    if grep -q "^WEB_URL=" "$envfile"; then
      sed -i "s|^WEB_URL=.*|WEB_URL=${web_url}|" "$envfile"
    else
      echo "WEB_URL=${web_url}" >> "$envfile"
    fi
    ok "WEB_URL=${web_url} → ${envfile}"

    # Загружаем обновлённый .env на сервер
    log "Обновляю .env на сервере..."
    _root_scp "$stage" "$envfile" "${project_dir}/.env"
    _root_ssh "$stage" "chown ${DEPLOY_USER}:${DEPLOY_USER} ${project_dir}/.env && chmod 600 ${project_dir}/.env"
    ok ".env обновлён на сервере"
  else
    warn ".env.${stage} не найден — создай вручную с WEB_URL=${web_url}"
  fi
}

# ================================================================
#  PHASE 7 — GitHub Actions workflow
# ================================================================
setup_telegram_notifications() {
  step "Phase 7.5 — Telegram notifications (optional)"

  echo
  printf "  Бот будет присылать отчёт после каждого пуша:\n"
  printf "  ${C}✅/❌ статус CI + деплоя, health-check домена, последние логи при ошибке${N}\n"
  echo

  if ! yn "Настроить Telegram-уведомления о деплоях?" "y"; then
    TG_NOTIFICATIONS=false
    ok "Пропущено. Можно включить позже, запустив скрипт с фазы 7.5"
    return
  fi

  echo
  log "Для уведомлений нужен бот. Можно использовать тот же бот что и у приложения,"
  log "или создать отдельный через @BotFather."
  echo

  local token_ok=false
  local bot_name=""
  for attempt in 1 2 3; do
    prompt_secret TG_BOT_TOKEN "Токен бота (@BotFather)"
    if [[ -z "$TG_BOT_TOKEN" ]]; then
      warn "Токен не введён — пропускаем"
      TG_NOTIFICATIONS=false
      return
    fi
    log "Проверяю токен..."
    local resp
    resp=$(curl -sf --max-time 10 \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe" 2>/dev/null || echo '{}')
    bot_name=$(echo "$resp" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('username',''))" \
      2>/dev/null || echo "")
    if [[ -n "$bot_name" ]]; then
      ok "Бот подключён: @${bot_name}"
      token_ok=true
      break
    else
      warn "Не удалось проверить токен (попытка ${attempt}/3)"
    fi
  done

  if ! $token_ok; then
    warn "Пропускаем Telegram — токен не прошёл проверку"
    TG_NOTIFICATIONS=false
    return
  fi

  echo
  log "Ваш Telegram chat_id (числовой ID) — узнать его:"
  log "  1. Напишите @${bot_name} любое сообщение"
  log "  2. Откройте: https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates"
  log "  3. Скопируйте число из поля  message.from.id  или  message.chat.id"
  log "  Либо напишите боту @userinfobot — он пришлёт ваш ID"
  echo
  prompt TG_ADMIN_CHAT_ID "Ваш Telegram chat_id"

  if [[ -z "$TG_ADMIN_CHAT_ID" ]]; then
    warn "chat_id не введён — пропускаем"
    TG_NOTIFICATIONS=false
    return
  fi

  # Отправляем тестовое сообщение
  log "Отправляю тестовое сообщение..."
  local send_resp
  send_resp=$(curl -sf --max-time 10 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_ADMIN_CHAT_ID}" \
    -d "parse_mode=HTML" \
    -d "text=🤖 <b>CI/CD setup</b>%0AТелеграм-уведомления настроены для репо <code>${REPO_FULL}</code>" \
    2>/dev/null || echo '{}')
  local ok_field
  ok_field=$(echo "$send_resp" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('ok','false'))" 2>/dev/null || echo "false")

  if [[ "$ok_field" == "True" ]] || [[ "$ok_field" == "true" ]]; then
    ok "Тестовое сообщение отправлено — проверь Telegram!"
    TG_NOTIFICATIONS=true
  else
    local tg_err
    tg_err=$(echo "$send_resp" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('description','unknown error'))" \
      2>/dev/null || echo "unknown")
    warn "Не удалось отправить сообщение: ${tg_err}"
    warn "Проверь chat_id и что бот добавлен в чат / написал вам"
    if yn "Всё равно сохранить настройки?" "n"; then
      TG_NOTIFICATIONS=true
    else
      TG_NOTIFICATIONS=false
    fi
  fi
}

generate_workflow() {
  step "Phase 7 — GitHub Actions workflow"

  mkdir -p .github/workflows
  local wf=".github/workflows/pipeline.yml"

  # Определяем ветку для каждого стейджа:
  #   первый стейдж → develop, последний (prod) → main
  #   если стейдж один — он на main
  local -A STAGE_BRANCH
  local stages_count="${#STAGES[@]}"
  if [[ "$stages_count" -eq 1 ]]; then
    STAGE_BRANCH["${STAGES[0]}"]="main"
  else
    STAGE_BRANCH["${STAGES[0]}"]="develop"
    for (( i=1; i<stages_count; i++ )); do
      STAGE_BRANCH["${STAGES[$i]}"]="main"
    done
  fi

  local deploy_branches
  deploy_branches=$(printf '%s\n' "${STAGE_BRANCH[@]}" | sort -u | paste -sd, | sed 's/,/, /g')

  # ── Notify secrets hint (written as YAML comment) ───────────────
  local tg_secrets_comment=""
  if $TG_NOTIFICATIONS; then
    tg_secrets_comment="#    TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID"
  fi

  # ── Static CI header ────────────────────────────────────────
  cat > "$wf" << CI_HEADER
name: CI/CD Pipeline

# ─────────────────────────────────────────────────────────────
#  Ветки → среды:
$(for stage in "${STAGES[@]}"; do
  printf "#    %-10s →  CI + Deploy %s\n" "${STAGE_BRANCH[$stage]}" "$stage"
done)#
#  Workflow разработки:
#    git push develop   →  автодеплой на тест
#    PR develop → main  →  автодеплой на прод после merge
${tg_secrets_comment:+#
#  GitHub Secrets:
#    SSH_HOST_*, SSH_PRIVATE_KEY_*
${tg_secrets_comment}
}# ─────────────────────────────────────────────────────────────

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  DEPLOY_USER: ${DEPLOY_USER}
  DEPLOY_DIR: ${DEPLOY_DIR_BASE}/${REPO_NAME}

jobs:

  # ───────────────────────────────────────────────────────────
  # CI — lint + docker build  (runs on every push / PR)
  # ───────────────────────────────────────────────────────────
  ci:
    name: CI
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python 3.12
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      - name: Install deps + linter
        run: pip install -r requirements.txt ruff

      - name: Lint
        run: ruff check .

      - name: Docker build smoke-test
        run: docker build -t app:ci-test .

CI_HEADER

  # ── Dynamic deploy jobs per stage (independent, branch-based) ──
  for stage in "${STAGES[@]}"; do
    local UPPER branch proj_dir db_mode
    UPPER=$(echo "$stage" | tr '[:lower:]' '[:upper:]')
    branch="${STAGE_BRANCH[$stage]}"
    proj_dir="${DEPLOY_DIR_BASE}/${REPO_NAME}"
    db_mode="${STAGE_DB_MODE[$stage]:-host}"

    cat >> "$wf" << DEPLOY_JOB

  # ───────────────────────────────────────────────────────────
  # Deploy → ${stage}   (${branch} branch only, needs: ci)
  # ───────────────────────────────────────────────────────────
  deploy-${stage}:
    name: "Deploy → ${stage}"
    runs-on: ubuntu-latest
    needs: ci
    if: github.ref == 'refs/heads/${branch}' && github.event_name == 'push'
    environment: ${stage}
    outputs:
      health: \${{ steps.health.outputs.result }}
      app_logs: \${{ steps.health.outputs.logs }}
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Lowercase image name
        run: echo "IMAGE_NAME=\${GITHUB_REPOSITORY,,}" >> \$GITHUB_ENV

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: \${{ env.REGISTRY }}
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}

      - name: Build and push → ${stage}
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            \${{ env.REGISTRY }}/\${{ env.IMAGE_NAME }}:${stage}-latest
            \${{ env.REGISTRY }}/\${{ env.IMAGE_NAME }}:${stage}-\${{ github.sha }}

      - name: Setup SSH agent
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: \${{ secrets.SSH_PRIVATE_KEY_${UPPER} }}

      - name: Add server to known hosts
        run: ssh-keyscan -H \${{ secrets.SSH_HOST_${UPPER} }} >> ~/.ssh/known_hosts

      - name: Upload compose file
        env:
          SSH_HOST: \${{ secrets.SSH_HOST_${UPPER} }}
        run: |
          scp -P 22 docker-compose.${stage}.yml ${DEPLOY_USER}@\$SSH_HOST:${proj_dir}/docker-compose.${stage}.yml

      - name: Deploy via SSH
        env:
          SSH_HOST: \${{ secrets.SSH_HOST_${UPPER} }}
          GHCR_TOKEN: \${{ secrets.GITHUB_TOKEN }}
          ACTOR: \${{ github.actor }}
        run: |
          ssh -p 22 ${DEPLOY_USER}@\$SSH_HOST bash << 'SSHEOF'
            set -e
            echo "\$GHCR_TOKEN" | docker login ghcr.io -u \$ACTOR --password-stdin
            cd ${proj_dir}
            test -f .env
            DB_URL=\$(grep '^DATABASE_URL=' .env | cut -d= -f2- || true)
            if [[ -z "\$DB_URL" ]]; then
              echo "DATABASE_URL is missing in ${proj_dir}/.env" >&2
              exit 1
            fi
            if [[ "\$DB_URL" == *"@localhost:"* || "\$DB_URL" == *"@127.0.0.1:"* ]]; then
              echo "DATABASE_URL points to localhost/127.0.0.1; container will not reach host PostgreSQL" >&2
              exit 1
            fi
$( if [[ "$db_mode" == "host" ]]; then cat <<EOF
            grep -q 'host.docker.internal:host-gateway' docker-compose.${stage}.yml || {
              echo "docker-compose.${stage}.yml is missing host-gateway mapping" >&2
              exit 1
            }
EOF
elif [[ "$db_mode" == "container" ]]; then cat <<EOF
            grep -q '^  postgres:' docker-compose.${stage}.yml || {
              echo "docker-compose.${stage}.yml is missing postgres service for container DB mode" >&2
              exit 1
            }
            [[ "\$DB_URL" == *"@postgres:"* ]] || {
              echo "DATABASE_URL must point to postgres service in container DB mode" >&2
              exit 1
            }
EOF
fi )
            docker compose -f docker-compose.${stage}.yml config -q
            docker compose -f docker-compose.${stage}.yml pull
            docker compose -f docker-compose.${stage}.yml up -d --remove-orphans
            docker image prune -f
          SSHEOF

      - name: Health check — container + domain
        id: health
        env:
          SSH_HOST: \${{ secrets.SSH_HOST_${UPPER} }}
        run: |
          sleep 8
          RAW=\$(ssh -p 22 ${DEPLOY_USER}@\$SSH_HOST bash << 'HEALTHEOF'
            cd ${proj_dir}
            CONTAINERS=\$(docker compose -f docker-compose.${stage}.yml ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | tail -n +2)
            LOGS=\$(docker compose -f docker-compose.${stage}.yml logs --tail=20 bot 2>&1)
            LOCAL_HTTP=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 8 http://localhost:8000/ 2>/dev/null || echo "NO_RESPONSE")
            WEB_URL=\$(grep '^WEB_URL=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
            if [[ -n "\$WEB_URL" ]]; then
              DOMAIN_HTTP=\$(curl -sf -o /dev/null -w "%{http_code}" --max-time 12 "\$WEB_URL/" 2>/dev/null || echo "NO_RESPONSE")
            else
              DOMAIN_HTTP="NO_URL"
            fi
            echo "---CONTAINERS---"
            echo "\$CONTAINERS"
            echo "---LOCAL---"
            echo "\$LOCAL_HTTP"
            echo "---DOMAIN---"
            echo "\$DOMAIN_HTTP \$WEB_URL"
            echo "---LOGS---"
            echo "\$LOGS"
          HEALTHEOF
          )
          echo "\$RAW"

          LOCAL_CODE=\$(echo "\$RAW" | grep -A1 '^---LOCAL---' | tail -1 | tr -d '[:space:]')
          DOMAIN_LINE=\$(echo "\$RAW" | grep -A1 '^---DOMAIN---' | tail -1)
          DOMAIN_CODE=\$(echo "\$DOMAIN_LINE" | awk '{print \$1}')
          DOMAIN_URL=\$(echo "\$DOMAIN_LINE" | awk '{print \$2}')
          LOGS=\$(echo "\$RAW" | sed -n '/^---LOGS---/,\$p' | tail -n +2)

          # Build result string
          if [[ "\$LOCAL_CODE" =~ ^(200|301|302|404)$ ]]; then
            LOCAL_STATUS="✅ localhost:\$LOCAL_CODE"
          else
            LOCAL_STATUS="❌ localhost:\$LOCAL_CODE"
          fi
          if [[ "\$DOMAIN_CODE" =~ ^(200|301|302|404)$ ]]; then
            DOMAIN_STATUS="✅ domain:\$DOMAIN_CODE"
          elif [[ "\$DOMAIN_CODE" == "NO_URL" ]]; then
            DOMAIN_STATUS="— domain:no WEB_URL"
          else
            DOMAIN_STATUS="❌ domain:\$DOMAIN_CODE (\$DOMAIN_URL)"
          fi

          RESULT="\$LOCAL_STATUS | \$DOMAIN_STATUS"
          echo "result=\$RESULT" >> \$GITHUB_OUTPUT

          SHORT_LOGS=\$(echo "\$LOGS" | tail -15 | cut -c1-900)
          SHORT_LOGS="\${SHORT_LOGS//'%'/'%25'}"
          SHORT_LOGS="\${SHORT_LOGS//\$'\\n'/'%0A'}"
          SHORT_LOGS="\${SHORT_LOGS//\$'\\r'/'%0D'}"
          echo "logs=\$SHORT_LOGS" >> \$GITHUB_OUTPUT

DEPLOY_JOB
  done

  # ── Telegram notify job (only if configured) ────────────────
  if $TG_NOTIFICATIONS; then
    local deploy_needs="" deploy_results="" deploy_health_block=""
    for stage in "${STAGES[@]}"; do
      deploy_needs="${deploy_needs}, deploy-${stage}"
      deploy_results="${deploy_results}
          DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_STATUS: \${{ needs.deploy-${stage}.result }}
          DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_HEALTH: \${{ needs.deploy-${stage}.outputs.health }}
          DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_LOGS: \${{ needs.deploy-${stage}.outputs.app_logs }}"
      deploy_health_block="${deploy_health_block}
          if [[ \"\$DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_STATUS\" != \"skipped\" ]]; then
            ICON=\$(deploy_icon \"\$DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_STATUS\")
            TEXT=\"\${TEXT}
          Deploy ${stage}: \${ICON} \$DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_STATUS
          Health ${stage}: \${DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_HEALTH:-—}\"
          fi"
    done
    local log_block=""
    for stage in "${STAGES[@]}"; do
      log_block="${log_block}
          if [[ \"\$DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_STATUS\" == \"success\" && \"\$DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_HEALTH\" == *\"❌\"* && -n \"\$DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_LOGS\" ]]; then
            DECODED=\$(python3 -c \"import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))\" \"\$DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_LOGS\" 2>/dev/null || echo \"\$DEPLOY_$(echo "$stage" | tr '[:lower:]' '[:upper:]')_LOGS\")
            TEXT=\"\${TEXT}

          <b>📜 Логи ${stage}:</b>
          <pre>\${DECODED}</pre>\"
          fi"
    done

    cat >> "$wf" << NOTIFY_JOB

  # ───────────────────────────────────────────────────────────
  # Telegram notify  (always, after all jobs)
  # ───────────────────────────────────────────────────────────
  notify:
    name: "Telegram notify"
    runs-on: ubuntu-latest
    if: always()
    needs: [ci${deploy_needs}]
    steps:
      - name: Send report
        env:
          BOT_TOKEN: \${{ secrets.TELEGRAM_BOT_TOKEN }}
          CHAT_ID: \${{ secrets.TELEGRAM_CHAT_ID }}
          CI_STATUS: \${{ needs.ci.result }}${deploy_results}
          BRANCH: \${{ github.ref_name }}
          COMMIT_MSG: \${{ github.event.head_commit.message }}
          RUN_URL: \${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_id }}
          ACTOR: \${{ github.actor }}
        run: |
          ci_icon()    { [[ "\$1" == "success" ]] && echo "✅" || [[ "\$1" == "skipped" ]] && echo "⏭" || echo "❌"; }
          deploy_icon(){ [[ "\$1" == "success" ]] && echo "🚀" || [[ "\$1" == "skipped" ]] && echo "—" || echo "💥"; }

          CI_ICON=\$(ci_icon "\$CI_STATUS")
          COMMIT_FIRST=\$(echo "\$COMMIT_MSG" | head -1 | cut -c1-80)

          TEXT="\${CI_ICON} <b>CI/CD · \${BRANCH}</b>
          <code>\${COMMIT_FIRST}</code>
          👤 \${ACTOR}

          CI: \${CI_ICON} \${CI_STATUS}"
${deploy_health_block}
          TEXT="\${TEXT}

          <a href=\"\${RUN_URL}\">📋 Открыть run</a>"
${log_block}
          curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
            -d chat_id="\${CHAT_ID}" \\
            -d parse_mode="HTML" \\
            -d disable_web_page_preview="true" \\
            --data-urlencode "text=\${TEXT}" \\
            | python3 -c "import sys,json; r=json.load(sys.stdin); print('Sent OK' if r.get('ok') else f'TG error: {r}')"

NOTIFY_JOB
  fi

  ok "Workflow: ${wf}"
}

# ================================================================
#  PHASE 8 — GitHub Environments + Secrets
# ================================================================
setup_github() {
  step "Phase 8 — GitHub Environments & Secrets"

  # ── Per-stage secrets ────────────────────────────────────────
  # GITHUB_TOKEN используется для docker pull на сервере — PAT не нужен
  for stage in "${STAGES[@]}"; do
    local UPPER privkey
    UPPER=$(echo "$stage" | tr '[:lower:]' '[:upper:]')
    privkey=$(cat "$(deploy_key "$stage")")

    log "Setting GitHub secrets for stage '${stage}'..."
    gh secret set "SSH_HOST_${UPPER}"        --repo "$REPO_FULL" --body "${STAGE_HOST[$stage]}"
    gh secret set "SSH_PRIVATE_KEY_${UPPER}" --repo "$REPO_FULL" --body "$privkey"
    ok "Secrets set: SSH_HOST/PRIVATE_KEY_${UPPER}"

    # Create GitHub Environment
    log "Creating GitHub Environment '${stage}'..."
    echo '{}' | gh api "repos/${REPO_FULL}/environments/${stage}" \
      --method PUT --input - --silent \
      && ok "GitHub Environment '${stage}' created" \
      || warn "Could not create environment (may already exist)"
  done

  # ── Telegram secrets (если настроены) ───────────────────────
  if $TG_NOTIFICATIONS && [[ -n "$TG_BOT_TOKEN" ]] && [[ -n "$TG_ADMIN_CHAT_ID" ]]; then
    log "Setting Telegram notification secrets..."
    gh secret set "TELEGRAM_BOT_TOKEN" --repo "$REPO_FULL" --body "$TG_BOT_TOKEN"
    gh secret set "TELEGRAM_CHAT_ID"   --repo "$REPO_FULL" --body "$TG_ADMIN_CHAT_ID"
    ok "Secrets set: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID"
  fi
}

# ================================================================
#  PHASE 9 — Commit & Push
# ================================================================
commit_and_push() {
  step "Phase 9 — Commit & Push"

  warn "Для пуша нужен scope ${W}repo${N} (или ${W}contents:write${N}) в gh auth токене."
  warn "Проверь: gh auth status  →  если нет — переавторизуйся: gh auth login"
  echo

  # Настраиваем git credential helper через gh — push без логина/пароля
  gh auth setup-git

  git add .github/workflows/pipeline.yml .gitignore
  [[ -f .dockerignore ]] && git add .dockerignore

  for stage in "${STAGES[@]}"; do
    [[ -f "docker-compose.${stage}.yml" ]] && git add "docker-compose.${stage}.yml"
  done

  if git diff --cached --quiet; then
    ok "Nothing new to commit — skipping"
  else
    local stages_str
    stages_str=$(IFS=,; echo "${STAGES[*]}")
    git commit -m "ci: add CI/CD pipeline (stages: ${stages_str})"
    git push origin HEAD
    ok "Committed and pushed pipeline files"
  fi

  # ── Создаём ветку develop (если не существует) ────────────────
  echo
  log "Настраиваю ветку develop..."
  if git ls-remote --exit-code --heads origin develop &>/dev/null; then
    ok "Ветка 'develop' уже существует на remote"
  else
    git checkout -b develop 2>/dev/null || git checkout develop
    git push origin develop
    ok "Ветка 'develop' создана и запушена"
    git checkout main
    git checkout develop 2>/dev/null || true
  fi

  echo
  printf "${G}${W}╔══════════════════════════════════════════════════════════╗${N}\n"
  printf "${G}${W}║  Workflow разработки готов                               ║${N}\n"
  printf "${G}${W}╚══════════════════════════════════════════════════════════╝${N}\n"
  echo
  printf "  ${W}Разработку вести в ветке:${N}  ${C}develop${N}\n"
  printf "  ${W}Деплой на тест:${N}            ${C}git push origin develop${N}\n"
  printf "  ${W}Деплой на прод:${N}            ${C}PR develop → main${N}  (или merge в main)\n"
  echo
  printf "  Ты сейчас на ветке: ${W}$(git branch --show-current)${N}\n"
  echo
}

# ================================================================
#  PHASE 10 — Smoke test
# ================================================================
_open_root_shell() {    # _open_root_shell STAGE
  local s=$1
  local h="${STAGE_HOST[$s]}" p="${STAGE_PORT[$s]}"
  echo
  log "Открываю root-сессию на ${h}..."
  log "  Переключись на деплой-юзера: ${W}su - ${DEPLOY_USER}${N}"
  log "  Проверь ключ:                ${W}cat ~/.ssh/authorized_keys${N}"
  log "  Выход из сессии:             ${W}exit${N}"
  echo
  case "${STAGE_AUTH[$s]}" in
    key)
      ssh "${SSH_BASE_OPTS[@]}" -t -p "$p" -i "${STAGE_ROOT_KEY[$s]}" "root@${h}" || true
      ;;
    pass)
      sshpass -p "${STAGE_ROOT_PASS[$s]}" \
        ssh "${SSH_BASE_OPTS[@]}" -t -p "$p" "root@${h}" || true
      ;;
  esac
}

_fetch_docker_logs() {   # _fetch_docker_logs STAGE
  local s=$1
  local project_dir="${DEPLOY_DIR_BASE}/${REPO_NAME}"
  local compose_file="${project_dir}/docker-compose.${s}.yml"
  echo
  log "── Docker logs [${s}] ─────────────────────────────────────"

  # Последние 80 строк compose-логов (все сервисы)
  _deployer_ssh "$s" \
    "docker compose -f ${compose_file} logs --tail=80 --no-color 2>&1" 2>&1 || true

  # Упавшие / exited контейнеры с кодом выхода
  local exited
  exited=$(_deployer_ssh "$s" \
    "docker ps -a --filter status=exited --filter status=dead \
     --format 'id={{.ID}} name={{.Names}} status={{.Status}} exit={{.Exited}}' 2>/dev/null" \
    2>&1 | grep -v '^\[ssh' || true)
  if [[ -n "$exited" ]]; then
    echo
    warn "Упавшие контейнеры на [${s}]:"
    while IFS= read -r line; do printf "  %s\n" "$line"; done <<< "$exited"
  fi

  log "── конец Docker logs [${s}] ──────────────────────────────"
  echo
}

_check_domain() {   # _check_domain STAGE
  local s=$1
  local proj_dir="${DEPLOY_DIR_BASE}/${REPO_NAME}"

  # Читаем WEB_URL из .cicd/.env.<stage> (локальная копия)
  local web_url=""
  local envfile="${CICD_DIR}/.env.${s}"
  if [[ -f "$envfile" ]]; then
    web_url=$(grep '^WEB_URL=' "$envfile" 2>/dev/null \
      | cut -d= -f2- | tr -d '"' | tr -d "'" | head -1)
  fi

  if [[ -z "$web_url" ]]; then
    warn "Stage '${s}': WEB_URL не найден в ${envfile} — пропускаем проверку домена"
    return
  fi

  log "Проверяю доступность домена [${s}]: ${web_url}"

  # Проверка изнутри сервера (через SSH deployer) — надёжнее при Cloudflare
  local http_code
  http_code=$(_deployer_ssh "$s" \
    "curl -sf -o /dev/null -w '%{http_code}' --max-time 12 '${web_url}/' 2>/dev/null || echo 'NO_RESPONSE'" \
    2>&1 | tail -1 | tr -d "' ")

  if [[ "$http_code" =~ ^(200|301|302|404)$ ]]; then
    ok "Stage '${s}': Домен ${web_url} отвечает HTTP ${http_code} ✓"
  else
    warn "Stage '${s}': Домен ${web_url} НЕ отвечает (код: ${http_code})"
    echo
    printf "  ${Y}Возможные причины:${N}\n"
    printf "  1. Nginx не настроен — запусти: ${W}bash setup-nginx.sh${N}\n"
    printf "  2. Nginx не запущен — на сервере: ${W}systemctl status nginx${N}\n"
    printf "  3. Firewall блокирует порт — ${W}ufw allow <port>${N}\n"
    printf "  4. DNS домена не указывает на ${STAGE_HOST[$s]}\n"
    printf "  5. Приложение упало — проверь логи: ${W}docker compose logs bot${N}\n"
    echo
    if yn "Открыть root-сессию для диагностики nginx?" "y"; then
      _open_root_shell "$s"
    fi
  fi
}

smoke_test() {
  step "Phase 10 — Smoke test deployer SSH"

  local failed=0
  for stage in "${STAGES[@]}"; do
    log "Testing deployer@${STAGE_HOST[$stage]} ..."
    local result
    local _check_stage  # функция проверки, вызывается дважды при retry
    _check_stage() {
      local saved_id="${STAGE_CONTAINER_ID[$stage]:-}"
      local out rc

      if [[ -n "$saved_id" ]]; then
        # Проверяем конкретный контейнер по сохранённому ID
        out=$(_deployer_ssh "$stage" \
          "docker ps -q --no-trunc --filter id=${saved_id}" 2>&1)
        rc=$?
        local running_id; running_id=$(echo "$out" | tail -1 | tr -d '[:space:]')
        if [[ $rc -ne 0 ]]; then
          warn "Stage '${stage}': SSH FAILED"
          return 1
        fi
        if [[ -z "$running_id" ]]; then
          warn "Stage '${stage}': SSH ✓  |  Контейнер ${saved_id:0:12} НЕ запущен!"
          return 1
        fi
        ok "Stage '${stage}': SSH ✓  |  Контейнер ${saved_id:0:12} работает"
      else
        # Container ID ещё не сохранён — просто проверяем что хоть что-то запущено
        out=$(_deployer_ssh "$stage" "docker ps -q | wc -l" 2>&1)
        rc=$?
        local cnt; cnt=$(echo "$out" | tail -1 | tr -d '[:space:]')
        if [[ $rc -ne 0 ]]; then
          warn "Stage '${stage}': SSH FAILED"
          return 1
        fi
        if [[ "${cnt}" == "0" ]]; then
          warn "Stage '${stage}': SSH ✓  |  Running containers: 0 — приложение не запущено!"
          return 1
        fi
        ok "Stage '${stage}': SSH ✓  |  Running containers: ${cnt} (container ID ещё не сохранён)"
      fi
      return 0
    }

    if ! _check_stage; then
      failed=1
      _fetch_docker_logs "$stage"
      if yn "Открыть root-сессию на ${STAGE_HOST[$stage]} для диагностики?" "y"; then
        _open_root_shell "$stage"
        log "Повторная проверка deployer SSH для '${stage}'..."
        if _check_stage; then
          failed=0
        fi
      fi
    else
      # Контейнер работает — проверяем доступность домена
      _check_domain "$stage"
    fi
  done

  if [[ $failed -eq 1 ]]; then
    echo
    warn "Smoke test провален. После исправления запусти скрипт снова."
    exit 1
  fi
}

# ================================================================
#  PHASE 10.5 — Initial deploy via GitHub Actions
# ================================================================
initial_deploy() {
  step "Phase 10.5 — Initial deploy"

  echo
  if ! yn "Запустить первый деплой через GitHub Actions прямо сейчас?" "y"; then
    warn "Пропущено — запусти вручную: gh workflow run pipeline.yml --repo ${REPO_FULL} --ref main"
    return
  fi

  # Убеждаемся что pipeline.yml с workflow_dispatch попал на GitHub.
  # Проверяем по remote, а не по локальному файлу.
  local wf=".github/workflows/pipeline.yml"
  if [[ -f $wf ]]; then
    # Добавить триггер если его нет локально
    if ! grep -q 'workflow_dispatch' "$wf"; then
      sed -i '/pull_request:/a\  workflow_dispatch:' "$wf"
    fi
    # Пушим если есть расхождение с remote (stage + unstaged)
    gh auth setup-git
    git add "$wf"
    if ! git diff --cached --quiet -- "$wf" 2>/dev/null; then
      log "Пушим pipeline.yml с workflow_dispatch..."
      git commit -m "ci: add workflow_dispatch trigger"
      git push origin HEAD
      log "Ждём 5 сек пока GitHub зарегистрирует workflow..."
      sleep 5
    else
      # Файл чист в index, но мог не быть запушен — проверяем через API
      local remote_has
      remote_has=$(gh api "repos/${REPO_FULL}/contents/${wf}" \
        --jq '.content' 2>/dev/null \
        | base64 -d 2>/dev/null \
        | grep -c 'workflow_dispatch' || echo 0)
      if [[ "$remote_has" == "0" ]]; then
        log "Remote не имеет workflow_dispatch — форс-пушим файл..."
        git commit --allow-empty -m "ci: ensure workflow_dispatch on remote"
        git push origin HEAD
        sleep 5
      fi
    fi
  fi

  log "Запускаем pipeline..."
  local gherr
  if ! gherr=$(gh workflow run pipeline.yml --repo "$REPO_FULL" --ref main 2>&1); then
    warn "Не удалось запустить workflow:"
    warn "  ${gherr}"
    warn "Запусти вручную: gh workflow run pipeline.yml --repo ${REPO_FULL} --ref main"
    return
  fi

  # Дать GitHub секунду зарегистрировать запуск
  sleep 4

  local run_id
  run_id=$(gh run list \
    --repo "$REPO_FULL" \
    --workflow pipeline.yml \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId' 2>/dev/null || echo "")

  if [[ -z "$run_id" ]]; then
    warn "Не удалось получить ID запуска. Следи сам:"
    warn "  https://github.com/${REPO_FULL}/actions"
    return
  fi

  log "Run ID: ${run_id} — ждём завершения (Ctrl+C чтобы отпустить)..."
  if gh run watch "$run_id" --repo "$REPO_FULL" --exit-status; then
    ok "Pipeline успешно выполнен!"
    fetch_container_ids
    save_config
  else
    warn "Pipeline завершился с ошибкой — проверь: https://github.com/${REPO_FULL}/actions/runs/${run_id}"
  fi
}

# ================================================================
#  Получить и сохранить container ID бота для каждого stage
# ================================================================
fetch_container_ids() {
  log "Получаем container ID запущенных контейнеров..."
  for stage in "${STAGES[@]}"; do
    local project_dir="${DEPLOY_DIR_BASE}/${REPO_NAME}"
    local compose_file="${project_dir}/docker-compose.${stage}.yml"
    local cid
    cid=$(_deployer_ssh "$stage" \
      "docker compose -f ${compose_file} ps -q bot 2>/dev/null | head -1" 2>&1 \
      | tail -1 | tr -d '[:space:]')
    if [[ -n "$cid" ]]; then
      STAGE_CONTAINER_ID[$stage]="$cid"
      ok "Stage '${stage}': container ID сохранён — ${cid:0:12}"
    else
      warn "Stage '${stage}': не удалось получить container ID"
    fi
  done
}

# ================================================================
#  PHASE 11 — Summary
# ================================================================
print_summary() {
  step "Done"

  printf "${W}Repository:${N}  https://github.com/%s\n" "${REPO_FULL}"
  printf "${W}Actions:${N}     https://github.com/%s/actions\n" "${REPO_FULL}"
  printf "${W}Packages:${N}    https://github.com/%s?tab=packages\n" "${REPO_OWNER}"
  printf "${W}Envs:${N}        https://github.com/%s/settings/environments\n" "${REPO_FULL}"
  echo

  printf "${W}%-12s  %-22s  %-6s  %-35s${N}\n" \
    "STAGE" "HOST" "PORT" "DEPLOY DIR"
  printf "%-12s  %-22s  %-6s  %-35s\n" \
    "──────────" "────────────────────" "────" "─────────────────────────────────"
  for stage in "${STAGES[@]}"; do
    printf "%-12s  %-22s  %-6s  %-35s\n" \
      "$stage" "${STAGE_HOST[$stage]}" "${STAGE_PORT[$stage]}" \
      "${DEPLOY_DIR_BASE}/${REPO_NAME}"
  done

  echo
  printf "${W}Database modes:${N}\n"
  for stage in "${STAGES[@]}"; do
    printf "  %-12s mode=%-9s host=%s db=%s user=%s%s\n" \
      "$stage" \
      "${STAGE_DB_MODE[$stage]:-host}" \
      "${STAGE_DB_HOST[$stage]:-}" \
      "${STAGE_DB_NAME[$stage]:-}" \
      "${STAGE_DB_USER[$stage]:-}" \
      "$( [[ "${STAGE_IS_LOCAL[$stage]:-false}" == "true" ]] && printf ' [local stage host]' )"
  done

  echo
  printf "${W}GitHub Secrets set:${N}\n"
  echo "  GHCR_TOKEN"
  for stage in "${STAGES[@]}"; do
    local U; U=$(echo "$stage" | tr '[:lower:]' '[:upper:]')
    echo "  SSH_HOST_${U}, SSH_PRIVATE_KEY_${U}"
  done
  if $TG_NOTIFICATIONS; then
    echo "  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID"
  fi

  echo
  echo -e "${W}Next steps:${N}"
  echo "  1. Push to main → pipeline triggers automatically"
  echo "  2. Monitor:  gh run list --repo ${REPO_FULL}"
  echo "  3. Prod protection rules (manual approval gate):"
  echo "     https://github.com/${REPO_FULL}/settings/environments"
  echo
  printf "${G}${W}CI/CD setup complete!${N}\n"
  echo
  printf "${W}Важно: SSH deploy-ключи хранятся в ~/.ssh/${N}\n"
  for stage in "${STAGES[@]}"; do
    printf "  ${C}%s${N}\n" "$(deploy_key "$stage")"
  done
  printf "  Не удаляй их — они нужны для подключения к серверам.\n"
}

# ================================================================
#  MAIN
# ================================================================
main() {
  # CICD_DIR известен как константа — пишем сразу в финальный путь, без mv
  # (mv на NTFS/WSL ломает открытый fd tee)
  mkdir -p "$CICD_DIR"
  local _log_ts; _log_ts=$(date '+%Y%m%d_%H%M%S')
  local LOG_FILE="${CICD_DIR}/setup_${_log_ts}.log"
  exec > >(tee -a "$LOG_FILE") 2>&1

  printf "${W}${C}"
  printf "╔═══════════════════════════════════════════════════════╗\n"
  printf "║    CI/CD Universal Setup  v%-28s║\n" "${SCRIPT_VERSION}                    "
  printf "║    GitHub Actions · Docker · GHCR · SSH deploy       ║\n"
  printf "╚═══════════════════════════════════════════════════════╝\n"
  printf "${N}\n"
  log "Лог сессии: ${LOG_FILE}"

  check_prereqs
  detect_repo   # устанавливает CONFIG_FILE

  # Загружаем или начинаем новую настройку
  if ! init_config; then
    configure_stages
    mark_phase_done "3"
    save_config
  fi

  for stage in "${STAGES[@]}"; do

    if ! phase_done "4_${stage}"; then
      provision_server "$stage"
      mark_phase_done "4_${stage}"
      save_config
    else
      ok "Phase 4 (${stage}): уже выполнена — пропускаем"
    fi

    if ! phase_done "45_${stage}"; then
      bootstrap_stage_database "$stage"
      mark_phase_done "45_${stage}"
      save_config
    else
      ok "Phase 4.5 (${stage}): уже выполнена — пропускаем"
    fi

    if ! phase_done "5_${stage}"; then
      collect_env "$stage"
      mark_phase_done "5_${stage}"
      save_config
    else
      ok "Phase 5 (${stage}): уже выполнена — пропускаем"
    fi

    if ! phase_done "6_${stage}"; then
      generate_compose "$stage"
      mark_phase_done "6_${stage}"
      save_config
    else
      ok "Phase 6 (${stage}): уже выполнена — пропускаем"
    fi

    if ! phase_done "65_${stage}"; then
      setup_nginx_stage "$stage"
      mark_phase_done "65_${stage}"
      save_config
    else
      ok "Phase 6.5 (${stage}): уже выполнена — пропускаем"
    fi

  done

  if ! phase_done "7"; then
    generate_workflow
    mark_phase_done "7"
    save_config
  else
    ok "Phase 7: уже выполнена — пропускаем"
  fi

  if ! phase_done "75"; then
    setup_telegram_notifications
    mark_phase_done "75"
    save_config
    # Если TG настроен — перегенерируем workflow с notify-job
    if $TG_NOTIFICATIONS; then
      log "Перегенерирую workflow с Telegram notify-job..."
      generate_workflow
    fi
  else
    ok "Phase 7.5: уже выполнена — пропускаем"
  fi

  if ! phase_done "8"; then
    setup_github
    mark_phase_done "8"
    save_config
  else
    ok "Phase 8: уже выполнена — пропускаем"
  fi

  if ! phase_done "9"; then
    commit_and_push
    mark_phase_done "9"
    save_config
  else
    ok "Phase 9: уже выполнена — пропускаем"
  fi

  smoke_test       # всегда
  initial_deploy   # всегда (с вопросом)
  print_summary    # всегда
}

main "$@"
