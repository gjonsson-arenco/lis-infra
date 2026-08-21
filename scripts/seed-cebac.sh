#!/usr/bin/env bash
#
# Corre el seeder de CEBAC dentro del contenedor del backend, sin tocar el
# schema (no dropea nada, a diferencia de db-fresh.sh).
#
# CebacSeeder es el orquestador: tenant + admins y de ahí llama a los de
# catálogos, facturación, reglas y requisitos ("indicaciones"). Los seeders son
# idempotentes (updateOrCreate por code), así que se puede correr las veces que
# haga falta. La excepción documentada es
# CebacBillingCatalogSeeder::importInsurancePricingAgreements(), que borra y
# re-crea insurance_pricing_agreements en cada corrida.
#
# Los CSV legacy que lee salen de la imagen del backend
# (database/seeders/data/cebac-legacy/), así que si cambiaron hay que
# rebuildear la imagen (./scripts/redeploy.sh), no alcanza con re-seedear.
#
# Uso (se corre EN EL SERVER):
#   ./scripts/seed-cebac.sh                          # CebacSeeder completo
#   ./scripts/seed-cebac.sh CebacRuleCatalogSeeder   # un seeder puntual

set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/opt/lis/lis-infra}"
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
SEEDER_CLASS="${1:-CebacSeeder}"

cd "$INFRA_DIR"

echo "==> db:seed --class=$SEEDER_CLASS"
$COMPOSE exec -T backend php artisan db:seed --class="$SEEDER_CLASS" --force

echo "==> Limpiando cache de la aplicación"
$COMPOSE exec -T backend php artisan cache:clear

# Si el seeder tocó la tabla `rules` (CebacRuleCatalogSeeder, o CebacSeeder que
# lo llama), el rules-engine sigue con el catálogo anterior en memoria.
"$INFRA_DIR/scripts/reload-rules-cache.sh" || true

echo "==> Listo"
