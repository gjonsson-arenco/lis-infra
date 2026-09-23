#!/usr/bin/env bash
#
# Respalda los usuarios del LIS: usuarios (con su cognito_sub), roles con sus
# permisos y módulos favoritos, al JSON que restaura CebacUsersSeeder.
#
# Es lo ÚNICO que rescata usuarios de un migrate:fresh. El resto de la base se
# regenera desde los CSV legacy que vienen en la imagen del backend, pero los
# usuarios no están en ningún export: los creó Cognito y el ABM.
#
# El JSON queda en dos lados a propósito:
#   - dentro del contenedor, en database/seeders/data/cebac-users.json, que es
#     la ruta exacta donde CebacUsersSeeder lo busca al re-seedear;
#   - en el host, fechado, porque el backend no tiene volumen sobre el código
#     (mirá docker-compose.prod.yml: sólo /var/www/storage), así que esa ruta
#     de adentro vive en la capa escribible del contenedor y el próximo
#     redeploy, que levanta una imagen nueva, se la lleva puesta.
#
# db-fresh.sh llama a este script antes de dropear. Correrlo suelto sirve para
# tener un respaldo a mano (antes de un redeploy, o simplemente cada tanto).
#
# Uso (se corre EN EL SERVER):
#   ./scripts/export-users.sh
#   BACKUP_DIR=/mnt/backups/lis ./scripts/export-users.sh

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/lis/lis-infra}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
BACKUP_DIR="${BACKUP_DIR:-/opt/lis/backups/cebac-users}"

# La ruta donde CebacUsersSeeder lee el JSON, dentro del contenedor. Está
# hardcodeada en el seeder (database_path('seeders/data/cebac-users.json')):
# si se mueve allá, se mueve acá.
SNAPSHOT="/var/www/database/seeders/data/cebac-users.json"

cd "$INFRA_DIR"

echo "==> cebac:export-users"
$COMPOSE exec -T backend php artisan cebac:export-users

# Se valida adentro, antes de copiar: un JSON trunco o sin usuarios no es un
# respaldo, y es mucho mejor enterarse ahora que después del fresh.
exported=$($COMPOSE exec -T backend php -r '
    $data = json_decode(@file_get_contents($argv[1]), true);
    if (! is_array($data) || ! isset($data["users"], $data["roles"]) || count($data["users"]) === 0) {
        fwrite(STDERR, "El export no tiene la forma que espera CebacUsersSeeder, o vino vacio.\n");
        exit(1);
    }
    echo count($data["users"]);
' -- "$SNAPSHOT")

mkdir -p "$BACKUP_DIR"
stamp=$(date +%Y%m%d-%H%M%S)
backup="$BACKUP_DIR/cebac-users-$stamp.json"

$COMPOSE cp "backend:$SNAPSHOT" "$backup"
# `latest` es por donde lo agarra db-fresh.sh para devolverlo al contenedor, y
# es el que hay que mirar cuando algo salió mal. Copia y no symlink: esto
# también se sincroniza afuera del server.
cp "$backup" "$BACKUP_DIR/cebac-users-latest.json"

echo "==> $exported usuario(s) respaldados en $backup"
