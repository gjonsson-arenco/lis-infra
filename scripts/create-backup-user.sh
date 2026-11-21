#!/usr/bin/env bash
#
# Crea (o actualiza) el usuario MySQL con el que el LIS hace los respaldos
# (Administración > Respaldos; runbook en lis-docs/infra/backups.md).
#
# Sólo lectura sobre todas las bases, que es lo que necesita mysqldump
# (--single-transaction --routines --triggers --events), y dueño de la base de
# prueba donde `backups:verify` restaura el último respaldo para comprobar que
# sirve. Nada más: si alguien se hace de estas credenciales no puede tocar la
# base de producción.
#
# Idempotente. Lee BACKUP_DB_USERNAME / BACKUP_DB_PASSWORD / BACKUP_VERIFY_DATABASE
# del .env de lis-infra (los mismos que inyecta el compose al backend) y la
# contraseña de root de MYSQL_ROOT_PASSWORD.
#
# Uso (se corre EN EL SERVER):
#   ./scripts/create-backup-user.sh

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/lis/lis-infra}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"

cd "$INFRA_DIR"

# Se lee con grep y no con `source` a propósito: un .env editado desde Windows
# arrastra CRLF y rompe el source (guía de deploy §6.5).
env_value() {
  grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' || true
}

root_pw=$(env_value MYSQL_ROOT_PASSWORD)
db_user=$(env_value BACKUP_DB_USERNAME)
db_pass=$(env_value BACKUP_DB_PASSWORD)
verify_db=$(env_value BACKUP_VERIFY_DATABASE)

db_user="${db_user:-lis_backup}"
verify_db="${verify_db:-lis_restore_check}"

if [ -z "$root_pw" ]; then
  echo "ERROR: falta MYSQL_ROOT_PASSWORD en $INFRA_DIR/.env." >&2
  exit 1
fi

if [ -z "$db_pass" ]; then
  echo "ERROR: falta BACKUP_DB_PASSWORD en $INFRA_DIR/.env (ver .env.example)." >&2
  echo "       Generá una: openssl rand -base64 24" >&2
  exit 1
fi

echo "==> Asegurando el usuario de respaldos '$db_user' en lis-mysql (base de prueba: $verify_db)"

# MYSQL_PWD en vez de -p<pass>: así la contraseña de root no queda visible en la
# lista de procesos del contenedor.
$COMPOSE exec -T -e MYSQL_PWD="$root_pw" mysql mysql -uroot <<SQL
-- mysql_native_password a propósito: el mysqldump de la imagen del backend es
-- el de MariaDB y no trae el plugin caching_sha2_password (el default de
-- MySQL 8); con el default la conexión falla con "Plugin … could not be loaded".
CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED WITH mysql_native_password BY '$db_pass';
ALTER USER '$db_user'@'%' IDENTIFIED WITH mysql_native_password BY '$db_pass';
-- Lo que pide mysqldump: SELECT + LOCK TABLES (single-transaction igual los
-- pide para los metadatos), SHOW VIEW, TRIGGER y EVENT para --routines/--triggers/--events.
GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER, EVENT ON *.* TO '$db_user'@'%';
-- La base de prueba de la verificación: se crea y se borra en cada corrida.
GRANT ALL PRIVILEGES ON \`$verify_db\`.* TO '$db_user'@'%';
FLUSH PRIVILEGES;
SQL

echo "==> Listo. Recordá recrear backend, scheduler y worker para que tomen las variables:"
echo "    $COMPOSE up -d backend scheduler worker"
