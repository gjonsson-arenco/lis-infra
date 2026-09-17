#!/usr/bin/env bash
#
# Setea una o más variables en el .env de lis-infra DEL SERVER
# (/opt/lis/lis-infra/.env) sin abrir un editor por ssh ni pegar secretos en
# la línea de comando. Cada variable se reemplaza si ya está o se agrega al
# final; el resto del archivo no se toca y queda un .bak al lado.
#
# ESTE SCRIPT SE CORRE DESDE TU MÁQUINA. Los valores se piden por teclado
# (sin eco) y viajan por stdin del ssh en base64: no quedan en `ps`, ni en el
# history local, ni en el del server.
#
# Uso:
#   ./scripts/set-infra-env.sh usuario@ip-del-server LABCORE_LIS_CONNECTION_STRING
#   ./scripts/set-infra-env.sh usuario@ip-del-server LABCORE_API_KEY LABCORE_LIS_CONNECTION_STRING
#
# Un valor con `$` se escribe entre comillas simples: Compose interpola el
# .env y un `$` suelto en una contraseña se lo comería. Un valor con `$` Y
# comilla simple a la vez no se puede escribir así — cambiá la contraseña.
#
# Después, el contenedor que lee la variable hay que recrearlo (`up -d` no
# alcanza con `restart`): el script imprime el comando al final.

set -euo pipefail

# Git Bash reescribe rutas tipo /opt/lis/... al pasarlas a ssh (guía §8).
export MSYS_NO_PATHCONV=1

REMOTE_ENV="/opt/lis/lis-infra/.env"

SERVER="${1:-}"
shift || true

if [ -z "$SERVER" ] || [ $# -eq 0 ]; then
  echo "Uso: $0 usuario@ip-del-server VARIABLE [VARIABLE...]" >&2
  exit 2
fi

for key in "$@"; do
  if ! [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "ERROR: '$key' no parece un nombre de variable (MAYUSCULAS_CON_GUION_BAJO)." >&2
    exit 2
  fi
done

redact() {
  local v="$1"
  # Una cadena de conexión se muestra con la contraseña tapada; cualquier
  # otra cosa, sólo el principio.
  if [[ "$v" == *Password=* ]]; then
    printf '%s' "$v" | sed -E 's/(Password=)[^;]*/\1…/I'
  else
    printf '%s…' "${v:0:6}"
  fi
}

assignments=""
for key in "$@"; do
  read -r -s -p "$key= " value
  echo
  if [ -z "$value" ]; then
    echo "ERROR: $key vacío. Cancelado." >&2
    exit 1
  fi
  if [[ "$value" == *'$'* ]]; then
    if [[ "$value" == *"'"* ]]; then
      echo "ERROR: $key tiene \$ y comilla simple a la vez; no se puede escribir en el .env." >&2
      exit 1
    fi
    value="'$value'"
  fi
  assignments+=$(printf '%s\t%s' "$key" "$value")$'\n'
  echo "    -> $key=$(redact "$value")"
done

echo
echo "Server:  $SERVER"
echo "Archivo: $REMOTE_ENV"
read -r -p "¿Aplicar en el server? [s/N] " answer
case "$answer" in
  s|S|si|SI|sí) ;;
  *) echo "Cancelado."; exit 0 ;;
esac

payload=$(printf '%s' "$assignments" | base64 | tr -d '\n')

echo
echo "==> Aplicando"
{
  printf "PAYLOAD='%s'\nFILE='%s'\n" "$payload" "$REMOTE_ENV"
  cat <<'REMOTE'
set -euo pipefail

if [ ! -f "$FILE" ]; then
  echo "ERROR: no existe $FILE en el server" >&2
  exit 1
fi

stamp=$(date +%Y%m%d-%H%M%S)
cp -p "$FILE" "$FILE.bak.$stamp"

upsert() {
  local key="$1" value="$2"
  # ENVIRON y no -v: -v procesa escapes y un valor podría traer alguno.
  if grep -qE "^${key}=" "$FILE"; then
    K="$key" V="$value" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
      index($0, k "=") == 1 { print k "=" v; next } { print }' "$FILE" > "$FILE.tmp"
  else
    cp "$FILE" "$FILE.tmp"
    # Que la línea nueva no se pegue a una última línea sin salto.
    [ -z "$(tail -c1 "$FILE.tmp")" ] || printf '\n' >> "$FILE.tmp"
    K="$key" V="$value" awk 'BEGIN { print ENVIRON["K"] "=" ENVIRON["V"] }' >> "$FILE.tmp"
  fi
  # cat y no mv: conserva owner y permisos (600) del .env.
  cat "$FILE.tmp" > "$FILE" && rm -f "$FILE.tmp"
}

while IFS=$'\t' read -r key value; do
  [ -n "$key" ] || continue
  upsert "$key" "$value"
done < <(printf '%s' "$PAYLOAD" | base64 -d)

echo "--- $FILE (backup: $FILE.bak.$stamp)"
for key in $(printf '%s' "$PAYLOAD" | base64 -d | cut -f1); do
  grep -E "^${key}=" "$FILE" | sed -E -e 's/(Password=)[^;]*/\1…/I' -e '/Password=/!s/^([A-Z0-9_]+=.{6}).*/\1…/'
done
REMOTE
} | ssh "$SERVER" bash -s

echo
echo "Listo. Para que el contenedor tome el valor nuevo, en el server:"
echo "  cd /opt/lis/lis-infra && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d labcore-api adapter-labcore"
echo "  (o ./scripts/redeploy.sh --force, que recrea todo)"
