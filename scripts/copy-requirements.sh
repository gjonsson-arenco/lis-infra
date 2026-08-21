#!/usr/bin/env bash
#
# Copia al server los PDF de indicaciones (los "printables" de los requisitos de
# estudio).
#
# Por qué hace falta un script: esos PDF NO están en el repo (viven bajo
# storage/, que está gitignoreado), así que ni el clone ni el build de la imagen
# los traen — pero la app los necesita para servir la indicación al paciente.
#
# Van a un directorio del HOST, /opt/lis/storage/requirements, que el compose
# bind-montea read-only dentro del contenedor del backend en
# /var/www/storage/app/private/requirements (= disk `local` de Laravel +
# la carpeta que usa CebacRequirementCatalogSeeder). Consecuencias buenas:
# sobreviven a cualquier rebuild, a un `down -v`, se listan con `ls` y entran en
# el backup del server como cualquier otro archivo.
#
# ESTE SCRIPT SE CORRE DESDE TU MÁQUINA (es la que tiene los PDF), no en el
# server. Necesita ssh y scp (o rsync si lo tenés).
#
# Uso:
#   ./scripts/copy-requirements.sh usuario@ip-del-server
#   ./scripts/copy-requirements.sh usuario@ip-del-server /ruta/a/los/pdf
#
# Después de copiar no hace falta re-seedear ni reiniciar nada: los requisitos
# ya guardan la ruta del archivo y el bind mount es en vivo. Si el catálogo
# todavía no se importó, correr en el server ./scripts/seed-cebac.sh.

set -euo pipefail

# Git Bash reescribe rutas tipo /opt/lis/... al pasarlas a ssh y las convierte
# en C:/Program Files/Git/opt/lis/... (ver guía de deploy §8).
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER="${1:-${LIS_SERVER:-}}"
SRC_DIR="${2:-$SCRIPT_DIR/../../lis-backend/storage/app/private/requirements}"

# Tiene que coincidir con el bind mount del backend en docker-compose.prod.yml.
HOST_DIR="/opt/lis/storage/requirements"
CONTAINER="lis-backend"

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
echo "Destino: $HOST_DIR (bind-monteado en $CONTAINER)"
echo

# El directorio se crea a mano una sola vez, y con el owner del usuario de
# deploy. Si no existe cuando arranca el stack, Docker lo crea root:root y
# después esta copia falla con un permission denied bastante opaco.
echo "==> Verificando el destino"
ssh "$SERVER" "
  if [ ! -d '$HOST_DIR' ] || [ ! -w '$HOST_DIR' ]; then
    echo 'ERROR: $HOST_DIR no existe o no es escribible por este usuario.' >&2
    echo 'Crealo una sola vez con:' >&2
    echo '  sudo mkdir -p $HOST_DIR && sudo chown \$(id -un):\$(id -gn) $HOST_DIR' >&2
    exit 1
  fi
"

echo "==> Copiando"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --info=progress2 "$SRC_DIR/" "$SERVER:$HOST_DIR/"
else
  echo "    (rsync no está, usando scp)"
  scp -q -r "$SRC_DIR/." "$SERVER:$HOST_DIR/"
fi

# El contenedor corre como www-data (uid 82): necesita permiso de lectura sobre
# los archivos y de traverse sobre el directorio. `a+rX` da exactamente eso sin
# marcar los PDF como ejecutables.
echo "==> Ajustando permisos y verificando"
ssh "$SERVER" "
  set -e
  chmod -R a+rX '$HOST_DIR'
  echo -n '    archivos en el host: '
  ls -1 '$HOST_DIR' | wc -l
  if docker ps --format '{{.Names}}' | grep -qx '$CONTAINER'; then
    echo -n '    visibles en el contenedor: '
    docker exec -u www-data '$CONTAINER' sh -c 'ls -1 /var/www/storage/app/private/requirements | wc -l'
  else
    echo '    ($CONTAINER no está corriendo — se van a ver cuando levante)'
  fi
"

echo "==> Listo (locales: $local_count)"
