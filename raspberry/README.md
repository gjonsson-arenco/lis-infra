# Raspberry Pi: display del llamador (y tótem)

Una Raspberry conectada a un televisor por HDMI que muestra el llamador de
turnos: los llamados en vivo, el historial y los videos de la biblioteca. No
tiene nada del LIS instalado: abre en Chromium una URL que sirve el servidor, y
un deploy del front le llega sola (se recarga cada madrugada).

Sirve igual para un **tótem** con pantalla táctil: cambia la URL (`/kiosk/` en
vez de `/display/`).

## Qué comprar

- **Raspberry Pi 5 (4 GB)**. La Pi 4 también anda, pero con video HD la 5
  va más holgada.
- Fuente oficial (27 W para la Pi 5), gabinete con ventilación.
- microSD de 32 GB clase A2, o mejor un SSD por USB: los videos se guardan en
  el equipo y una SD barata se gasta.
- Cable micro-HDMI → HDMI.
- **Red por cable** si se puede. Por Wi-Fi funciona, pero la primera bajada
  de los videos tarda más.

## Videos

- **MP4 H.264, 1080p a 30 fps, hasta ~8 Mbps**, sin audio (el display los pasa
  mudos: el único sonido de la sala es el timbre del llamado). También sirve
  WebM.
- Hacerlos 16:9. El panel del video no ocupa toda la pantalla (a la derecha va
  la lista de llamados), así que se ven con franjas negras arriba y abajo.
- Se suben en el LIS: Configuración > Sistema > **Biblioteca de medios**, y se
  eligen para cada display en **Dispositivos**. El display baja cada archivo
  una sola vez y lo pasa desde el disco: un corte de red no lo frena.

## Instalación

1. Con **Raspberry Pi Imager** grabar **Raspberry Pi OS Lite (64-bit)**. En
   la configuración del Imager: usuario y contraseña, red (si va por Wi-Fi) y
   **SSH habilitado**. Conviene ponerle un nombre, p. ej. `display-pb`.
2. En el LIS, Configuración > Sistema > **Dispositivos** > Nuevo dispositivo:
   tipo *Display del llamador*, sede, filas que anuncia y videos. Copiar la URL
   que muestra al crearlo.
3. Prender la Raspberry conectada al televisor y a la red, y desde una PC:

   ```bash
   scp -r raspberry/ usuario@display-pb.local:~/
   ssh usuario@display-pb.local
   cd raspberry
   sudo ./install.sh --url "https://192.168.4.95:3000/display/?key=K7M4-Q2XP-HN3R"
   sudo reboot
   ```

   Al volver arranca sola en la pantalla del llamador. En el LIS, el
   dispositivo pasa a **En línea**.

Opciones de `install.sh` (`./install.sh --help`):

| Opción | Para qué |
|---|---|
| `--rotate 90` | Televisor parado (0, 90, 180, 270). |
| `--restart-at 04:30` | Hora del reinicio diario del navegador (`never` lo apaga). |
| `--audio hdmi` | Por dónde sale el timbre: `hdmi`, `jack` o `none`. |
| `--hostname display-pb` | Nombre en la red. |
| `--cert-from host:puerto` | De dónde bajar el certificado, si no es el de la URL. |

Se puede volver a correr: pisa la configuración con la nueva.

## El día a día

- **Se regeneró la clave en el LIS** (o se reusa la Raspberry para otro
  display): `sudo ./set-url.sh "https://…/display/?key=NUEVA-CLAVE"`.
- **Ver qué pasa**: `journalctl -u lis-kiosk -f`.
- **Reiniciar el navegador**: `sudo systemctl restart lis-kiosk`.
- **Entrar por consola en el televisor**: `Ctrl+Alt+F2` con un teclado.
- **Cambió el certificado del servidor** (`nginx/certs`): volver a correr
  `install.sh` con la misma URL, que lo baja de nuevo.

### Si algo no anda

| Síntoma | Qué mirar |
|---|---|
| Pantalla negra al arrancar | `journalctl -u lis-kiosk`: si dice "esperando a…", el servidor no responde desde la Raspberry. |
| "Clave del display" en pantalla | La clave se regeneró o el dispositivo se borró/desactivó en el LIS. `set-url.sh` con la URL nueva. |
| "Sin conexión" abajo a la derecha | Reverb (puerto 6001) no responde. El display sigue mostrando videos y, al volver, recupera los llamados. |
| Los llamados aparecen pero no suena | Volumen del televisor; `--audio` (HDMI vs jack). |
| El video se traba | Bajar la resolución o el bitrate (1080p30, ≤ 8 Mbps, H.264). |

## Qué deja instalado

- `cage` (compositor Wayland de una sola ventana) + Chromium en kiosko,
  corriendo como el usuario `lis`, sin sudo.
- `/etc/lis-kiosk.conf`: la URL y la rotación.
- `lis-kiosk.service`: lo arranca en la consola 1 y lo levanta de nuevo si se
  cae. `lis-kiosk-restart.timer`: el reinicio diario.
- El certificado del servidor como confiable para Chromium (sin eso no guarda
  los videos: el almacenamiento del navegador exige HTTPS válido).
- `consoleblank=0` en `cmdline.txt`, el timbre por HDMI y el watchdog del
  hardware (si el sistema se cuelga, se reinicia solo).

## Tótem en una tableta

Mientras el tótem sea una tableta y no una Raspberry con pantalla táctil:

- Un navegador en **modo kiosko** que bloquee la tableta en la URL del tótem
  (`https://…/kiosk/?key=…`). En Android, *Fully Kiosk Browser* es el más
  usado.
- El certificado del servidor es autofirmado: instalarlo en la tableta
  (Ajustes > Seguridad > Instalar certificado, bajándolo de
  `https://192.168.4.95:3000`) o, en Fully, activar *Ignore SSL errors*.
- **Imprimir**: por ahora el ticket se imprime con el diálogo del sistema
  (botón *Imprimir* en la pantalla del turno), así que la tableta necesita
  tener configurada la impresora (Mopria o el plugin del fabricante). Cuando
  esté el print engine, el ticket sale directo por la impresora de red.
