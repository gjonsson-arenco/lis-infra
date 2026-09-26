#!/usr/bin/env bash
#
# Cambia la URL que abre la Raspberry y reinicia el navegador. Es lo que hay
# que hacer cuando se regenera la clave del equipo en el LIS, o cuando se
# reusa la Raspberry para otro display.
#
#   sudo ./set-url.sh "https://192.168.4.95:3000/display/?key=NUEVA-CLAV-EXXX"
#
# Requiere haber corrido install.sh antes.

set -euo pipefail

URL="${1:-}"
CONF=/etc/lis-kiosk.conf

[ "$(id -u)" -eq 0 ] || { echo "Correlo con sudo." >&2; exit 1; }
[ -n "$URL" ] || { echo "Uso: sudo $0 \"https://.../display/?key=...\"" >&2; exit 2; }
[ -f "$CONF" ] || { echo "No encuentro $CONF: corré primero install.sh." >&2; exit 1; }
case "$URL" in https://*) ;; *) echo "La URL tiene que ser https://." >&2; exit 2 ;; esac

# Reemplaza la línea entera; `|` como separador porque la URL lleva `/`.
escaped=$(printf '%s' "$URL" | sed 's/[&|]/\\&/g')
sed -i "s|^LIS_URL=.*|LIS_URL=\"$escaped\"|" "$CONF"

systemctl restart lis-kiosk.service
echo "URL actualizada y navegador reiniciado:"
grep '^LIS_URL=' "$CONF"
