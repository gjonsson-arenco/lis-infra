#!/usr/bin/env bash
#
# Sube al server las variables de geolocalización del domicilio del paciente
# (Amazon Location) a los dos .env.prod que las leen: el del backend
# (resuelve el place_id) y el del front (autocompletado y mapa). Cada
# variable se reemplaza si ya está o se agrega al final; el resto del
# archivo no se toca y queda un .bak al lado.
#
# ESTE SCRIPT SE CORRE DESDE TU MÁQUINA. Los valores salen de tus .env
# locales (lis-backend/.env y apps/lis/.env.local) salvo que los pises por
# variable de entorno. Las keys nunca viajan en la línea de comando: van por
# stdin del ssh, así no quedan en `ps` ni en el history del server.
#
# Uso:
#   ./scripts/push-geo-env.sh usuario@ip-del-server
#
# Para desdoblar las keys (recomendado en prod: la de browser restringida por
# referrer, la de servidor sin referrer y sólo con GetPlace):
#   GEO_SERVER_KEY=v1.public.... GEO_BROWSER_KEY=v1.public.... \
#     ./scripts/push-geo-env.sh usuario@ip-del-server
#
# Otras variables que se pueden pisar: GEO_AWS_REGION, GEO_BIAS_LAT,
# GEO_BIAS_LNG (coordenadas del laboratorio, sesgan las sugerencias).
#
# Después hay que reconstruir el front: las NEXT_PUBLIC_* se inlinean en
# build-time. ./scripts/redeploy.sh lo hace solo si el repo del front cambió;
# si no, en el server:
#   set -a && source /opt/lis/lis-front-monorepo/apps/lis/.env.prod && set +a
#   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build frontend
# El backend lee su .env.prod al arrancar: alcanza con `up -d backend`.

set -euo pipefail

# Git Bash reescribe rutas tipo /opt/lis/... al pasarlas a ssh y las convierte
# en C:/Program Files/Git/opt/lis/... (ver guía de deploy §8).
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER="${1:-${LIS_SERVER:-}}"
LOCAL_BACKEND_ENV="$SCRIPT_DIR/../../lis-backend/.env"
LOCAL_FRONT_ENV="$SCRIPT_DIR/../../lis-front-monorepo/apps/lis/.env.local"

REMOTE_BACKEND_ENV="/opt/lis/lis-backend/.env.prod"
REMOTE_FRONT_ENV="/opt/lis/lis-front-monorepo/apps/lis/.env.prod"

if [ -z "$SERVER" ]; then
  echo "Uso: $0 usuario@ip-del-server" >&2
  exit 2
fi

# Último valor de KEY en un .env local, sin CR ni comillas. Vacío si no está.
read_local() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//'
}

SERVER_KEY="${GEO_SERVER_KEY:-$(read_local "$LOCAL_BACKEND_ENV" AWS_LOCATION_KEY)}"
BROWSER_KEY="${GEO_BROWSER_KEY:-$(read_local "$LOCAL_FRONT_ENV" NEXT_PUBLIC_AWS_LOCATION_KEY)}"
REGION="${GEO_AWS_REGION:-$(read_local "$LOCAL_BACKEND_ENV" AWS_LOCATION_REGION)}"
REGION="${REGION:-sa-east-1}"
BIAS_LAT="${GEO_BIAS_LAT:-$(read_local "$LOCAL_FRONT_ENV" NEXT_PUBLIC_GEO_BIAS_LAT)}"
BIAS_LNG="${GEO_BIAS_LNG:-$(read_local "$LOCAL_FRONT_ENV" NEXT_PUBLIC_GEO_BIAS_LNG)}"

if [ -z "$SERVER_KEY" ] || [ -z "$BROWSER_KEY" ]; then
  echo "ERROR: falta la key de Amazon Location." >&2
  echo "       Backend: AWS_LOCATION_KEY en $LOCAL_BACKEND_ENV (o GEO_SERVER_KEY)" >&2
  echo "       Front:   NEXT_PUBLIC_AWS_LOCATION_KEY en $LOCAL_FRONT_ENV (o GEO_BROWSER_KEY)" >&2
  exit 1
fi

for key in "$SERVER_KEY" "$BROWSER_KEY"; do
  case "$key" in
    v1.public.*) ;;
    *) echo "ERROR: eso no parece una API key de Amazon Location (empiezan con v1.public.)." >&2; exit 1 ;;
  esac
done

redact() { printf '%s…' "${1:0:18}"; }

echo "Server:   $SERVER"
echo "Región:   $REGION"
echo "Backend:  $REMOTE_BACKEND_ENV"
echo "          GEO_PROVIDER=aws  AWS_LOCATION_KEY=$(redact "$SERVER_KEY")"
echo "Front:    $REMOTE_FRONT_ENV"
echo "          NEXT_PUBLIC_GEO_PROVIDER=aws  NEXT_PUBLIC_AWS_LOCATION_KEY=$(redact "$BROWSER_KEY")"
if [ -n "$BIAS_LAT" ] && [ -n "$BIAS_LNG" ]; then
  echo "          NEXT_PUBLIC_GEO_BIAS_LAT=$BIAS_LAT  NEXT_PUBLIC_GEO_BIAS_LNG=$BIAS_LNG"
else
  echo "          (sin BIAS_LAT/LNG: se dejan los que haya o el default de Buenos Aires)"
fi
if [ "$SERVER_KEY" = "$BROWSER_KEY" ]; then
  echo
  echo "AVISO: backend y front van con la MISMA key. En prod conviene desdoblarla"
  echo "       (GEO_SERVER_KEY / GEO_BROWSER_KEY): la de browser queda expuesta en el"
  echo "       HTML y debería estar restringida por referrer, cosa que al backend no le sirve."
fi
echo
read -r -p "¿Aplicar en el server? [s/N] " answer
case "$answer" in
  s|S|si|SI|sí) ;;
  *) echo "Cancelado."; exit 0 ;;
esac

# Una línea por asignación: archivo<TAB>clave<TAB>valor, en base64 para que
# nada de esto pase por el parser de ssh ni del shell remoto.
assignments=$(
  printf '%s\t%s\t%s\n' \
    "$REMOTE_BACKEND_ENV" GEO_PROVIDER aws \
    "$REMOTE_BACKEND_ENV" AWS_LOCATION_KEY "$SERVER_KEY" \
    "$REMOTE_BACKEND_ENV" AWS_LOCATION_REGION "$REGION" \
    "$REMOTE_FRONT_ENV" NEXT_PUBLIC_GEO_PROVIDER aws \
    "$REMOTE_FRONT_ENV" NEXT_PUBLIC_AWS_LOCATION_KEY "$BROWSER_KEY" \
    "$REMOTE_FRONT_ENV" NEXT_PUBLIC_AWS_LOCATION_REGION "$REGION"
  if [ -n "$BIAS_LAT" ] && [ -n "$BIAS_LNG" ]; then
    printf '%s\t%s\t%s\n' \
      "$REMOTE_FRONT_ENV" NEXT_PUBLIC_GEO_BIAS_LAT "$BIAS_LAT" \
      "$REMOTE_FRONT_ENV" NEXT_PUBLIC_GEO_BIAS_LNG "$BIAS_LNG"
  fi
)
payload=$(printf '%s\n' "$assignments" | base64 | tr -d '\n')

echo
echo "==> Aplicando"
{
  printf "PAYLOAD='%s'\n" "$payload"
  cat <<'REMOTE'
set -euo pipefail

stamp=$(date +%Y%m%d-%H%M%S)
declare -A backed_up=()

upsert() {
  local file="$1" key="$2" value="$3"
  if [ ! -f "$file" ]; then
    echo "ERROR: no existe $file en el server" >&2
    exit 1
  fi
  if [ -z "${backed_up[$file]:-}" ]; then
    cp -p "$file" "$file.bak.$stamp"
    backed_up[$file]=1
  fi
  # ENVIRON y no -v: -v procesa escapes y una key podría traer alguno.
  if grep -qE "^${key}=" "$file"; then
    K="$key" V="$value" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
      index($0, k "=") == 1 { print k "=" v; next } { print }' "$file" > "$file.tmp"
  else
    cp "$file" "$file.tmp"
    # Que la línea nueva no se pegue a una última línea sin salto.
    [ -z "$(tail -c1 "$file.tmp")" ] || printf '\n' >> "$file.tmp"
    K="$key" V="$value" awk 'BEGIN { print ENVIRON["K"] "=" ENVIRON["V"] }' >> "$file.tmp"
  fi
  # cat y no mv: conserva owner y permisos del .env.prod.
  cat "$file.tmp" > "$file" && rm -f "$file.tmp"
}

while IFS=$'\t' read -r file key value; do
  [ -n "$file" ] || continue
  upsert "$file" "$key" "$value"
done < <(printf '%s' "$PAYLOAD" | base64 -d)

echo
for file in $(printf '%s' "$PAYLOAD" | base64 -d | cut -f1 | sort -u); do
  echo "--- $file (backup: $file.bak.$stamp)"
  grep -E '^(GEO_|AWS_LOCATION_|NEXT_PUBLIC_GEO_|NEXT_PUBLIC_AWS_LOCATION_)' "$file" \
    | sed -E 's/(_KEY=v1\.public\.[A-Za-z0-9]{8}).*/\1…/'
done
REMOTE
} | ssh "$SERVER" bash -s

echo
echo "Listo. Ahora en el server:"
echo "  - backend: docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d backend"
echo "  - front:   set -a && source $REMOTE_FRONT_ENV && set +a"
echo "             docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build frontend"
echo "  (o ./scripts/redeploy.sh, que hace las dos cosas si además hay commits nuevos)"
