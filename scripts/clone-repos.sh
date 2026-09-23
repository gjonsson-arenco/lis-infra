#!/usr/bin/env bash
#
# Clona en $LIS_ROOT los repos del stack que todavía no estén, y deja cada uno
# en la rama que corresponde. Idempotente: lo que ya existe se reporta y no se
# toca (nunca hace pull ni checkout sobre un clon existente — de eso se encarga
# redeploy.sh).
#
# Para qué: los nombres de repo en GitHub NO coinciden siempre con el nombre de
# la carpeta que espera el compose (`lis-front-monorepo` vive en el repo
# `lis-front-end`, `lis-clinical-matcher` en `lis_clinical_matcher`, con guión
# bajo). Tenerlo escrito acá evita clonar con el nombre equivocado y que después
# el build context del compose apunte a un directorio que no existe.
#
# Uso:
#   ./scripts/clone-repos.sh
#   LIS_GIT_BASE=https://github.com/gjonsson-arenco ./scripts/clone-repos.sh
#
# Por defecto clona por SSH, que es lo que usa el server (deploy key dedicada,
# ver linux-deploy-guide.md §2). Para HTTPS, exportar LIS_GIT_BASE como arriba.
#
# IMPORTANTE: los nombres de carpeta de acá tienen que coincidir exactamente
# con los del mapa REPO_SERVICE de redeploy.sh y con los build context del
# docker-compose.prod.yml.

set -euo pipefail

LIS_ROOT="${LIS_ROOT:-/opt/lis}"
LIS_GIT_BASE="${LIS_GIT_BASE:-git@github.com:gjonsson-arenco}"

# carpeta|repo en GitHub|rama
REPOS=(
  "lis-infra|lis-infra|deploy/cebac"
  "lis-backend|lis-backend|main"
  "lis-broker-gateway|lis-broker-gateway|main"
  "lis-front-monorepo|lis-front-end|main"
  "lis-clinical-matcher|lis_clinical_matcher|main"
  "lis-rules-engine|lis-rules-engine|main"
  "lis-chat-service|lis-chat-service|main"
  "lis-orchestrator|lis-orchestrator|main"
  # Gateway de facturación electrónica ARCA (WSFEv1). Stateless: usa el Redis
  # compartido del stack (TA de WSAA, lock por punto de venta e idempotencia).
  "lis-arca-gateway|lis-arca-gateway|main"
  # Servicio de documentos (el que dibuja el ticket fiscal y los informes). El
  # repo se sigue llamando lis-reports-engine; el servicio, adentro, es
  # lis-reporting-service.
  "lis-reports-engine|lis-reports-engine|main"
  # Los adapters de proveedores van agrupados bajo lis-adapters/, un repo
  # por adapter (git clone crea la carpeta intermedia).
  "lis-adapters/lis-adapter-labcore|lis-adapter-labcore|main"
  # La Labcore API (repo api-lis-labcore) NO va en este stack: corre como
  # servicio de Windows en una máquina del cliente (ver
  # scripts/build-labcore-api-windows.ps1) y el adapter le pega por
  # LABCORE_API_URL.
)

mkdir -p "$LIS_ROOT"

cloned=()
skipped=()

for entry in "${REPOS[@]}"; do
  IFS='|' read -r dir repo branch <<< "$entry"
  target="$LIS_ROOT/$dir"

  if [ -d "$target/.git" ]; then
    current_branch=$(git -C "$target" rev-parse --abbrev-ref HEAD)
    echo "==> $dir: ya está clonado (rama actual: $current_branch)"
    if [ "$current_branch" != "$branch" ]; then
      echo "    OJO: se esperaba la rama '$branch'. No lo cambio solo — revisalo a mano." >&2
    fi
    skipped+=("$dir")
    continue
  fi

  if [ -e "$target" ]; then
    echo "ERROR: $target existe pero no es un repo git. Sacalo del medio y reintentá." >&2
    exit 1
  fi

  echo "==> $dir: clonando $repo (rama $branch)"
  git clone --branch "$branch" "$LIS_GIT_BASE/$repo.git" "$target"
  cloned+=("$dir")
done

echo
echo "==> Resumen"
echo "    clonados: ${cloned[*]:-ninguno}"
echo "    ya estaban: ${skipped[*]:-ninguno}"

if [ ${#cloned[@]} -gt 0 ]; then
  cat <<'NEXT'

Antes de levantar el stack, para cada repo recién clonado:

  1. Crear su .env.prod a mano (chmod 600) — no se versionan.
     - lis-backend/.env.prod
     - lis-broker-gateway/.env.prod
     - lis-front-monorepo/apps/lis/.env.prod
     - lis-clinical-matcher/.env.prod
     - lis-rules-engine, lis-chat-service, lis-orchestrator, lis-arca-gateway,
       lis-reports-engine y los adapters: NO necesitan .env.prod (toda su
       config sale del docker-compose.prod.yml).
       Al .env.prod del backend le van además los datos del emisor que salen
       impresos en el comprobante (BILLING_ISSUER_*): razón social, domicilio,
       ingresos brutos e inicio de actividades. El CUIT y el punto de venta NO
       van ahí — los toma del .env de lis-infra, de las mismas variables que
       usa el gateway.
       lis-arca-gateway sí necesita el certificado y la clave privada de
       ARCA en /opt/lis/secrets/arca (arca_cert.pem y arca_key.pem, chmod
       600) — se montan read-only en el contenedor; sin ellos WSAA no puede
       firmar el login y no se emite ningún comprobante.
  2. Revisar que el .env de lis-infra tenga las variables compartidas
     (ver .env.example: MYSQL_*, MYSQL_CHAT_*, LIS_CHAT_CORS_ORIGINS,
     LIS_MATCHER_INTERNAL_TOKEN, LIS_RULES_ENGINE_INTERNAL_TOKEN,
     LIS_ORCHESTRATOR_INTERNAL_TOKEN, LIS_ADAPTER_LABCORE_INTERNAL_TOKEN,
     LABCORE_API_URL y LABCORE_API_KEY — la Labcore API corre como servicio
     de Windows en una máquina del cliente, no acá; sin esas dos el adapter
     no arranca / no autentica; ARCA_CUIT y ARCA_POINT_OF_SALE, obligatorias
     para el gateway de facturación; y LIS_REPORTING_SERVICE_INTERNAL_TOKEN,
     sin la cual el servicio de documentos no arranca).
     La base del chat no hay que crearla a mano: la crea
     scripts/create-chat-db.sh, que redeploy.sh llama en cada deploy.
  3. Levantar/actualizar con: ./scripts/redeploy.sh
NEXT
fi
