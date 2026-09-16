#!/usr/bin/env bash
#
# Imprime en Markdown el borrador de notas de un release: qué commits entraron
# en cada repo entre dos tags de deploy (ver tag-release.sh), agrupados por
# categoría funcional según el scope del conventional commit, más lo que hay
# que saber para el deploy (migrations, seeders y variables nuevas).
#
# Es un BORRADOR: la sección "Novedades para el cliente" sale con los subjects
# de los feat/fix tal cual; hay que reescribirla en lenguaje de cliente antes
# de mandarla. Lo demás (tabla de hashes, notas de deploy) va como está.
#
# Corre en el server, que es donde están los tags (el push desde el server es
# best-effort, así que los repos locales pueden no tenerlos). Desde tu máquina:
#
#   ssh usuario@server 'bash -s' < scripts/release-notes.sh \
#     > releases/cebac/2026-09-16-1835.md
#
#   # release puntual y/o "anterior" explícito (por defecto: el último tag y el
#   # inmediato anterior):
#   ssh usuario@server 'bash -s -- cebac/2026-09-16-1835 cebac/2026-09-10' < scripts/release-notes.sh
#
# El archivo va en lis-infra/releases/<cliente>/<tag sin prefijo>.md, en la
# rama del cliente, y se commitea ya editado: es el registro de qué se le
# informó al cliente en cada deploy.

set -uo pipefail

LIS_ROOT="${LIS_ROOT:-/opt/lis}"
INFRA="$LIS_ROOT/lis-infra"

# lis-infra siempre está y siempre se taggea: es la referencia de qué tags
# existen. Orden lexicográfico = cronológico por el formato del nombre.
mapfile -t all_tags < <(git -C "$INFRA" tag -l 'cebac/*' | sort)

TAG="${1:-${all_tags[-1]:-}}"
if [ -z "$TAG" ]; then
  echo "ERROR: no hay ningún tag cebac/* en $INFRA. Corré tag-release.sh primero." >&2
  exit 1
fi

PREV="${2:-}"
if [ -z "$PREV" ]; then
  for t in "${all_tags[@]}"; do
    [ "$t" = "$TAG" ] && break
    PREV="$t"
  done
fi

# Nombre corto por repo para marcar de dónde sale cada línea.
short_name() {
  case "$1" in
    lis-backend) echo back ;;
    lis-front-monorepo) echo front ;;
    lis-rules-engine) echo rules ;;
    lis-clinical-matcher) echo matcher ;;
    lis-chat-service) echo chat ;;
    lis-broker-gateway) echo broker ;;
    lis-orchestrator) echo orchestrator ;;
    lis-adapters/*) echo "${1#lis-adapters/lis-adapter-}" ;;
    lis-infra) echo infra ;;
    *) echo "$1" ;;
  esac
}

# scope del commit -> categoría con la que se le habla al cliente. Un scope
# que no está acá aparece con su propio nombre, así no se pierde nada: si se
# repite, se agrega a la lista.
category() {
  case "$1" in
    medical-orders|documents) echo "Órdenes médicas" ;;
    admission|quick-admission|orders) echo "Admisión" ;;
    valuation|billing|rules|nomenclators) echo "Valorización y facturación" ;;
    patients|geo) echo "Pacientes" ;;
    sample-collection|samples) echo "Toma de muestras" ;;
    results|reports) echo "Resultados" ;;
    catalogs) echo "Catálogos" ;;
    integrations|labcore|orchestrator) echo "Integraciones" ;;
    chat) echo "Chat" ;;
    users|auth|permissions) echo "Usuarios y permisos" ;;
    matcher|person-id) echo "Lectura de recetas" ;;
    *) echo "$1" ;;
  esac
}

# Orden en que salen las categorías conocidas; las demás van después.
CATEGORY_ORDER=(
  "Órdenes médicas" "Admisión" "Valorización y facturación" "Pacientes"
  "Toma de muestras" "Resultados" "Catálogos" "Integraciones" "Chat"
  "Usuarios y permisos" "Lectura de recetas"
)

join() { local sep="$1" out="$2"; shift 2; local x; for x in "$@"; do out+="$sep$x"; done; echo "$out"; }

# type(scope)!: subject  — scope y "!" opcionales. En variable porque bash no
# banca paréntesis/corchetes literales dentro de [[ =~ ]].
CONVENTIONAL='^([a-z]+)(\(([^)]+)\))?!?: (.*)$'

table=()
client=()    # "categoría<TAB>- subject (repo)"
internal=()  # "- type(scope): subject (repo)"

while read -r gitdir; do
  repo="$(dirname "$gitdir")"
  name="${repo#"$LIS_ROOT"/}"
  short="$(short_name "$name")"

  if ! git -C "$repo" rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null; then
    table+=("| $name | — | — | sin tag \`$TAG\` |")
    continue
  fi
  to=$(git -C "$repo" rev-parse --short "refs/tags/$TAG")

  if [ -n "$PREV" ] && git -C "$repo" rev-parse -q --verify "refs/tags/$PREV^{commit}" >/dev/null; then
    from=$(git -C "$repo" rev-parse --short "refs/tags/$PREV")
    range="refs/tags/$PREV..refs/tags/$TAG"
  else
    # Repo nuevo en el stack (o primer release): no hay "desde". Se lista el
    # último commit para no inundar el borrador con todo el historial.
    from="—"
    range="refs/tags/$TAG~1..refs/tags/$TAG"
  fi

  count=$(git -C "$repo" rev-list --count "$range" 2>/dev/null || echo 0)
  table+=("| $name | $from | $to | $count |")

  while IFS= read -r subject; do
    [ -z "$subject" ] && continue
    if [[ "$subject" =~ $CONVENTIONAL ]]; then
      type="${BASH_REMATCH[1]}"; scope="${BASH_REMATCH[3]}"; text="${BASH_REMATCH[4]}"
    else
      type="other"; scope=""; text="$subject"
    fi
    # Sólo feat/fix de los servicios son novedad para el cliente; lo de infra
    # y los scopes de tooling son siempre internos, sea cual sea el tipo.
    case "$short:$type:$scope" in
      infra:*|*:*:deploy|*:*:scripts|*:*:compose|*:*:ci|*:*:docker) internal+=("- $subject ($short)") ;;
      *:feat:*|*:fix:*) client+=("$(category "${scope:-$short}")"$'\t'"- $text ($short)") ;;
      *) internal+=("- $subject ($short)") ;;
    esac
  done < <(git -C "$repo" log --reverse --format='%s' "$range" 2>/dev/null)
done < <(find "$LIS_ROOT" -maxdepth 3 -type d -name .git 2>/dev/null | sort)

# --- Notas de deploy: sólo lo que se puede sacar de git sin pensar ---------
# Devuelve el rango PREV..TAG del repo $1 si tiene los dos tags; vacío si no.
tagged_range() {
  [ -n "$PREV" ] || return 0
  git -C "$1" rev-parse -q --verify "refs/tags/$PREV^{commit}" >/dev/null || return 0
  git -C "$1" rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null || return 0
  echo "refs/tags/$PREV..refs/tags/$TAG"
}

BACKEND="$LIS_ROOT/lis-backend"
FRONT="$LIS_ROOT/lis-front-monorepo"
backend_range=$(tagged_range "$BACKEND")
front_range=$(tagged_range "$FRONT")

migrations=(); seeders=(); backend_env=(); front_env=()
if [ -n "$backend_range" ]; then
  mapfile -t migrations  < <(git -C "$BACKEND" diff --name-only --diff-filter=A "$backend_range" -- database/migrations | sed 's#.*/##; s#\.php$##')
  mapfile -t seeders     < <(git -C "$BACKEND" diff --name-only --diff-filter=A "$backend_range" -- database/seeders | sed 's#.*/##; s#\.php$##')
  mapfile -t backend_env < <(git -C "$BACKEND" diff "$backend_range" -- .env.example | grep -E '^\+[A-Z_]+=' | sed 's/^+//; s/=.*//')
fi
if [ -n "$front_range" ]; then
  mapfile -t front_env < <(git -C "$FRONT" diff "$front_range" -- apps/lis/.env.example | grep -E '^\+[A-Z_]+=' | sed 's/^+//; s/=.*//')
fi

# --- Salida -----------------------------------------------------------------
echo "# CEBAC — release \`$TAG\`"
echo
if [ -n "$PREV" ]; then
  echo "Delta \`$PREV\` → \`$TAG\`, generado con \`release-notes.sh\` el $(date +%Y-%m-%d)."
else
  echo "Primer release taggeado (sin anterior), generado con \`release-notes.sh\` el $(date +%Y-%m-%d)."
fi
echo
echo "| Repo | Anterior | Desplegado | Commits |"
echo "|---|---|---|---|"
printf '%s\n' "${table[@]}"
echo
echo "## Novedades para el cliente"
echo
echo "<!-- Borrador: subjects de los feat/fix. Reescribir para el cliente y borrar lo que no le importe. -->"

if [ ${#client[@]} -gt 0 ]; then
  # Categorías conocidas en su orden, después las que aparecieron sueltas.
  ordered=("${CATEGORY_ORDER[@]}")
  while IFS= read -r cat; do
    [ -z "$cat" ] && continue
    found=false
    for s in "${ordered[@]}"; do [ "$s" = "$cat" ] && found=true && break; done
    [ "$found" = false ] && ordered+=("$cat")
  done < <(printf '%s\n' "${client[@]}" | cut -f1 | sort -u)

  for cat in "${ordered[@]}"; do
    lines=$(printf '%s\n' "${client[@]}" | awk -F'\t' -v c="$cat" '$1==c {print $2}')
    [ -z "$lines" ] && continue
    echo
    echo "### $cat"
    echo "$lines"
  done
else
  echo
  echo "_Sin feat/fix en este release._"
fi

echo
echo "## Notas de deploy"
echo
if [ ${#migrations[@]} -gt 0 ]; then
  echo "- **Migraciones nuevas (${#migrations[@]})**:"
  printf '  - %s\n' "${migrations[@]}"
else
  echo "- Sin migraciones nuevas."
fi
[ ${#seeders[@]} -gt 0 ]     && echo "- **Seeders nuevos**: $(join ', ' "${seeders[@]}") — correrlos."
[ ${#backend_env[@]} -gt 0 ] && echo "- **Env backend nuevas** (\`.env.example\`): $(join ', ' "${backend_env[@]}")"
[ ${#front_env[@]} -gt 0 ]   && echo "- **Env front nuevas** (\`apps/lis/.env.example\`, build-time): $(join ', ' "${front_env[@]}")"
echo "- <!-- completar: pasos manuales, servicios nuevos, cosas a revisar -->"

if [ ${#internal[@]} -gt 0 ]; then
  echo
  echo "## Cambios internos"
  echo
  printf '%s\n' "${internal[@]}"
fi
