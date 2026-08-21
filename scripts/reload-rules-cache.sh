#!/usr/bin/env bash
#
# Fuerza el reload del catálogo de reglas de facturación en el rules-engine.
#
# Por qué existe como script aparte: el engine NO lee las reglas de la base en
# cada evaluación — se las pide al backend una vez (warmup al arrancar) y las
# cachea en memoria. Cualquier cosa que cambie la tabla `rules` por fuera del
# ABM (un seeder, un migrate:fresh, una restauración de backup) deja al engine
# evaluando con el catálogo viejo hasta que alguien lo recarga. Lo llaman
# redeploy.sh, db-fresh.sh y seed-cebac.sh.
#
# No aborta a quien lo llama si falla: devuelve != 0 y que decida el caller.
#
# Uso: ./scripts/reload-rules-cache.sh

set -uo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/lis/lis-infra}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"

cd "$INFRA_DIR"

echo "==> Recalentando catálogo de reglas de facturación"

# shellcheck disable=SC2086
if $COMPOSE exec -T rules-engine node -e "fetch('http://localhost:3010/api/v1/billing/reload',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({tenantId:process.env.TENANT_ID||'lis-default'})}).then(async (r)=>{console.log('    HTTP',r.status,await r.text());process.exit(r.ok?0:1)}).catch((e)=>{console.error('   ',e.message);process.exit(1)})"; then
  exit 0
fi

echo "    WARNING: no se pudo recalentar el catálogo de reglas." >&2
echo "    Hasta que se recargue, las valorizaciones usan el catálogo viejo (o" >&2
echo "    fallan con 500 si la cache quedó vacía). Reintentar con:" >&2
echo "    $INFRA_DIR/scripts/reload-rules-cache.sh" >&2
exit 1
