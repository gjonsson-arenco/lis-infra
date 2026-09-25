#!/usr/bin/env bash
#
# Crea (si faltan) la base de lis-messaging-service y su usuario dentro del
# MySQL del stack. Mismo molde que create-chat-db.sh.
#
# La mensajería NO comparte la base del LIS: usa una propia (`lis_messaging`),
# que es a la vez el registro de lo enviado y la cola de reintentos, en la misma
# instancia de MySQL. No la crea el contenedor de MySQL — los scripts de
# /docker-entrypoint-initdb.d solo corren cuando el datadir está vacío, y el de
# este server ya tiene la base del LIS, así que nunca volverían a correr.
#
# Solo crea la BASE y el USUARIO. Las tablas las crea el propio servicio al
# arrancar (TypeORM con DB_RUN_MIGRATIONS=true).
#
# Idempotente: `IF NOT EXISTS` en todo, y el `ALTER USER` deja la contraseña
# igual a la del .env aunque haya cambiado. redeploy.sh lo llama en cada deploy,
# así que en el flujo normal no hay que correrlo a mano.
#
# Uso (se corre EN EL SERVER):
#   ./scripts/create-messaging-db.sh

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
db_name=$(env_value MYSQL_MESSAGING_DATABASE)
db_user=$(env_value MYSQL_MESSAGING_USER)
db_pass=$(env_value MYSQL_MESSAGING_PASSWORD)

# Los defaults tienen que ser los MISMOS que los del docker-compose.prod.yml
# (${MYSQL_MESSAGING_DATABASE:-lis_messaging}, etc.): si divergen, el servicio se conecta
# a una base distinta de la que crea este script.
db_name="${db_name:-lis_messaging}"
db_user="${db_user:-lis_messaging_user}"

if [ -z "$root_pw" ]; then
  echo "ERROR: falta MYSQL_ROOT_PASSWORD en $INFRA_DIR/.env." >&2
  exit 1
fi

if [ -z "$db_pass" ]; then
  echo "ERROR: falta MYSQL_MESSAGING_PASSWORD en $INFRA_DIR/.env (ver .env.example)." >&2
  echo "       Sin eso lis-messaging-service no puede conectarse a su base." >&2
  exit 1
fi

echo "==> Asegurando la base '$db_name' y el usuario '$db_user' en lis-mysql"

# MYSQL_PWD en vez de -p<pass>: así la contraseña de root no queda visible en la
# lista de procesos del contenedor.
$COMPOSE exec -T -e MYSQL_PWD="$root_pw" mysql mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED BY '$db_pass';
ALTER USER '$db_user'@'%' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'%';
FLUSH PRIVILEGES;
SQL

echo "==> Listo"
