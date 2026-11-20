#!/bin/sh
#
# Lo corre certbot cada vez que obtiene un certificado (ver entrypoint.sh).
# Copia la cadena y la clave de la lineage a /certs con los nombres que lee
# nginx.conf (server.crt / server.key). nginx mira la fecha de server.crt y se
# recarga solo cuando cambia.
#
# Primero la clave y después el certificado, a propósito: nginx recarga al ver
# server.crt nuevo, y si en ese momento la clave fuera todavía la vieja, la
# recarga fallaría por "key values mismatch" (seguiría sirviendo el cert viejo
# hasta la próxima, pero mejor no).

set -eu

: "${RENEWED_LINEAGE:?certbot no pasó RENEWED_LINEAGE}"
CERTS=/certs

install -m 600 "$RENEWED_LINEAGE/privkey.pem"   "$CERTS/server.key.new"
install -m 644 "$RENEWED_LINEAGE/fullchain.pem" "$CERTS/server.crt.new"
mv -f "$CERTS/server.key.new" "$CERTS/server.key"
mv -f "$CERTS/server.crt.new" "$CERTS/server.crt"

echo "[certbot-lis] certificado instalado en $CERTS:"
openssl x509 -in "$CERTS/server.crt" -noout -subject -enddate 2>/dev/null \
  || python3 -c "
import sys
from cryptography import x509
c = x509.load_pem_x509_certificate(open('$CERTS/server.crt','rb').read())
print('  subject:', c.subject.rfc4514_string()); print('  vence:', c.not_valid_after_utc)
" 2>/dev/null || true
