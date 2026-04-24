#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-postgres-host.sh \
    --host <ssh-host> \
    --port <ssh-port> \
    --auth <key|pass> \
    --db-name <name> \
    --db-user <user> \
    --db-password <password> \
    --allowed-cidr <cidr> \
    [--key-file <path>] \
    [--root-password <password>]
EOF
}

SSH_HOST=""
SSH_PORT="22"
SSH_AUTH=""
KEY_FILE=""
ROOT_PASSWORD=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
ALLOWED_CIDR=""
LOCAL_MODE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) SSH_HOST=$2; shift 2 ;;
    --port) SSH_PORT=$2; shift 2 ;;
    --auth) SSH_AUTH=$2; shift 2 ;;
    --key-file) KEY_FILE=$2; shift 2 ;;
    --root-password) ROOT_PASSWORD=$2; shift 2 ;;
    --db-name) DB_NAME=$2; shift 2 ;;
    --db-user) DB_USER=$2; shift 2 ;;
    --db-password) DB_PASSWORD=$2; shift 2 ;;
    --allowed-cidr) ALLOWED_CIDR=$2; shift 2 ;;
    --local) LOCAL_MODE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$DB_NAME" ]] || { echo "Missing --db-name" >&2; exit 1; }
[[ -n "$DB_USER" ]] || { echo "Missing --db-user" >&2; exit 1; }
[[ -n "$DB_PASSWORD" ]] || { echo "Missing --db-password" >&2; exit 1; }
[[ -n "$ALLOWED_CIDR" ]] || { echo "Missing --allowed-cidr" >&2; exit 1; }

SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -o LogLevel=ERROR
  -p "$SSH_PORT"
)

if [[ "$LOCAL_MODE" == "true" ]]; then
  if [[ $(id -u) -eq 0 ]]; then
    SSH_CMD=(env)
  else
    SSH_CMD=(sudo -H env)
  fi
else
  [[ -n "$SSH_HOST" ]] || { echo "Missing --host" >&2; exit 1; }
  [[ -n "$SSH_AUTH" ]] || { echo "Missing --auth" >&2; exit 1; }
  case "$SSH_AUTH" in
    key)
      [[ -f "$KEY_FILE" ]] || { echo "Key file not found: $KEY_FILE" >&2; exit 1; }
      SSH_CMD=(ssh "${SSH_OPTS[@]}" -i "$KEY_FILE" "root@${SSH_HOST}")
      ;;
    pass)
      command -v sshpass >/dev/null 2>&1 || { echo "sshpass is required for password auth" >&2; exit 1; }
      SSH_CMD=(sshpass -p "$ROOT_PASSWORD" ssh "${SSH_OPTS[@]}" "root@${SSH_HOST}")
      ;;
    *)
      echo "Unknown auth mode: $SSH_AUTH" >&2
      exit 1
      ;;
  esac
fi

esc_sql() {
  printf "%s" "$1" | sed "s/'/''/g"
}

DB_NAME_SQL=$(esc_sql "$DB_NAME")
DB_USER_SQL=$(esc_sql "$DB_USER")
DB_PASSWORD_SQL=$(esc_sql "$DB_PASSWORD")
ALLOWED_CIDR_SQL=$(esc_sql "$ALLOWED_CIDR")

run_bootstrap_body() {
  cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v psql >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq postgresql postgresql-contrib
fi

systemctl enable postgresql --now

CONFIG_FILE=$(sudo -u postgres psql -Atqc "SHOW config_file")
HBA_FILE=$(sudo -u postgres psql -Atqc "SHOW hba_file")

if ! grep -Eq "^[[:space:]]*listen_addresses[[:space:]]*=" "$CONFIG_FILE"; then
  echo "listen_addresses = '*'" >> "$CONFIG_FILE"
else
  sed -i "s/^[#[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '*'/" "$CONFIG_FILE"
fi

HBA_LINE="host    ${DB_NAME_SQL}    ${DB_USER_SQL}    ${ALLOWED_CIDR_SQL}    scram-sha-256"
grep -Fqx "$HBA_LINE" "$HBA_FILE" || echo "$HBA_LINE" >> "$HBA_FILE"

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER_SQL}') THEN
    EXECUTE 'CREATE ROLE ${DB_USER_SQL} LOGIN PASSWORD ''${DB_PASSWORD_SQL}''';
  ELSE
    EXECUTE 'ALTER ROLE ${DB_USER_SQL} WITH LOGIN PASSWORD ''${DB_PASSWORD_SQL}''';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${DB_NAME_SQL} OWNER ${DB_USER_SQL}'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DB_NAME_SQL}')
\gexec
SQL

systemctl restart postgresql
sudo -u postgres psql -Atqc "SELECT current_database()" >/dev/null
echo "PostgreSQL bootstrap complete"
REMOTE
}

if [[ "$LOCAL_MODE" == "true" ]]; then
  run_bootstrap_body | "${SSH_CMD[@]}" \
    DB_NAME_SQL="$DB_NAME_SQL" \
    DB_USER_SQL="$DB_USER_SQL" \
    DB_PASSWORD_SQL="$DB_PASSWORD_SQL" \
    ALLOWED_CIDR_SQL="$ALLOWED_CIDR_SQL" \
    bash -s
else
  run_bootstrap_body | "${SSH_CMD[@]}" \
    env \
    DB_NAME_SQL="$DB_NAME_SQL" \
    DB_USER_SQL="$DB_USER_SQL" \
    DB_PASSWORD_SQL="$DB_PASSWORD_SQL" \
    ALLOWED_CIDR_SQL="$ALLOWED_CIDR_SQL" \
    bash -s
fi
