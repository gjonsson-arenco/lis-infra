#!/usr/bin/env bash
#
# Corre `php artisan migrate:fresh` dentro del contenedor del backend.
#
# ¡BORRA TODOS LOS DATOS! `migrate:fresh` dropea todas las tablas y vuelve a
# correr las migrations desde cero. Está pensado para preparar/rearmar una
# instancia (por ejemplo antes de reimportar los CSV legacy de CEBAC), NO para
# una base con datos reales de producción.
#
# Uso (parado en cualquier lado, se corre EN EL SERVER):
#   ./scripts/db-fresh.sh              # solo migrate:fresh, pide confirmación
#   ./scripts/db-fresh.sh --seed       # migrate:fresh + CebacSeeder
#   ./scripts/db-fresh.sh --seed --yes # sin confirmación (para automatizar)

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/lis/lis-infra}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
SEEDER_CLASS="${SEEDER_CLASS:-CebacSeeder}"

run_seed=false
assume_yes=false

for arg in "$@"; do
  case "$arg" in
    --seed) run_seed=true ;;
    --yes|-y) assume_yes=true ;;
    *) echo "Argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

cd "$INFRA_DIR"

# El nombre de la base sale del .env de infra (el mismo que le inyecta el
# compose al backend). Se lee con grep y no con `source` a propósito: un .env
# editado desde Windows arrastra CRLF y rompe el source (guía de deploy §6.5).
db_name=$(grep -E '^MYSQL_DATABASE=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' || true)
db_name="${db_name:-<desconocida>}"

echo "Server:  $(hostname)"
echo "Base:    $db_name (contenedor lis-mysql)"
echo
echo "migrate:fresh DROPEA TODAS LAS TABLAS de esa base y las vuelve a crear."
echo "Todo lo que haya cargado ahí se pierde."
echo

if [ "$assume_yes" = false ]; then
  read -r -p "Escribí el nombre de la base para confirmar: " answer
  if [ "$answer" != "$db_name" ]; then
    echo "No coincide — no toco nada." >&2
    exit 1
  fi
fi

echo "==> migrate:fresh"
$COMPOSE exec -T backend php artisan migrate:fresh --force

if [ "$run_seed" = true ]; then
  echo "==> db:seed --class=$SEEDER_CLASS"
  $COMPOSE exec -T backend php artisan db:seed --class="$SEEDER_CLASS" --force
fi

# La base quedó nueva; lo cacheado en Redis apunta a ids que ya no existen.
echo "==> Limpiando cache de la aplicación"
$COMPOSE exec -T backend php artisan cache:clear

# El rules-engine tiene el catálogo viejo en memoria: sin esto sigue evaluando
# con las reglas de antes del fresh (o con la cache vacía si nunca cargó).
"$INFRA_DIR/scripts/reload-rules-cache.sh" || true

echo "==> Listo"
