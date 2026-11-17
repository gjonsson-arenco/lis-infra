# CEBAC — Labcore API del 2026-11-17

Entrega sólo de la **Labcore API** (repo `api-lis-labcore`, servicio de Windows en CEBAC, fuera de `redeploy.sh`).
El stack del LIS no cambia: queda en el release del 2026-11-12.

| Componente | Anterior | Entregado |
|---|---|---|
| labcore-api (api-lis-labcore) | 13cbfdf (2026-09-19, el del paquete `cebac/2026-10-06-0450`) | 778d196 (2026-11-11) |

Paquete: `artifacts/labcore-api-windows-20261117-1425-778d196.zip` (generado con `scripts/build-labcore-api-windows.ps1`, no se versiona).

## Por qué

Matías reabrió el 2026-11-16 el pasaje de órdenes a Labcore: en la orden LIS00029 seguían vacíos Usuario,
Prioridad, Fecha de retiro y Diagnóstico. El LIS, el adapter y el orchestrator estaban al día; la API que
escribe en la base de Labcore no se actualizaba desde el 2026-10-06, y todo lo que resuelve esos campos
entró en la API después.

## Qué cambia para el cliente

- **Quién cargó la orden**: `Ordenes.o_usr_login` recibe el login del usuario del LIS que la admitió, y
  `o_usr_id` si ese login existe en AppUsers (si no, la orden se crea igual y queda un aviso).
- **Prioridad**: si el LIS no manda código de prioridad, la API elige sola la urgente (`pr_urg = 1`) o
  la primera no urgente. Antes quedaba vacía.
- **Fecha de retiro**: `o_fec_retiro` recibe la fecha prometida por el LIS.
- **Diagnóstico**: va a `o_diagnostico`; los datos clínicos van a la nota.
- **Fecha de toma sin hora**: `o_fecha_toma` se graba a las 00:00, para que facturación encuentre las
  órdenes al importar por rango de fecha.
- **Pruebas repetidas**: una prueba pedida por dos estudios va una sola vez a `Laboratorios`.
- **Perfiles**: el renglón del perfil queda en OrdenesDet y sus pruebas se cargan bajo cada componente.
  Queda por confirmar contra una orden nativa de CEBAC si la GUI de Labcore espera además un renglón por
  componente (`Lis:Defaults:ProfileComponentsAsStudyRows`, apagado en esta entrega).

No cambia: el **mail** del paciente sólo se escribe en `Historias.h_mail` cuando la API crea el paciente.
Para un paciente que ya existía en Labcore, el campo Mail sigue como estaba.

## Notas de deploy

- `labcore-api/appsettings.Production.json` suma `Lis:Defaults:Production:EnsureTable = false`: el binario
  nuevo trae el middleware de instrumentos y, con el default, crearía la tabla `dbo.InstrumentProduction` en
  la base de Labcore al arrancar. CEBAC no lo usa.
- Actualización según `DESPLIEGUE.md` del zip: detener `LabcoreApi`, reemplazar el contenido de
  `C:\LabcoreApi` por la carpeta `app` del zip y correr `install-windows-service.ps1 -BinaryPath ...` **sin**
  `-ConnectionString` ni `-ApiKey` (conserva los que ya tiene el servicio). Verificar con
  `http://localhost:5080/health/ready`.
- No requiere cambios en el `.env` de lis-infra ni en el adapter.
