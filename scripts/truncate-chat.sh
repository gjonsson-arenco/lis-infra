#!/usr/bin/env bash
#
# Vacía la base del chat (`lis_chat`) y su cache en Redis.
#
# Por qué existe: el chat NO se pierde en un migrate:fresh del LIS — tiene base
# propia y nadie la toca — pero queda MAL APUNTADO, que es peor que perderlo.
# Todo lo que guarda el chat identifica a la gente por el `users.id` de
# lis-backend (`messages.sender_id`, `recipient_id`, `conversation_members`,
# `conversations.participant1_id/participant2_id`, `thread_resource_links`),
# y el rescate de usuarios (export-users.sh + CebacUsersSeeder) hace upsert por
# EMAIL, sin preservar el id: en el fresh los ids se reasignan desde cero.
# Resultado, si no se vacía: una conversación privada entre los usuarios 7 y 12
# sigue en la base, pero el 7 y el 12 ahora son otras dos personas, y el
# historial aparece en la bandeja de quien no era.
#
# Las TABLAS no se dropean, se truncan: las crea el propio servicio con TypeORM
# al arrancar (DB_RUN_MIGRATIONS=true) y la tabla `migrations`, que es el
# registro de lo ya aplicado, NO se toca. Si se truncara, el próximo arranque
# intentaría recrear tablas que existen y el chat no levantaría.
#
# También se limpian las claves `lis:chat:*` de Redis, que guardan ids viejos:
#   - `:presence:<tenant>:online`, un set SIN TTL (el TTL de 12h es del set de
#     sockets por usuario, no de este), así que los ids viejos se quedarían;
#   - `:identity:<tenant>:<huella-del-token>`, la cache de identidad, TTL 300s.
# Se borran sólo por prefijo y con --scan: el Redis es COMPARTIDO con el resto
# del stack (backend, orchestrator, rules-engine). Nada de FLUSHALL acá.
#
# db-fresh.sh lo llama después del migrate:fresh. Correrlo suelto sirve para
# limpiar el chat sin tocar el LIS.
#
# Uso (se corre EN EL SERVER):
#   ./scripts/truncate-chat.sh         # pide confirmación
#   ./scripts/truncate-chat.sh --yes   # sin confirmación (para automatizar)

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/lis/lis-infra}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"

# El prefijo está hardcodeado en docker-compose.prod.yml (REDIS_KEY_PREFIX:
# lis:chat), no sale del .env: si se cambia allá, se cambia acá.
REDIS_PREFIX="lis:chat"

# Las siete tablas del chat, hijas primero. Con FOREIGN_KEY_CHECKS=0 el orden
# da igual, pero así se lee qué cuelga de qué. `migrations` queda AFUERA a
# propósito (ver el comentario de arriba).
CHAT_TABLES=(
  thread_resource_links
  message_resources
  message_reactions
  conversation_reads
  conversation_members
  messages
  conversations
)

assume_yes=false

for arg in "$@"; do
  case "$arg" in
    --yes|-y) assume_yes=true ;;
    *) echo "Argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

cd "$INFRA_DIR"

# Se lee con grep y no con `source` a propósito: un .env editado desde Windows
# arrastra CRLF y rompe el source (guía de deploy §6.5).
env_value() {
  grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' || true
}

root_pw=$(env_value MYSQL_ROOT_PASSWORD)
# El default tiene que ser el MISMO que el de docker-compose.prod.yml y el de
# create-chat-db.sh: si divergen, se vacía una base distinta de la que usa el
# servicio (o ninguna) y el chat sigue desalineado.
db_name=$(env_value MYSQL_CHAT_DATABASE)
db_name="${db_name:-lis_chat}"

if [ -z "$root_pw" ]; then
  echo "ERROR: falta MYSQL_ROOT_PASSWORD en $INFRA_DIR/.env." >&2
  exit 1
fi

echo "Base del chat: $db_name (contenedor lis-mysql)"
echo "Se borran mensajes, conversaciones, canales, hilos y reacciones."
echo "El historial del chat NO se respalda en ningún lado: no hay vuelta atrás."

if [ "$assume_yes" = false ]; then
  echo
  read -r -p "Escribí el nombre de la base del chat para confirmar: " answer
  if [ "$answer" != "$db_name" ]; then
    echo "No coincide — no toco nada." >&2
    exit 1
  fi
fi

echo "==> Vaciando las tablas del chat"

# Un solo `mysql` para todo el heredoc: FOREIGN_KEY_CHECKS es de sesión, así
# que tiene que valer para los siete TRUNCATE. Sin eso MySQL los rechaza, aun
# con las tablas vacías, por las FK que apuntan a `messages`/`conversations`.
{
  echo "SET FOREIGN_KEY_CHECKS = 0;"
  for table in "${CHAT_TABLES[@]}"; do
    echo "TRUNCATE TABLE \`$table\`;"
  done
  echo "SET FOREIGN_KEY_CHECKS = 1;"
} | $COMPOSE exec -T -e MYSQL_PWD="$root_pw" mysql mysql -uroot "$db_name"

# MYSQL_PWD en vez de -p<pass>: así la contraseña de root no queda visible en la
# lista de procesos del contenedor.
remaining=$($COMPOSE exec -T -e MYSQL_PWD="$root_pw" mysql \
  mysql -uroot -N -B -e "SELECT COUNT(*) FROM messages;" "$db_name" | tr -dc '0-9')
echo "    Mensajes en la base: ${remaining:-?}"

# Redis es best-effort: el chat funciona igual con la cache sucia (la identidad
# expira en 5 minutos y la presencia se rearma al reconectar), así que un Redis
# caído no tiene que hacer fallar el vaciado, que es lo que importaba.
echo "==> Limpiando las claves $REDIS_PREFIX:* de Redis"

keys=$($COMPOSE exec -T redis redis-cli --scan --pattern "$REDIS_PREFIX:*" 2>/dev/null | tr -d '\r' | grep -c . || true)

if [ "${keys:-0}" -eq 0 ]; then
  echo "    No había claves para borrar."
else
  # -n 200 para no armar una línea de comando gigante si quedaron muchas.
  if $COMPOSE exec -T redis sh -c \
    "redis-cli --scan --pattern '$REDIS_PREFIX:*' | xargs -n 200 redis-cli del" >/dev/null 2>&1; then
    echo "    $keys clave(s) borradas."
  else
    echo "    WARNING: no se pudieron borrar las claves de Redis." >&2
    echo "    La presencia puede mostrar usuarios que ya no existen hasta que" >&2
    echo "    se reinicie el chat-service. Reintentar con:" >&2
    echo "    $INFRA_DIR/scripts/truncate-chat.sh --yes" >&2
  fi
fi

echo "==> Listo"
