#!/usr/bin/env bash
#
# Actualiza lis-infra y los repos de servicio, reconstruye solo las
# imágenes de los que tuvieron cambios, corre las migrations si el backend
# cambió, y siempre reinicia nginx/backend-proxy al final si se recreó
# algún contenedor (el propio o cualquiera de los que proxea). Si desplegó
# algo, cierra taggeando todos los repos con `cebac/<fecha>-<hhmm>`
# (tag-release.sh), que es de donde release-notes.sh saca el delta.
#
# Por qué "siempre": nginx/backend-proxy resuelven el hostname de sus
# upstreams (`proxy_pass http://frontend:3000`, `fastcgi_pass backend:8000`,
# etc) una sola vez al arrancar — no por request. Si Compose recrea el
# contenedor de un servicio (nueva IP en la red de Docker) pero nginx no se
# reinicia, sigue apuntando a la IP vieja y devuelve 502 aunque el servicio
# nuevo esté sano. No alcanza con "cambió la config de nginx".
#
# Uso: ./scripts/redeploy.sh [--force]
# Correrlo parado en cualquier lado — resuelve todos los paths solos.
#
# --force: reconstruir TODAS las imágenes, aplicar el compose, correr
# migrations y taggear aunque ningún repo haya traído commits nuevos. Es para
# rehacer un deploy que falló a mitad — los repos ya se pullearon, así que sin
# esto la segunda corrida ve "sin cambios" en todos y no reconstruye nada — y
# para aplicar un cambio de .env sin código nuevo.

set -euo pipefail

FORCE=false
SELF_UPDATED=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    # Interno: lo pasa el propio script al re-ejecutarse después de pullear
    # lis-infra (ver más abajo). No usarlo a mano.
    --self-updated) SELF_UPDATED=true ;;
    *) echo "Uso: $0 [--force]" >&2; exit 2 ;;
  esac
done

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
  [lis-orchestrator]=orchestrator
  [lis-adapters/lis-adapter-labcore]=adapter-labcore
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

# Si el pull de lis-infra trajo cambios, este archivo puede haber cambiado
# también, pero bash sigue ejecutando la versión que ya leyó: el mapa
# REPO_SERVICE viejo contra el compose nuevo. Así fue como una corrida
# intentó buildear labcore-api después de que el pull lo sacara del compose.
# Por eso, si infra cambió, se reemplaza el proceso por el script nuevo
# antes de tocar los demás repos; la segunda pasada ya no pullea infra.
infra_changed=false
if [ "$SELF_UPDATED" = true ]; then
  infra_changed=true
  echo "==> lis-infra: actualizado, corriendo la versión nueva del script"
elif pull_repo "$INFRA_DIR"; then
  exec bash "$INFRA_DIR/scripts/redeploy.sh" --self-updated "$@"
fi

changed_services=()
for repo in "${!REPO_SERVICE[@]}"; do
  if pull_repo "$LIS_ROOT/$repo"; then
    changed_services+=("${REPO_SERVICE[$repo]}")
  fi
done

cd "$INFRA_DIR"

# --force trata a todos los servicios como cambiados: es lo que hace falta
# cuando los repos ya se pullearon en una corrida anterior que falló. Sin
# esto, la segunda corrida ve "sin cambios" en todos, no reconstruye ninguna
# imagen, y `up -d` deja los contenedores viejos corriendo con código nuevo
# en el repo — exactamente el síntoma de "desplegué y no veo los cambios".
if [ "$FORCE" = true ]; then
  changed_services=("${REPO_SERVICE[@]}")
  echo "==> --force: se reconstruye todo el stack"
fi

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

if [ "$infra_changed" = true ] || [ ${#changed_services[@]} -gt 0 ] || [ "$FORCE" = true ]; then
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
  # `up -d` NO puede abortar el script: si un servicio nuevo no levanta (o
  # queda unhealthy y frena a los que dependen de él), Compose devuelve error
  # pero ya recreó todo lo demás — frontend y backend con IP nueva. Cortar acá
  # deja nginx apuntando a las IPs viejas (502 en todo el stack) y sin
  # migrations. Se anota el fallo, se sigue con el resto, y el script termina
  # con error y sin taggear el release.
  echo "==> Aplicando el compose al stack completo"
  deploy_failed=false
  if ! $COMPOSE up -d; then
    deploy_failed=true
    echo "ERROR: 'compose up' falló — sigo con nginx/migrations para no dejar el stack a medias." >&2
  fi

  if [[ " ${changed_services[*]} " == *" backend "* ]] || [ "$FORCE" = true ]; then
    echo "==> Corriendo migrations del backend"
    if ! $COMPOSE exec backend php artisan migrate --force; then
      deploy_failed=true
      echo "ERROR: fallaron las migrations — revisar antes de volver a correr." >&2
    fi
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

  # Foto del stack recién desplegado: el mismo tag en todos los repos, para
  # que release-notes.sh pueda decir qué entró desde el deploy anterior. Va
  # al final porque un deploy que falló a mitad no es un release: se corrige
  # y se vuelve a correr redeploy.sh, que taggea recién cuando sale todo.
  # Si el tag en sí falla (repetido, etc) el stack ya está arriba: se avisa.
  if [ "$deploy_failed" = true ]; then
    echo "==> Deploy con errores: no se taggea el release." >&2
  elif "$INFRA_DIR/scripts/tag-release.sh"; then
    echo "==> Notas del release: desde tu máquina,"
    echo "    ssh <usuario>@<server> 'bash -s' < scripts/release-notes.sh > releases/cebac/<fecha>.md"
  else
    echo "ADVERTENCIA: no se pudo taggear el release en todos los repos —" >&2
    echo "             corré scripts/tag-release.sh a mano cuando lo resuelvas." >&2
  fi
fi

echo "==> Estado final"
$COMPOSE ps

if [ "${deploy_failed:-false}" = true ]; then
  echo >&2
  echo "DEPLOY CON ERRORES (ver arriba). nginx ya fue reiniciado, así que lo que" >&2
  echo "levantó está accesible; arreglar lo que falló y correr redeploy.sh --force." >&2
  exit 1
fi
