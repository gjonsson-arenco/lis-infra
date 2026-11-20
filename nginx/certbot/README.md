# Certificado TLS del LIS on-prem: Let's Encrypt por DNS (Route53)

CEBAC no tiene servidor DNS propio y el server del LIS no recibe conexiones desde
internet. Aun así el LIS se sirve por un nombre con certificado válido:

- **El nombre vive en nuestra Route53** y resuelve a la IP privada del server
  (`qa.cebac.ankra-lis.com → 192.168.4.95`). Un registro público puede apuntar a
  una IP privada; las PCs de CEBAC lo resuelven con el DNS que les da el router.
- **El certificado lo emite Let's Encrypt** validando por DNS (desafío DNS-01):
  el contenedor `certbot` escribe un TXT `_acme-challenge` en la zona con un
  usuario IAM acotado, Let's Encrypt lo lee, y emite. El server sólo necesita
  salida a internet. Renueva solo cada 60 días.
- **nginx no cambia**: certbot deja el certificado en `./nginx/certs/server.crt`
  y `server.key`, los mismos archivos que generaba
  [`generate-self-signed-cert.sh`](../generate-self-signed-cert.sh), y nginx se
  recarga solo cuando ve el archivo nuevo.

Por qué no ACM: el certificado público de ACM no se exporta (sólo vive en
ALB/CloudFront). La variante exportable cuesta por nombre y se renueva a mano;
una CA privada de ACM cuesta mucho más y obliga a instalar la CA en cada PC,
tótem y display, que es justo lo que queremos evitar.

Nombres acordados (2026-11-20): `qa.cebac.ankra-lis.com` para el ambiente actual
(QA) y `cebac.ankra-lis.com` para producción. Producción se arma con estos mismos
pasos cambiando el nombre.

## Piezas

| Pieza | Dónde |
|---|---|
| Servicio `certbot` (imagen `certbot/dns-route53`) | `docker-compose.prod.yml` |
| Loop de emisión/renovación | `nginx/certbot/entrypoint.sh` |
| Copia del cert a `./nginx/certs` | `nginx/certbot/deploy-hook.sh` |
| Recarga de nginx al cambiar el cert | `command:` del servicio `nginx` en el compose |
| Policy IAM mínima | `aws/onprem-cebac/certbot-route53-policy.json` |
| Variables | `.env` de lis-infra (`LIS_PUBLIC_HOST`, `LIS_CERT_*`, `CERTBOT_AWS_*`) |

La cuenta ACME y la lineage quedan en el volumen `letsencrypt`; `./nginx/certs`
sigue siendo un bind mount del host.

## Puesta en marcha (una vez por nombre)

### 1. Zona y registro en Route53

La zona `ankra-lis.com` tiene que existir en Route53 y el dominio estar delegado
a sus NS. Después, el registro A del LIS (TTL alto: la IP del server es fija y
así una caída corta de internet no deja a las PCs sin resolver):

```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name ankra-lis.com \
  --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch '{
  "Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
    "Name": "qa.cebac.ankra-lis.com", "Type": "A", "TTL": 3600,
    "ResourceRecords": [{"Value": "192.168.4.95"}]}}]}'
```

**Probar desde una PC de CEBAC antes de seguir:**

```
nslookup qa.cebac.ankra-lis.com
```

Tiene que devolver `192.168.4.95`. Si devuelve vacío o error aunque desde afuera
resuelva, el router de CEBAC filtra respuestas públicas con IP privada
("DNS rebinding protection", típico de MikroTik, pfSense, Fritz!Box): hay que
desactivarlo o poner el nombre en la lista blanca del router. Sin esto, nada de
lo que sigue sirve.

### 2. Usuario IAM para certbot

Un usuario dedicado, sin consola, con la policy de
`aws/onprem-cebac/certbot-route53-policy.json` reemplazando `<HOSTED_ZONE_ID>`.
Sólo puede escribir el TXT `_acme-challenge.qa.cebac.ankra-lis.com` en esa zona;
nada más.

```bash
sed "s/<HOSTED_ZONE_ID>/$ZONE_ID/" aws/onprem-cebac/certbot-route53-policy.json > policy.json
aws iam create-user --user-name lis-cebac-certbot
aws iam put-user-policy --user-name lis-cebac-certbot --policy-name route53-acme-challenge-qa-cebac \
  --policy-document file://policy.json
aws iam create-access-key --user-name lis-cebac-certbot
rm policy.json
```

(Desde Git Bash en Windows, no usar `/tmp` para el archivo: el `aws.exe` nativo
no ve ese path y falla con "No such file or directory". Un path relativo anda.)

Para QA esto ya está hecho (2026-11-20): zona `Z07607952ZLINJ6983CWT`, usuario
`lis-cebac-certbot`, policy `route53-acme-challenge-qa-cebac`, y el registro A.

Si el certificado lleva más nombres (`LIS_CERT_EXTRA_DOMAINS`), cada uno necesita
su `_acme-challenge.<nombre>` en la lista de la policy. Un wildcard del mismo
nombre (`*.qa.cebac.ankra-lis.com`) usa el mismo registro, no hace falta agregar.

### 3. Variables en el `.env` de lis-infra

```
LIS_PUBLIC_HOST=qa.cebac.ankra-lis.com
LIS_CERT_EMAIL=                # opcional: correo para los avisos de vencimiento
LIS_CERT_STAGING=true          # primero en modo prueba, ver paso 4
CERTBOT_AWS_ACCESS_KEY_ID=...
CERTBOT_AWS_SECRET_ACCESS_KEY=...
```

Y el origen nuevo en las que ya existían:

```
LIS_CHAT_CORS_ORIGINS=https://qa.cebac.ankra-lis.com:3000,https://192.168.4.95:3000
REVERB_ALLOWED_ORIGINS=qa.cebac.ankra-lis.com,192.168.4.95
```

(La IP se deja en las dos mientras el front siga entrando por IP y queden
displays o tótems sin reapuntar; se saca cuando estén todos en el nombre.)

### 4. Primera emisión: staging y después real

Let's Encrypt limita a 5 certificados idénticos por semana, así que la primera
vez se valida el circuito (DNS + IAM + salida a internet) contra su servidor de
pruebas, que no cuenta para el cupo y cuyo certificado **no** se instala en nginx:

```bash
./scripts/redeploy.sh --force        # o: docker compose ... up -d certbot nginx
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f certbot
```

Cuando el log diga `ok; próximo chequeo en 43200s`, el circuito anda. Entonces:

```
LIS_CERT_STAGING=false
```

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d certbot
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f certbot
```

El entrypoint descarta solo la lineage de staging y emite la real. En hasta 5
minutos nginx la toma (ver "Cómo funciona la recarga"). Verificar desde una PC:

```bash
openssl s_client -connect qa.cebac.ankra-lis.com:3000 -servername qa.cebac.ankra-lis.com </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -enddate
```

El issuer tiene que ser de Let's Encrypt (`R1x`/`E1x`), no `CN=192.168.4.95`.

### 5. Reapuntar lo que tenía la IP

El origen del LIS pasa de `https://192.168.4.95:3000` a
`https://qa.cebac.ankra-lis.com:3000`. Con un certificado emitido para el nombre,
entrar por IP vuelve a dar aviso de certificado, así que se reapunta todo junto:

1. **Front** (`/opt/lis/lis-front-monorepo/apps/lis/.env.prod`): las
   `NEXT_PUBLIC_API_*_URL`, `NEXT_PUBLIC_COGNITO_REDIRECT_URI` y
   `NEXT_PUBLIC_COGNITO_LOGOUT_URI`. Van inlined en el build, así que hace falta
   `redeploy.sh --force` para reconstruir `frontend` y `devices-web`.
2. **Cognito**: dar de alta las URLs nuevas de callback y sign-out en el app
   client del user pool, antes del rebuild del front (si no, nadie entra).
3. **Backend** (`/opt/lis/lis-backend/.env.prod`): `APP_URL` y
   `CORS_ALLOWED_ORIGINS` si están atadas a la IP.
4. **Displays (Raspberry)**: `sudo ./set-url.sh "https://qa.cebac.ankra-lis.com:3000/display/?key=..."`
   en cada una (`raspberry/set-url.sh`). La clave del equipo es la misma; la URL
   completa la muestra Configuración > Dispositivos al entrar al LIS por el
   nombre nuevo, porque la arma a partir del origen con el que se abrió.
   Con un certificado de CA pública, el paso de `install.sh` que confía en el
   certificado del server pasa a sobrar, pero no molesta.
5. **Tótem**: misma idea, la URL de `/kiosk/` con el nombre nuevo.
6. Cuando no quede nada entrando por IP, sacar `192.168.4.95` de
   `REVERB_ALLOWED_ORIGINS`.

No cambian: la Labcore API (le pega el adapter por IP de la máquina Windows), la
impresión de rótulos por TCP, ni el reconocimiento de estación por IP fija (mira
la IP de la PC cliente, no la del server).

## Cómo funciona la recarga de nginx

nginx arranca con un watcher al costado del proceso principal (ver `command:` en
el compose): cada 5 minutos compara la fecha de `server.crt` con una marca que
dejó al arrancar y, si es más nuevo, hace `nginx -s reload` (recarga en
caliente, sin cortar conexiones). No necesita el socket de Docker ni que certbot
sepa nada de nginx: sólo comparten la carpeta `./nginx/certs`.

## Operación

```bash
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"

$COMPOSE logs --tail=50 certbot                      # último intento
$COMPOSE exec certbot certbot certificates           # qué hay emitido y cuándo vence
$COMPOSE restart certbot                             # forzar un chequeo ahora
$COMPOSE exec certbot certbot renew --force-renewal --deploy-hook /opt/certbot-lis/deploy-hook.sh
```

- **Agregar nombres**: editar `LIS_CERT_EXTRA_DOMAINS` (y la policy IAM si el
  nombre no comparte `_acme-challenge`), `up -d certbot`. El loop reemite con
  `--expand`.
- **Cambiar el nombre principal**: cambiar `LIS_PUBLIC_HOST`, la policy IAM y el
  registro A, `up -d certbot`. Queda una lineage vieja en el volumen; se borra
  con `certbot delete --cert-name <nombre-viejo>`.
- **Si falla**: certbot reintenta cada 15 minutos y nginx sigue con el último
  certificado bueno. Causas típicas, en el log de certbot: `AccessDenied` (policy
  o zona equivocada), `NXDOMAIN`/`unauthorized` (el registro A no existe o la
  zona no está delegada), timeouts (sin salida a internet desde el contenedor).
- **Volver al autofirmado**: parar certbot (`$COMPOSE stop certbot`), correr
  `nginx/generate-self-signed-cert.sh` y `$COMPOSE restart nginx`.

## Producción

Mismos pasos con `cebac.ankra-lis.com`: registro A, policy IAM con su
`_acme-challenge.cebac.ankra-lis.com`, `LIS_PUBLIC_HOST`, y el reapuntado del
paso 5. Si en ese momento conviven QA y producción sobre la misma zona, cada uno
tiene su usuario IAM acotado a su propio nombre.
