#!/usr/bin/env bash
#
# Actualiza lis-infra y los repos de servicio, reconstruye solo las
# imágenes de los que tuvieron cambios, corre las migrations si el backend
# cambió, y siempre reinicia nginx/backend-proxy al final si se recreó
# algún contenedor (el propio o cualquiera de los que proxea).
#
# Por qué "siempre": nginx/backend-proxy resuelven el hostname de sus
# upstreams (`proxy_pass http://frontend:3000`, `fastcgi_pass backend:8000`,
# etc) una sola vez al arrancar — no por request. Si Compose recrea el
# contenedor de un servicio (nueva IP en la red de Docker) pero nginx no se
# reinicia, sigue apuntando a la IP vieja y devuelve 502 aunque el servicio
# nuevo esté sano. No alcanza con "cambió la config de nginx".
#
# Uso: ./scripts/redeploy.sh
# Correrlo parado en cualquier lado — resuelve todos los paths solos.

set -euo pipefail

LIS_ROOT="/opt/lis"
INFRA_DIR="$LIS_ROOT/lis-infra"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
FRONTEND_ENV="$LIS_ROOT/lis-front-monorepo/apps/lis/.env.prod"

# repo -> nombre del servicio en docker-compose.prod.yml
declare -A REPO_SERVICE=(
  [lis-backend]=backend
  [lis-broker-gateway]=broker-gateway
  [lis-front-monorepo]=frontend
  [lis-clinical-matcher]=clinical-matcher
)

# Hace git pull --ff-only en $1. Devuelve 0 (éxito) si HEAD cambió, 1 si no
# — pensado para usarse en un `if`, así "sin cambios" nunca aborta el
# script bajo `set -e`. Si el pull falla de verdad (diverged, conflicto),
# git corta con error y el script aborta ahí, que es lo que queremos: no
# seguir con un checkout en estado incierto.
pull_repo() {
  local dir="$1"
  local name
  name=$(basename "$dir")
  echo "==> $name: git pull"

  local before after
  before=$(git -C "$dir" rev-parse HEAD)
  git -C "$dir" pull --ff-only
  after=$(git -C "$dir" rev-parse HEAD)

  if [ "$before" != "$after" ]; then
    echo "    cambios: $before -> $after"
    return 0
  fi
  echo "    sin cambios"
  return 1
}

infra_changed=false
if pull_repo "$INFRA_DIR"; then
  infra_changed=true
fi

changed_services=()
for repo in "${!REPO_SERVICE[@]}"; do
  if pull_repo "$LIS_ROOT/$repo"; then
    changed_services+=("${REPO_SERVICE[$repo]}")
  fi
done

cd "$INFRA_DIR"

if [ ${#changed_services[@]} -eq 0 ]; then
  echo "No hay servicios con código nuevo — nada para reconstruir."
else
  echo "==> Reconstruyendo: ${changed_services[*]}"

  # Las NEXT_PUBLIC_* de Next.js se inlinean en build-time, no en runtime.
  # docker compose las toma del shell que corre `--build` (ver
  # docker-compose.prod.yml build.args y linux-deploy-guide.md §6.2), asi
  # que hay que exportarlas ANTES de buildear o el build de frontend falla
  # con "Missing environment variable: NEXT_PUBLIC_...".
  if [[ " ${changed_services[*]} " == *" frontend "* ]]; then
    if [ ! -f "$FRONTEND_ENV" ]; then
      echo "ERROR: no existe $FRONTEND_ENV, no puedo buildear frontend." >&2
      exit 1
    fi
    echo "==> Exportando env de frontend para el build ($FRONTEND_ENV)"
    set -a
    # shellcheck disable=SC1090
    source "$FRONTEND_ENV"
    set +a
  fi

  # shellcheck disable=SC2086
  $COMPOSE up -d --build "${changed_services[@]}"

  if [[ " ${changed_services[*]} " == *" backend "* ]]; then
    echo "==> Backend cambió — corriendo migrations"
    $COMPOSE exec backend php artisan migrate --force
  fi
fi

if [ "$infra_changed" = true ] || [ ${#changed_services[@]} -gt 0 ]; then
  # `restart` (no `up -d`): un contenedor bind-mounteado no se recrea solo
  # porque cambió el contenido del archivo montado, así que `up -d` no
  # alcanza para releer nginx.conf/backend-proxy.conf. `restart` reinicia
  # el proceso in-place, que relee tanto el archivo montado como el DNS de
  # los upstreams — soluciona los dos problemas de una.
  echo "==> Reiniciando nginx/backend-proxy (upstreams recreados y/o config nueva)"
  $COMPOSE restart nginx backend-proxy
fi

echo "==> Estado final"
$COMPOSE ps
