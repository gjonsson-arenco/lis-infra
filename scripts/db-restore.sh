#!/usr/bin/env bash
#
# Restaura una base desde un respaldo hecho por el LIS (Administración >
# Respaldos; runbook en lis-docs/infra/backups.md).
#
# ¡PISA LA BASE DESTINO! Dropea y recrea la base y carga el dump. Es el
# procedimiento de recuperación: cuando hace falta, el LIS está caído o a medio
# reemplazar, por eso no vive en el panel.
#
# El respaldo es una carpeta <raíz>/<año>/<fecha_hora>/ con un <base>.sql.gz
# por base, files.tar.gz y manifest.json. Las raíces en el server son
# /opt/lis/backups (copia local, pocos días) y /mnt/lis-backups (el storage de
# respaldos). Qué carpeta usar se ve en el panel (columna "Carpeta") o con ls.
#
# Uso (se corre EN EL SERVER, con el stack parado salvo mysql):
#   ./scripts/db-restore.sh <carpeta-del-respaldo> <base>            # pide confirmación
#   ./scripts/db-restore.sh <carpeta-del-respaldo> <base> --yes
#   ./scripts/db-restore.sh <carpeta-del-respaldo> <base> --into=<otra_base>
#
# Ejemplos:
#   ./scripts/db-restore.sh /mnt/lis-backups/2026/2026-11-21_020000 lis_production
#   ./scripts/db-restore.sh /opt/lis/backups/2026/2026-11-21_020000 lis_chat --into=lis_chat_prueba
#
# Los archivos (files.tar.gz) se restauran aparte, al volumen backend-storage:
#   docker run --rm -v lis-infra_backend-storage:/var/www/storage -v <carpeta>:/b:ro alpine \
#     sh -c 'cd /var/www/storage/app && tar -xzf /b/files.tar.gz'
# (el nombre real del volumen sale de `docker volume ls | grep backend-storage`).

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/lis/lis-infra}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"

if [ $# -lt 2 ]; then
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

backup_dir="$1"
database="$2"
shift 2

target="$database"
assume_yes=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) assume_yes=true ;;
    --into=*) target="${arg#--into=}" ;;
    *) echo "Argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

dump="$backup_dir/$database.sql.gz"
if [ ! -f "$dump" ]; then
  echo "ERROR: no existe $dump" >&2
  echo "Dumps en esa carpeta:" >&2
  ls -1 "$backup_dir"/*.sql.gz 2>/dev/null >&2 || echo "  (ninguno)" >&2
  exit 1
fi

cd "$INFRA_DIR"

env_value() {
  grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"' || true
}
root_pw=$(env_value MYSQL_ROOT_PASSWORD)
if [ -z "$root_pw" ]; then
  echo "ERROR: falta MYSQL_ROOT_PASSWORD en $INFRA_DIR/.env." >&2
  exit 1
fi

# El checksum del manifiesto, si está: un dump a medio copiar restaura una base
# a medias sin avisar.
if [ -f "$backup_dir/manifest.json" ] && command -v python3 >/dev/null 2>&1; then
  expected=$(python3 - "$backup_dir/manifest.json" "$database.sql.gz" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
for a in m.get("artifacts", []):
    if a.get("filename") == sys.argv[2]:
        print(a.get("sha256") or "")
PY
)
  if [ -n "$expected" ]; then
    actual=$(sha256sum "$dump" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
      echo "ERROR: el SHA-256 de $dump no coincide con el manifiesto." >&2
      echo "       esperado $expected" >&2
      echo "       real     $actual" >&2
      exit 1
    fi
    echo "Checksum OK ($actual)"
  fi
fi

echo "Server:   $(hostname)"
echo "Respaldo: $dump ($(du -h "$dump" | cut -f1))"
echo "Destino:  base '$target' en el contenedor lis-mysql"
echo
echo "Se DROPEA la base '$target' (si existe) y se carga el dump completo."
if [ "$target" = "$database" ]; then
  echo "Es la base real: parar antes backend, scheduler, worker y reverb"
  echo "($COMPOSE stop backend scheduler worker reverb)."
fi
echo

if [ "$assume_yes" = false ]; then
  read -r -p "Escribí el nombre de la base destino para confirmar: " answer
  if [ "$answer" != "$target" ]; then
    echo "No coincide — no toco nada." >&2
    exit 1
  fi
fi

echo "==> Recreando '$target'"
$COMPOSE exec -T -e MYSQL_PWD="$root_pw" mysql mysql -uroot <<SQL
DROP DATABASE IF EXISTS \`$target\`;
CREATE DATABASE \`$target\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

echo "==> Cargando el dump (puede tardar varios minutos)"
# El dump viaja descomprimido por stdin; el DEFINER de vistas/triggers se quita
# para no depender de que exista el usuario con el que se hizo el dump.
gunzip -c "$dump" \
  | sed -E 's#/\*!50017 DEFINER=`[^`]*`@`[^`]*`\*/##g; s# DEFINER=`[^`]*`@`[^`]*`##g' \
  | $COMPOSE exec -T -e MYSQL_PWD="$root_pw" mysql mysql -uroot --default-character-set=utf8mb4 "$target"

tables=$($COMPOSE exec -T -e MYSQL_PWD="$root_pw" mysql mysql -uroot -N -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$target' AND table_type='BASE TABLE'" | tr -dc '0-9')
echo "==> Listo: $tables tablas en '$target'."

if [ "$target" = "$database" ]; then
  echo
  echo "Después de restaurar la base real:"
  echo "  1. $COMPOSE up -d backend scheduler worker reverb"
  echo "  2. $COMPOSE exec -T backend php artisan migrate --force   # si el respaldo es anterior al código desplegado"
  echo "  3. $COMPOSE exec -T backend php artisan cache:clear"
  echo "  4. $INFRA_DIR/scripts/reload-rules-cache.sh"
fi
