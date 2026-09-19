<#
.SYNOPSIS
    Arma el paquete de la Labcore API para instalarla como servicio de Windows
    en una máquina del cliente.

.DESCRIPTION
    La Labcore API (repo api-lis-labcore) no corre en el stack Docker del LIS:
    el SQL Server de Labcore de CEBAC es 2008 R2 y el driver de .NET desde
    Linux no pasa del post-login. Desde Windows usa Schannel, como SSMS, y
    funciona. Este script deja un zip autocontenido (no hace falta instalar
    .NET en el server del cliente) con:

      app\Labcore.Api.exe                 self-contained win-x64, un solo archivo
      app\appsettings.Production.json     la config de ESTA instalación (labcore-api\ de este repo)
      app\sql-overrides\                  queries ajustadas al cliente (idem)
      install-windows-service.ps1         instalador (del repo de la API)
      DESPLIEGUE.md                       los pasos, para quien lo instale

    Se corre desde ESTA máquina (la de desarrollo, con el SDK de .NET 10 y el
    repo de la API clonado). El zip se copia al Windows del cliente y ahí se
    sigue DESPLIEGUE.md.

    Con -NoSettings el paquete lleva sólo el binario (más el appsettings.json
    embebido, que trae los defaults y ningún secreto): ni
    appsettings.Production.json ni sql-overrides\. Sirve para actualizar una
    instalación que ya tiene su config en la máquina, o para entregarle el
    binario a quien configure la instalación por su cuenta.

.PARAMETER Source
    Carpeta del clone de api-lis-labcore.

.PARAMETER Output
    Dónde dejar el zip. Por defecto artifacts\ de este repo (ignorado por git).

.PARAMETER NoSettings
    No mete en el paquete la config de la instalación (appsettings.Production.json
    ni sql-overrides\). El zip sale con sufijo "-nosettings".

.EXAMPLE
    .\scripts\build-labcore-api-windows.ps1 -Source "C:\Projects\Customs\labcore api"

.EXAMPLE
    .\scripts\build-labcore-api-windows.ps1 -NoSettings
#>
[CmdletBinding()]
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\..\..\Customs\labcore api'),

    [string]$Output = (Join-Path $PSScriptRoot '..\artifacts'),

    [switch]$NoSettings
)

$ErrorActionPreference = 'Stop'

$infra = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not (Test-Path (Join-Path $Source 'deploy\publish.ps1'))) {
    throw "No encuentro el repo de la API en '$Source' (falta deploy\publish.ps1). Pasá -Source."
}
$Source = (Resolve-Path $Source).Path

$version = (git -C $Source rev-parse --short HEAD).Trim()
$dirty = (git -C $Source status --porcelain)
if ($dirty) { Write-Warning "El repo de la API tiene cambios sin commitear: el paquete no va a coincidir con $version." }

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$name = "labcore-api-windows-$stamp-$version"
if ($NoSettings) { $name += '-nosettings' }
$stage = Join-Path ([IO.Path]::GetTempPath()) $name
$app = Join-Path $stage 'app'

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Path $app | Out-Null

Write-Host "==> dotnet publish (win-x64, self-contained) de $Source @ $version"
& (Join-Path $Source 'deploy\publish.ps1') -Target windows -Output $app

# Al paquete va un solo archivo de configuración: el appsettings.json embebido
# (defaults, sin secretos). Cualquier otro appsettings.*.json que el publish haya
# arrastrado (Development, *.local) no tiene que llegar al cliente.
Get-ChildItem $app -Filter 'appsettings.*.json' | ForEach-Object {
    Write-Warning "El publish dejó $($_.Name); lo saco del paquete."
    Remove-Item $_.FullName
}

$overrides = Join-Path $app 'sql-overrides'
if (-not (Test-Path $overrides)) { New-Item -ItemType Directory -Path $overrides | Out-Null }

if (-not $NoSettings) {
    # La config de la instalación y las queries del cliente viven en este repo
    # (rama del cliente), no en el de la API.
    Copy-Item (Join-Path $infra 'labcore-api\appsettings.Production.json') (Join-Path $app 'appsettings.Production.json')
    Get-ChildItem (Join-Path $infra 'labcore-api\sql-overrides') -Recurse -File |
        Where-Object { $_.Name -ne '.gitkeep' } |
        ForEach-Object {
            $rel = $_.FullName.Substring((Join-Path $infra 'labcore-api\sql-overrides').Length).TrimStart('\')
            $dest = Join-Path $overrides $rel
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Copy-Item $_.FullName $dest
        }
}

Copy-Item (Join-Path $Source 'deploy\install-windows-service.ps1') (Join-Path $stage 'install-windows-service.ps1')

if ($NoSettings) {
$readme = @"
# Labcore API — binario para instalar como servicio de Windows

Paquete: ``$name`` (api-lis-labcore @ $version, .NET 10 autocontenido: no hace falta instalar nada más).

Este paquete trae **sólo el binario**, sin la configuración de ninguna instalación: ``app\``
contiene ``Labcore.Api.exe`` y el ``appsettings.json`` embebido (defaults de la API, sin secretos).
La configuración de la instalación se agrega al lado del exe:

- ``appsettings.Production.json``: pisa al embebido. Como mínimo ``Kestrel:Endpoints:Http:Url``
  (``http://0.0.0.0:5080`` para que se llegue desde otra máquina; el embebido escucha sólo en
  ``localhost``) y ``Api:ApiKeys`` con el nombre del consumidor y ``CanWrite``. Qué significa cada
  clave: README del repo api-lis-labcore.
- ``sql-overrides\``: queries ajustadas al cliente, si las hay. Puede quedar vacía.
- Los secretos (``Lis:ConnectionString`` y ``Api:ApiKeys[0].Key``) **no** van en ningún archivo:
  los guarda ``install-windows-service.ps1`` como variables de entorno del servicio.

## Instalación nueva

1. Copiar la carpeta ``app`` a ``C:\LabcoreApi`` (o donde se prefiera; sin espacios es más cómodo)
   y dejar ahí ``appsettings.Production.json`` y ``sql-overrides\``.

2. Instalar el servicio, pasándole la cadena de conexión y la clave de API (24+ caracteres, sólo
   letras y números; la misma que usa el consumidor en ``X-Api-Key``):

   ``````powershell
   cd <carpeta donde se descomprimió el zip>
   .\install-windows-service.ps1 -BinaryPath C:\LabcoreApi\Labcore.Api.exe ``
       -ConnectionString 'Server=<ip>;Database=Labcore;User ID=<usuario>;Password=<clave>;TrustServerCertificate=True;Encrypt=False' ``
       -ApiKey '<la clave>' ``
       -OpenFirewall
   ``````

3. Verificar:

   ``````powershell
   Get-Service LabcoreApi                          # Running
   curl.exe http://localhost:5080/health/ready     # Healthy
   ``````

   Si ``/health/ready`` responde 503, la API no llega al SQL Server: el motivo está en
   ``C:\LabcoreApi\logs\labcore-api-<fecha>.log`` (usuario/clave, IP/puerto o firewall del SQL
   Server, o TLS 1.0 deshabilitado como cliente en Windows Server 2025 / Windows 11 24H2).

## Actualizar una instalación existente

Detener el servicio, copiar el contenido de ``app`` sobre ``C:\LabcoreApi`` (el
``appsettings.Production.json`` y ``sql-overrides\`` que ya están en la máquina quedan como están:
este paquete no los trae) y volver a correr ``install-windows-service.ps1 -BinaryPath ...``
**sin** ``-ConnectionString`` ni ``-ApiKey``: el instalador conserva los valores ya guardados.

## Desinstalar

``````powershell
Stop-Service LabcoreApi; sc.exe delete LabcoreApi
``````
"@
} else {
$readme = @"
# Labcore API — instalación como servicio de Windows

Paquete: ``$name`` (api-lis-labcore @ $version, .NET 10 autocontenido: no hace falta instalar nada más).

## Requisitos de la máquina

- Windows Server 2016 o superior, o Windows 10/11 (64 bits). **No** puede ser el propio servidor
  del SQL Server 2008 R2: ese Windows es demasiado viejo para .NET 10.
- Acceso de red al SQL Server de Labcore (``192.168.5.10:1433``).
- Que el servidor del LIS (Linux) llegue a esta máquina por TCP 5080.
- PowerShell como administrador para instalar.

## Pasos

1. Copiar la carpeta ``app`` a ``C:\LabcoreApi`` (o donde se prefiera; sin espacios es más cómodo).
   Adentro tienen que quedar ``Labcore.Api.exe``, ``appsettings.Production.json`` y ``sql-overrides\``.

2. Instalar el servicio, pasándole la cadena de conexión y la clave de API. La clave tiene que
   ser **la misma** que ``LABCORE_API_KEY`` en el ``.env`` de lis-infra del servidor del LIS
   (24+ caracteres, sólo letras y números). Los dos valores quedan guardados como variables de
   entorno del servicio, no en ningún archivo.

   ``````powershell
   cd <carpeta donde se descomprimió el zip>
   .\install-windows-service.ps1 -BinaryPath C:\LabcoreApi\Labcore.Api.exe ``
       -ConnectionString 'Server=192.168.5.10;Database=Labcore;User ID=<usuario>;Password=<clave>;TrustServerCertificate=True;Encrypt=False' ``
       -ApiKey '<LABCORE_API_KEY>' ``
       -OpenFirewall
   ``````

   ``-OpenFirewall`` abre el 5080 en los perfiles Dominio y Privado. Si la máquina está en perfil
   Público, agregar ``-Profile Public`` a mano en la regla o cambiar el perfil de la red.

3. Verificar:

   ``````powershell
   Get-Service LabcoreApi                          # Running
   curl.exe http://localhost:5080/health/ready     # Healthy
   ``````

   Si ``/health/ready`` responde 503, la API no llega al SQL Server: el motivo está en
   ``C:\LabcoreApi\logs\labcore-api-<fecha>.log``. Los casos típicos:
   - *Login failed for user*: usuario o clave.
   - *A network-related or instance-specific error*: IP/puerto o firewall del SQL Server.
   - *handshake* / *SSL Provider*: el Windows tiene TLS 1.0 deshabilitado como cliente (Server 2025
     y Windows 11 24H2 en adelante). Habilitarlo:
     ``````powershell
     New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client' -Force | Out-Null
     Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client' -Name Enabled -Value 1 -Type DWord
     Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client' -Name DisabledByDefault -Value 0 -Type DWord
     Restart-Service LabcoreApi
     ``````
     (Es una baja de seguridad de esa máquina como cliente TLS, necesaria sólo porque el SQL
     Server 2008 R2 no habla otra cosa.)

4. Desde el servidor del LIS, comprobar que llega y apuntar el adapter:

   ``````bash
   curl -s http://<ip-de-esta-máquina>:5080/health/ready; echo
   # en /opt/lis/lis-infra/.env:
   #   LABCORE_API_URL=http://<ip-de-esta-máquina>:5080
   #   LABCORE_API_KEY=<la misma clave>
   cd /opt/lis/lis-infra && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d adapter-labcore
   ``````

## Actualizar a una versión nueva

Detener el servicio, reemplazar el contenido de ``C:\LabcoreApi`` por la ``app`` del zip nuevo y
volver a correr ``install-windows-service.ps1 -BinaryPath ...`` **sin** ``-ConnectionString`` ni
``-ApiKey``: el instalador conserva los valores ya guardados. ``appsettings.Production.json`` y
``sql-overrides\`` vienen en cada zip desde el repo lis-infra, así que cualquier ajuste local se
hace ahí (rama del cliente), no en la máquina.

## Desinstalar

``````powershell
Stop-Service LabcoreApi; sc.exe delete LabcoreApi
``````
"@
}
Set-Content -Path (Join-Path $stage 'DESPLIEGUE.md') -Value $readme -Encoding UTF8

if (-not (Test-Path $Output)) { New-Item -ItemType Directory -Path $Output | Out-Null }
$zip = Join-Path (Resolve-Path $Output).Path "$name.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item -Recurse -Force $stage

Write-Host ""
Write-Host "Paquete: $zip" -ForegroundColor Green
if ($NoSettings) {
    Write-Host "Adentro: app\ (exe + appsettings.json embebido; SIN appsettings.Production.json ni sql-overrides), install-windows-service.ps1, DESPLIEGUE.md"
} else {
    Write-Host "Adentro: app\ (exe + appsettings.Production.json + sql-overrides\), install-windows-service.ps1, DESPLIEGUE.md"
}
