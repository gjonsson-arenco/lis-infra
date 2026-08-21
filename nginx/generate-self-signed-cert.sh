#!/usr/bin/env bash
# Generates a self-signed TLS cert for the server's IP (used as SAN — modern
# browsers reject certs that only set CN, they require subjectAltName).
#
# Usage: ./generate-self-signed-cert.sh [ip]
#   ip defaults to 192.168.4.95 (CEBAC server)
#
# Browsers will still show a "not secure" warning on first visit to each
# origin (host:port combo) until someone clicks through and accepts it, or
# the cert is installed as trusted on the client machine — that's inherent
# to self-signed certs, not something this script can avoid.

set -euo pipefail

IP="${1:-192.168.4.95}"
CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certs"
mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/server.crt" ]; then
  read -p "server.crt already exists in $CERT_DIR — overwrite? [y/N] " confirm
  [ "$confirm" = "y" ] || { echo "Aborted."; exit 1; }
fi

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.crt" \
  -days 825 \
  -subj "/CN=$IP" \
  -addext "subjectAltName=IP:$IP"

chmod 600 "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/server.crt"

echo "Generated $CERT_DIR/server.crt (valid 825 days, SAN=IP:$IP)"
