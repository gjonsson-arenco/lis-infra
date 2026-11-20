#!/bin/sh
#
# Emite y renueva el certificado TLS del LIS con Let's Encrypt, validando por
# DNS contra la zona de Route53 (desafío DNS-01). El server no necesita recibir
# conexiones desde internet: certbot escribe el TXT `_acme-challenge` en la
# zona con las credenciales IAM del contenedor, Let's Encrypt lo lee, y listo.
#
# Corre en loop: cada LIS_CERT_CHECK_SECONDS (12 h) llama a `certbot certonly`
# con --keep-until-expiring, que no hace nada si el certificado vigente cubre
# los nombres pedidos y le quedan más de 30 días; renueva si está por vencer; y
# con --expand reemite si se agregaron nombres (LIS_CERT_EXTRA_DOMAINS). Un solo
# camino para el primer arranque, la renovación y el cambio de nombres.
#
# Cada vez que obtiene un certificado corre deploy-hook.sh, que lo copia a
# /certs (el ./nginx/certs del host) como server.crt/server.key: los mismos
# archivos que hoy genera generate-self-signed-cert.sh, así nginx.conf no
# cambia. nginx detecta el archivo nuevo y se recarga solo (ver el `command`
# del servicio nginx en docker-compose.prod.yml).
#
# Si la emisión falla (DNS que no resuelve, IAM sin permiso, sin salida a
# internet), nginx sigue con el certificado que tenga en /certs — el
# autofirmado del primer deploy, o el Let's Encrypt anterior — y acá se
# reintenta en LIS_CERT_RETRY_SECONDS. Nunca se deja a nginx sin archivo.
#
# Variables (vienen del .env de lis-infra por docker-compose.prod.yml):
#   LIS_PUBLIC_HOST          nombre del LIS, p. ej. qa.cebac.ankra-lis.com
#   LIS_CERT_EXTRA_DOMAINS   nombres extra en el mismo cert, separados por coma
#   LIS_CERT_EMAIL           contacto para los avisos de vencimiento de LE
#                            (opcional; vacío = cuenta sin correo)
#   LIS_CERT_STAGING         true = servidor de pruebas de LE; el cert NO se
#                            instala en nginx (sólo valida DNS + IAM)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  usuario IAM acotado a la zona

# -f: sin globbing, que un `-d *.qa.cebac...` no se expanda contra el cwd.
set -uf

HOST="${LIS_PUBLIC_HOST:?LIS_PUBLIC_HOST sin definir en el .env}"
EMAIL="${LIS_CERT_EMAIL:-}"
EXTRA="${LIS_CERT_EXTRA_DOMAINS:-}"
STAGING="${LIS_CERT_STAGING:-false}"
CHECK_SECONDS="${LIS_CERT_CHECK_SECONDS:-43200}"
RETRY_SECONDS="${LIS_CERT_RETRY_SECONDS:-900}"

HOOK=/opt/certbot-lis/deploy-hook.sh
LIVE="/etc/letsencrypt/live/$HOST"
RENEWAL_CONF="/etc/letsencrypt/renewal/$HOST.conf"
INSTALLED=/certs/server.crt

log() { echo "[certbot-lis $(date -u +%FT%TZ)] $*"; }

# -d por cada nombre: el principal y los extra.
domain_args="-d $HOST"
for d in $(printf '%s' "$EXTRA" | tr ',' ' '); do
  domain_args="$domain_args -d $d"
done

# Sin correo, Let's Encrypt no avisa si un certificado va a vencer sin
# renovarse; la renovación automática de este loop sigue igual. Se puede
# agregar después: `certbot update_account --email ...` en el contenedor.
if [ -n "$EMAIL" ]; then
  email_args="--email $EMAIL"
else
  log "LIS_CERT_EMAIL vacío: cuenta ACME sin correo de contacto (sin avisos de vencimiento)."
  email_args="--register-unsafely-without-email"
fi

if [ "$STAGING" = "true" ]; then
  log "MODO STAGING: se emite contra el servidor de pruebas de Let's Encrypt y NO se instala en nginx."
  server_args="--staging"
  hook_args=""
else
  server_args=""
  hook_args="--deploy-hook $HOOK"

  # Una lineage emitida en staging se renovaría contra staging para siempre
  # (certbot guarda el servidor ACME en el renewal conf). Al pasar a modo
  # real se descarta y se emite de cero.
  if [ -f "$RENEWAL_CONF" ] && grep -q "acme-staging" "$RENEWAL_CONF"; then
    log "el certificado guardado es de staging: lo descarto para emitir el real"
    certbot delete --cert-name "$HOST" --non-interactive || true
  fi
fi

while :; do
  log "certonly para $HOST${EXTRA:+ + $EXTRA}"
  # shellcheck disable=SC2086
  if certbot certonly \
      --dns-route53 \
      --non-interactive --agree-tos --no-eff-email \
      $email_args \
      --cert-name "$HOST" \
      $domain_args \
      --keep-until-expiring --expand \
      $server_args $hook_args; then
    # El hook sólo corre cuando se obtuvo un certificado nuevo. Si el vigente
    # está bien pero /certs no lo tiene (primer deploy sobre el autofirmado,
    # ./nginx/certs borrado a mano), se instala igual.
    if [ "$STAGING" != "true" ] && [ -f "$LIVE/fullchain.pem" ] \
        && ! cmp -s "$LIVE/fullchain.pem" "$INSTALLED"; then
      log "nginx no tiene el certificado vigente: lo instalo"
      RENEWED_LINEAGE="$LIVE" "$HOOK"
    fi
    log "ok; próximo chequeo en ${CHECK_SECONDS}s"
    sleep "$CHECK_SECONDS"
  else
    log "falló la emisión/renovación; nginx sigue con el certificado actual. Reintento en ${RETRY_SECONDS}s" >&2
    sleep "$RETRY_SECONDS"
  fi
done
