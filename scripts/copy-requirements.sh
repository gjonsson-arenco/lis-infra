#!/usr/bin/env bash
#
# Copia al server los PDF de indicaciones (los "printables" de los requisitos de
# estudio) y los mete adentro del contenedor del backend.
#
# Por qué hace falta un script: esos PDF NO están en el repo (viven bajo
# storage/, que está gitignoreado), así que ni el clone ni el build de la imagen
# los traen. Y no alcanza con copiarlos a /opt/lis/lis-backend/storage en el
# host: el compose monta ahí un volumen de Docker (backend-storage), o sea que
# lo que se ve dentro del contenedor no es el directorio del repo. Por eso el
# último salto es un `docker cp` al contenedor, no un cp en el host.
#
# Destino final: /var/www/storage/app/private/requirements/ dentro del
# contenedor = disk `local` de Laravel (storage/app/private) + la carpeta
# `requirements` que usa CebacRequirementCatalogSeeder. Si DOCUMENTS_DISK deja
# de ser `local`, este destino cambia.
#
# ESTE SCRIPT SE CORRE DESDE TU MÁQUINA (es la que tiene los PDF), no en el
# server. Necesita ssh y scp (o rsync si lo tenés).
#
# Uso:
#   ./scripts/copy-requirements.sh usuario@ip-del-server
#   ./scripts/copy-requirements.sh usuario@ip-del-server /ruta/a/los/pdf
#
# Después de copiar no hace falta re-seedear: los requisitos ya guardan la ruta
# del archivo, solo faltaba el archivo. Si el catálogo todavía no se importó,
# correr en el server ./scripts/seed-cebac.sh.

set -euo pipefail

# Git Bash reescribe rutas tipo /var/www/... al pasarlas a ssh/docker y las
# convierte en C:/Program Files/Git/var/www/... (ver guía de deploy §8).
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER="${1:-${LIS_SERVER:-}}"
SRC_DIR="${2:-$SCRIPT_DIR/../../lis-backend/storage/app/private/requirements}"

CONTAINER="lis-backend"
DEST="/var/www/storage/app/private/requirements"
STAGING="/tmp/lis-requirements-upload"

if [ -z "$SERVER" ]; then
  echo "Uso: $0 usuario@ip-del-server [/ruta/local/a/los/pdf]" >&2
  exit 2
fi

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: no existe el directorio de origen: $SRC_DIR" >&2
  exit 1
fi

local_count=$(find "$SRC_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')

if [ "$local_count" -eq 0 ]; then
  echo "ERROR: no hay archivos en $SRC_DIR" >&2
  exit 1
fi

echo "Origen:  $SRC_DIR ($local_count archivos)"
echo "Server:  $SERVER"
echo "Destino: $CONTAINER:$DEST"
echo

# 1) A un staging en el server. rsync si está (transfiere solo lo que cambió),
#    scp si no — Git Bash en Windows no suele traer rsync.
echo "==> Subiendo a $SERVER:$STAGING"
ssh "$SERVER" "mkdir -p '$STAGING'"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --info=progress2 "$SRC_DIR/" "$SERVER:$STAGING/"
else
  echo "    (rsync no está, usando scp)"
  scp -q -r "$SRC_DIR/." "$SERVER:$STAGING/"
fi

# 2) Del staging al volumen del contenedor. Se usa `docker cp` con el nombre de
#    contenedor (fijado con container_name en el compose) en vez de
#    `docker compose cp`, para no depender del cwd ni de la versión de compose.
#    El contenedor corre como www-data, así que el chown va con -u root.
echo "==> Copiando adentro del contenedor"
ssh "$SERVER" "
  set -e
  docker exec -u root '$CONTAINER' mkdir -p '$DEST'
  docker cp '$STAGING/.' '$CONTAINER:$DEST'
  docker exec -u root '$CONTAINER' chown -R www-data:www-data '$DEST'
  rm -rf '$STAGING'
  echo -n '    archivos en el contenedor: '
  docker exec '$CONTAINER' sh -c 'ls -1 \"$DEST\" | wc -l'
"

echo "==> Listo (locales: $local_count)"
echo "    Si los números no coinciden, revisá nombres con caracteres raros."
