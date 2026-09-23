#!/usr/bin/env bash
#
# Corre `php artisan migrate:fresh` dentro del contenedor del backend.
#
# ¡BORRA TODOS LOS DATOS! `migrate:fresh` dropea todas las tablas y vuelve a
# correr las migrations desde cero. Está pensado para preparar/rearmar una
# instancia (por ejemplo antes de reimportar los CSV legacy de CEBAC), NO para
# una base con datos reales de producción.
#
# Los usuarios se respaldan solos antes de dropear (scripts/export-users.sh) y
# los restaura CebacUsersSeeder, así que el rescate sólo se completa con
# --seed: sin él la base queda sin usuarios y el respaldo espera en
# /opt/lis/backups/cebac-users.
#
# Uso (parado en cualquier lado, se corre EN EL SERVER):
#   ./scripts/db-fresh.sh              # solo migrate:fresh, pide confirmación
#   ./scripts/db-fresh.sh --seed       # migrate:fresh + CebacSeeder
#   ./scripts/db-fresh.sh --seed --yes # sin confirmación (para automatizar)
#   ./scripts/db-fresh.sh --seed --no-export  # instancia de estreno: nada que salvar

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/lis/lis-infra}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
SEEDER_CLASS="${SEEDER_CLASS:-CebacSeeder}"
BACKUP_DIR="${BACKUP_DIR:-/opt/lis/backups/cebac-users}"
# La ruta donde CebacUsersSeeder lee el JSON, dentro del contenedor.
SNAPSHOT="/var/www/database/seeders/data/cebac-users.json"

run_seed=false
assume_yes=false
export_users=true

for arg in "$@"; do
  case "$arg" in
    --seed) run_seed=true ;;
    --yes|-y) assume_yes=true ;;
    --no-export) export_users=false ;;
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

# Lo primero, y antes de cualquier cosa destructiva: si el respaldo falla la
# base queda intacta y hay algo para revisar.
if [ "$export_users" = true ]; then
  "$INFRA_DIR/scripts/export-users.sh" || {
    echo "El respaldo de usuarios fallo: no toco la base." >&2
    echo "Si es una instancia de estreno y no hay usuarios que salvar, corre con --no-export." >&2
    exit 1
  }
else
  echo "Respaldo de usuarios salteado (--no-export): los usuarios de $db_name se pierden."
fi

echo "==> migrate:fresh"
$COMPOSE exec -T backend php artisan migrate:fresh --force

if [ "$run_seed" = true ]; then
  # El JSON vuelve al contenedor antes de seedear. Parece de más (el export lo
  # dejó ahí recién), pero no lo es si entre medio hubo un redeploy: la imagen
  # nueva no tiene nada de lo que se escribió en la vieja.
  if [ "$export_users" = true ] && [ -f "$BACKUP_DIR/cebac-users-latest.json" ]; then
    $COMPOSE cp "$BACKUP_DIR/cebac-users-latest.json" "backend:$SNAPSHOT"
  fi

  echo "==> db:seed --class=$SEEDER_CLASS"
  $COMPOSE exec -T backend php artisan db:seed --class="$SEEDER_CLASS" --force

  # Sin tinker: la imagen de prod instala con --no-dev. Se arranca el framework
  # a mano, que es lo único que hace falta para contar una tabla.
  restored=$($COMPOSE exec -T backend php -r '
    require "vendor/autoload.php";
    $app = require "bootstrap/app.php";
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    echo App\Models\User::count();
  ' | tr -dc '0-9' || true)
  echo "==> Usuarios en la base: ${restored:-?}"
elif [ "$export_users" = true ]; then
  echo "Sin --seed no corre CebacUsersSeeder: la base queda SIN usuarios."
  echo "El respaldo esta en $BACKUP_DIR/cebac-users-latest.json y se restaura al seedear."
fi

# La base quedó nueva; lo cacheado en Redis apunta a ids que ya no existen.
echo "==> Limpiando cache de la aplicación"
$COMPOSE exec -T backend php artisan cache:clear

# El rules-engine tiene el catálogo viejo en memoria: sin esto sigue evaluando
# con las reglas de antes del fresh (o con la cache vacía si nunca cargó).
"$INFRA_DIR/scripts/reload-rules-cache.sh" || true

echo "==> Listo"
