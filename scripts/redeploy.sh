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
  [lis-rules-engine]=rules-engine
  [lis-chat-service]=chat-service
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

  # Un repo que todavía no se clonó (típico al sumar un servicio nuevo al
  # stack) hace fallar a `git -C` con un error críptico y, bajo `set -e`,
  # aborta el redeploy entero sin decir qué falta. Cortamos acá con el path
  # exacto: además el compose lo necesita como build context, así que sin el
  # clone no hay nada que hacer.
  if [ ! -d "$dir/.git" ]; then
    echo "ERROR: falta clonar el repo en $dir (build context del compose)." >&2
    echo "       Cloná ahí el repo del servicio y volvé a correr este script." >&2
    exit 1
  fi

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
  echo "No hay servicios con código nuevo — no se reconstruye ninguna imagen."
else
  echo "==> Reconstruyendo imágenes: ${changed_services[*]}"

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
  $COMPOSE build "${changed_services[@]}"
fi

if [ "$infra_changed" = true ] || [ ${#changed_services[@]} -gt 0 ]; then
  # `up -d` sobre TODO el stack, no solo sobre los servicios que cambiaron:
  # Compose recrea únicamente lo que difiere (imagen nueva, env/puertos/
  # depends_on nuevos en el compose) y deja el resto corriendo. Limitarlo a los
  # servicios con código nuevo dejaba afuera dos casos reales:
  #
  #  - Servicio NUEVO en el compose cuyo repo ya estaba clonado y sin commits
  #    nuevos: nunca se creaba el contenedor, y nginx quedaba con un upstream
  #    que no resuelve -> 502 en todo lo que dependa de él.
  #  - Cambio de compose sin cambio de código (variables de entorno nuevas,
  #    puertos): `restart` no las aplica, hay que recrear el contenedor.
  #
  # Las imágenes ya se buildearon arriba; acá `up -d` solo buildea si falta
  # alguna imagen (primer deploy de un servicio nuevo).
  echo "==> Aplicando el compose al stack completo"
  $COMPOSE up -d

  if [[ " ${changed_services[*]} " == *" backend "* ]]; then
    echo "==> Backend cambió — corriendo migrations"
    $COMPOSE exec backend php artisan migrate --force
  fi

  # La base del chat (`lis_chat`) es propia y no la crea nadie solo: el init de
  # MySQL solo corre con el datadir vacío. Va DESPUÉS del `up -d` porque recién
  # ahí Compose garantizó que mysql está healthy — antes, el `exec` del script
  # fallaría en un server recién levantado. Si el contenedor del chat arrancó un
  # instante antes de que la base existiera quedó reiniciándose, así que el
  # restart lo pone al día sin esperar el backoff.
  if "$INFRA_DIR/scripts/create-chat-db.sh"; then
    $COMPOSE restart chat-service
  else
    echo "ADVERTENCIA: no se pudo asegurar la base del chat — chat-service va a" >&2
    echo "             quedar reiniciándose. El resto del stack sigue arriba." >&2
  fi

  # `restart` (no `up -d`): un contenedor bind-mounteado no se recrea solo
  # porque cambió el contenido del archivo montado, así que `up -d` no
  # alcanza para releer nginx.conf/backend-proxy.conf. `restart` reinicia
  # el proceso in-place, que relee tanto el archivo montado como el DNS de
  # los upstreams — soluciona los dos problemas de una.
  echo "==> Reiniciando nginx/backend-proxy (upstreams recreados y/o config nueva)"
  $COMPOSE restart nginx backend-proxy

  # El catálogo de reglas de facturación vive en el backend (MySQL) y el
  # rules-engine lo cachea en memoria: solo lo carga en el warmup de arranque o
  # cuando alguien le pega a /billing/reload. Dos motivos para forzarlo acá:
  #
  #  1. Si el engine arrancó antes de que el backend pudiera servir el catálogo
  #     (migrations a medio correr, por ejemplo), el warmup reintenta 12 veces
  #     cada 5s y después se rinde: la cache queda vacía y TODA valorización
  #     devuelve 500, porque el backend llama al engine sin fallback.
  #  2. Si el deploy trajo reglas nuevas por migration/seed, la cache vieja
  #     sigue sirviendo hasta que alguien la refresque.
  #
  # No aborta el deploy si falla: el resto del stack ya está arriba.
  "$INFRA_DIR/scripts/reload-rules-cache.sh" || true
fi

echo "==> Estado final"
$COMPOSE ps
