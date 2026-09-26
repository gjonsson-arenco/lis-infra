#!/usr/bin/env bash
#
# Deja una Raspberry Pi andando como display del llamador (o como tótem, si
# tiene pantalla táctil): arranca sola, sin escritorio, con Chromium en modo
# kiosko abriendo la URL que da el LIS en Configuración > Sistema >
# Dispositivos.
#
# Pensado para Raspberry Pi OS Lite (Bookworm, 64 bits) recién instalado con
# Raspberry Pi Imager, con red y SSH. Se corre una vez, como root:
#
#   sudo ./install.sh --url "https://192.168.4.95:3000/display/?key=K7M4-Q2XP-HN3R"
#
# Qué hace:
#   - instala cage (un compositor Wayland mínimo: una sola app a pantalla
#     completa) y Chromium;
#   - crea el usuario `lis` que corre el navegador (sin sudo);
#   - instala como confiable el certificado del servidor del LIS. Es
#     autofirmado, y sin esto Chromium no deja guardar los videos en el
#     equipo (el Cache Storage exige HTTPS válido);
#   - arranca todo con un servicio de systemd que se reinicia solo si algo se
#     cae, y lo reinicia además todas las madrugadas;
#   - saca el blanqueo de pantalla, manda el audio (el timbre del llamado)
#     por HDMI y prende el watchdog del hardware: si la Raspberry se cuelga,
#     se reinicia sola.
#
# Se puede volver a correr: pisa la configuración con la nueva.
#
# Opciones:
#   --url URL            La URL del equipo, con su clave. Obligatoria.
#   --cert-from HOST:PORT De dónde bajar el certificado del servidor.
#                        Default: el host y puerto de la URL.
#   --rotate 0|90|180|270 Rotar la pantalla (un televisor parado). Default 0.
#   --restart-at HH:MM   Reinicio diario del navegador. `never` lo apaga.
#                        Default 04:30.
#   --audio hdmi|jack|none Por dónde sale el timbre. Default hdmi.
#   --hostname NOMBRE    Nombre de la Raspberry en la red (p. ej. display-pb).

set -euo pipefail

URL=""
CERT_FROM=""
ROTATE=0
RESTART_AT="04:30"
AUDIO="hdmi"
NEW_HOSTNAME=""
KIOSK_USER="lis"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --cert-from) CERT_FROM="$2"; shift 2 ;;
    --rotate) ROTATE="$2"; shift 2 ;;
    --restart-at) RESTART_AT="$2"; shift 2 ;;
    --audio) AUDIO="$2"; shift 2 ;;
    --hostname) NEW_HOSTNAME="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Correlo con sudo." >&2; exit 1; }
[ -n "$URL" ] || { echo "Falta --url (la URL del equipo que da el LIS, con ?key=...)." >&2; exit 2; }
case "$URL" in https://*) ;; *) echo "La URL tiene que ser https:// (el guardado de videos lo exige)." >&2; exit 2 ;; esac
case "$ROTATE" in 0|90|180|270) ;; *) echo "--rotate: 0, 90, 180 o 270." >&2; exit 2 ;; esac
case "$AUDIO" in hdmi|jack|none) ;; *) echo "--audio: hdmi, jack o none." >&2; exit 2 ;; esac

# host:puerto de la URL, para bajar el certificado.
if [ -z "$CERT_FROM" ]; then
  hostport="${URL#https://}"
  hostport="${hostport%%/*}"
  hostport="${hostport%%\?*}"
  case "$hostport" in *:*) CERT_FROM="$hostport" ;; *) CERT_FROM="$hostport:443" ;; esac
fi
CERT_HOST="${CERT_FROM%%:*}"

BOOT_DIR=/boot/firmware
[ -d "$BOOT_DIR" ] || BOOT_DIR=/boot
CMDLINE="$BOOT_DIR/cmdline.txt"

echo "==> Paquetes"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cage wlr-randr curl openssl libnss3-tools ca-certificates alsa-utils >/dev/null
# Bookworm lo llama chromium-browser; las versiones nuevas, chromium.
apt-get install -y -qq chromium-browser >/dev/null 2>&1 || apt-get install -y -qq chromium >/dev/null
CHROMIUM="$(command -v chromium-browser || command -v chromium)"
echo "    chromium: $CHROMIUM"

echo "==> Usuario $KIOSK_USER"
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$KIOSK_USER"
fi
# Pantalla, sonido, GPU y la pantalla táctil de un tótem. Sólo los grupos que
# existan: no todas las imágenes traen `render` o `input`.
for group in video audio render input; do
  if getent group "$group" >/dev/null; then
    usermod -aG "$group" "$KIOSK_USER"
  fi
done
KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"

if [ -n "$NEW_HOSTNAME" ]; then
  echo "==> Hostname $NEW_HOSTNAME"
  hostnamectl set-hostname "$NEW_HOSTNAME"
  # Se reescribe el contenido en vez de `sed -i`, que reemplaza el archivo y
  # falla si /etc/hosts está montado (contenedores).
  hosts=$(sed "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts)
  printf '%s\n' "$hosts" > /etc/hosts
  grep -q "^127\.0\.1\.1" /etc/hosts || printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
fi

echo "==> Certificado de $CERT_FROM"
CERT_FILE=/usr/local/share/ca-certificates/lis-server.crt
if ! echo | openssl s_client -connect "$CERT_FROM" -servername "$CERT_HOST" 2>/dev/null \
    | openssl x509 -outform PEM > "$CERT_FILE.tmp" || [ ! -s "$CERT_FILE.tmp" ]; then
  rm -f "$CERT_FILE.tmp"
  echo "No pude bajar el certificado de $CERT_FROM. ¿El servidor está andando y se ve desde acá?" >&2
  exit 1
fi
mv "$CERT_FILE.tmp" "$CERT_FILE"
openssl x509 -in "$CERT_FILE" -noout -subject -enddate | sed 's/^/    /'
# Para curl (la espera del arranque).
update-ca-certificates >/dev/null
# Para Chromium, que en Linux usa su propia base (NSS) por usuario.
NSSDB="$KIOSK_HOME/.pki/nssdb"
sudo -u "$KIOSK_USER" mkdir -p "$NSSDB"
if [ ! -f "$NSSDB/cert9.db" ]; then
  sudo -u "$KIOSK_USER" certutil -d "sql:$NSSDB" -N --empty-password
fi
sudo -u "$KIOSK_USER" certutil -d "sql:$NSSDB" -D -n lis-server >/dev/null 2>&1 || true
sudo -u "$KIOSK_USER" certutil -d "sql:$NSSDB" -A -t "P,," -n lis-server -i "$CERT_FILE"

echo "==> Configuración (/etc/lis-kiosk.conf)"
cat > /etc/lis-kiosk.conf <<EOF
# La edita raspberry/set-url.sh. Después de cambiarla a mano:
#   sudo systemctl restart lis-kiosk
LIS_URL="$URL"
CHROMIUM="$CHROMIUM"
# Rotación de la pantalla en grados (0, 90, 180, 270).
ROTATE=$ROTATE
EOF

echo "==> Lanzador (/usr/local/bin/lis-kiosk-browser)"
cat > /usr/local/bin/lis-kiosk-browser <<'EOF'
#!/usr/bin/env bash
# Lo arranca cage (ver lis-kiosk.service). Espera al servidor y abre Chromium.
set -u
source /etc/lis-kiosk.conf

# Un apagón prende la Raspberry antes que el servidor o que el router: se
# espera en vez de mostrar la página de error de Chromium.
until curl -s --max-time 5 -o /dev/null "$LIS_URL"; do
  echo "lis-kiosk: esperando a $LIS_URL"
  sleep 5
done

# Si Chromium se cortó (un corte de luz), arranca normal y no con el cartel
# de "restaurar pestañas".
PREFS="$HOME/.config/chromium/Default/Preferences"
if [ -f "$PREFS" ]; then
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' "$PREFS"
fi
rm -f "$HOME/.config/chromium/Singleton"*

# Un televisor parado: se rota la salida dentro de la sesión de cage.
if [ "${ROTATE:-0}" != "0" ]; then
  output=$(wlr-randr 2>/dev/null | awk 'NR==1 {print $1}')
  if [ -n "$output" ]; then
    wlr-randr --output "$output" --transform "$ROTATE" || true
  fi
fi

exec "$CHROMIUM" \
  --kiosk \
  --ozone-platform=wayland \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --disable-session-crashed-bubble \
  --disable-features=Translate,TranslateUI,MediaRouter \
  --autoplay-policy=no-user-gesture-required \
  --overscroll-history-navigation=0 \
  --disable-pinch \
  --password-store=basic \
  --check-for-update-interval=31536000 \
  "$LIS_URL"
EOF
chmod 755 /usr/local/bin/lis-kiosk-browser

echo "==> Servicio (lis-kiosk.service)"
cat > /etc/systemd/system/lis-kiosk.service <<EOF
[Unit]
Description=LIS: display del llamador / tótem (Chromium en kiosko)
After=systemd-user-sessions.service network-online.target
Wants=network-online.target
# Usa la consola 1: no puede haber un login ahí.
Conflicts=getty@tty1.service

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpMode=user
Environment=XDG_SESSION_TYPE=wayland
# -d: sin decoraciones de ventana. -s: deja cambiar de consola (Ctrl+Alt+F2)
# para entrar a mano si hace falta.
ExecStart=/usr/bin/cage -d -s -- /usr/local/bin/lis-kiosk-browser
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

if [ "$RESTART_AT" != "never" ]; then
  echo "==> Reinicio diario a las $RESTART_AT"
  cat > /etc/systemd/system/lis-kiosk-restart.service <<'EOF'
[Unit]
Description=LIS: reinicio diario del navegador del llamador

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart lis-kiosk.service
EOF
  cat > /etc/systemd/system/lis-kiosk-restart.timer <<EOF
[Unit]
Description=LIS: reinicio diario del navegador del llamador

[Timer]
OnCalendar=*-*-* $RESTART_AT:00
Persistent=false

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now lis-kiosk-restart.timer >/dev/null
else
  systemctl disable --now lis-kiosk-restart.timer >/dev/null 2>&1 || true
fi

echo "==> Pantalla: sin blanqueo"
# En la única línea de cmdline.txt. Se saca el valor viejo antes de poner el
# nuevo, así volver a correr el script no lo duplica. (La rotación no va acá:
# la aplica el lanzador dentro de cage.)
sed -i -E 's/ ?consoleblank=[0-9]+//g' "$CMDLINE"
sed -i "1 s/\$/ consoleblank=0/" "$CMDLINE"

echo "==> Audio: $AUDIO"
case "$AUDIO" in
  hdmi)
    if aplay -l 2>/dev/null | grep -q vc4hdmi0; then
      cat > /etc/asound.conf <<'EOF'
# El timbre del llamado sale por el HDMI del televisor.
pcm.!default { type plug slave.pcm "hdmi:CARD=vc4hdmi0,DEV=0" }
ctl.!default { type hw card vc4hdmi0 }
EOF
    else
      echo "    no encontré la salida HDMI (vc4hdmi0); el audio queda como estaba." >&2
    fi
    ;;
  jack)
    if aplay -l 2>/dev/null | grep -q Headphones; then
      cat > /etc/asound.conf <<'EOF'
pcm.!default { type plug slave.pcm "hw:CARD=Headphones,DEV=0" }
ctl.!default { type hw card Headphones }
EOF
    else
      echo "    esta Raspberry no tiene salida de auriculares; el audio queda como estaba." >&2
    fi
    ;;
  none)
    rm -f /etc/asound.conf
    ;;
esac

echo "==> Watchdog del hardware"
# Si el sistema entero se cuelga, el chip lo reinicia a los 15 segundos.
sed -i -E 's/^#?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=15/' /etc/systemd/system.conf
grep -q '^RuntimeWatchdogSec=' /etc/systemd/system.conf || echo 'RuntimeWatchdogSec=15' >> /etc/systemd/system.conf

echo "==> Arranque"
systemctl daemon-reload
systemctl set-default multi-user.target >/dev/null
systemctl disable getty@tty1.service >/dev/null 2>&1 || true
systemctl enable lis-kiosk.service >/dev/null

cat <<EOF

Listo. Reiniciá la Raspberry (sudo reboot): al volver abre sola
  $URL

Para cambiar la URL (p. ej. si se regeneró la clave en el LIS):
  sudo ./set-url.sh "https://..."
Para ver qué pasa:
  journalctl -u lis-kiosk -f
EOF
