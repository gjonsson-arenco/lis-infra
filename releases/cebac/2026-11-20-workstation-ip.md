# CEBAC — release `cebac/2026-11-20-2219`

Delta `cebac/2026-11-20-2141` → `cebac/2026-11-20-2219`, generado con `release-notes.sh` el 2026-11-20.

| Repo | Anterior | Desplegado | Commits |
|---|---|---|---|
| labcore-api | 13cbfdf | 13cbfdf | 0 |
| lis-adapters/lis-adapter-healthbook | b7301d2 | b7301d2 | 0 |
| lis-adapters/lis-adapter-labcore | 01e94f1 | 01e94f1 | 0 |
| lis-arca-gateway | d2f9c93 | d2f9c93 | 0 |
| lis-backend | 46b464c | b571f7b | 1 |
| lis-broker-gateway | 0cf6b59 | 0cf6b59 | 0 |
| lis-chat-service | 21fe699 | 21fe699 | 0 |
| lis-clinical-matcher | 4878104 | 4878104 | 0 |
| lis-front-monorepo | 03c2c84 | 46522d3 | 1 |
| lis-infra | 7816a35 | 7816a35 | 0 |
| lis-messaging-service | 433ae76 | 433ae76 | 0 |
| lis-orchestrator | 137f2dd | 137f2dd | 0 |
| lis-reports-engine | 3bb3cf3 | 3bb3cf3 | 0 |
| lis-rules-engine | d153df4 | d153df4 | 0 |

## Novedades para el cliente

### El LIS reconoce el puesto solo
- Si la PC tiene IP fija y esa IP está cargada en su estación (Configuración > Estaciones,
  campo "IP de la PC"), al entrar al LIS ya se está "Operando desde" esa estación en todas
  las pantallas, sin elegir nada. Aparece la marca **Puesto fijo**.
- Una PC sin IP cargada sigue eligiendo la estación a mano, y la elección queda guardada en
  el navegador como hasta ahora. Toma de muestras ya no guarda una elección aparte.
- Si la PC está dada de alta como una estación que no atiende las filas de la pantalla
  abierta, la pantalla lo avisa en vez de ofrecer otra estación.

## Notas de deploy

- **Migraciones nuevas (1)**:
  - 2026_11_21_100000_add_ip_address_to_stations_table — columna única `stations.ip_address`,
    rellenada desde `parameters.ip` (las IPs de IGOF cargadas el mismo día).
- Verificado en el server: 192.168.4.89 → Admisión 1, 192.168.4.230 → Toma de muestras,
  una IP desconocida → sin estación. Admisión 3 de IGOF sigue sin IP.
- Funciona porque nginx le habla a PHP-FPM por FastCGI directo: `REMOTE_ADDR` es la IP real
  de la PC. Si algún día se mete un proxy HTTP en el medio, hay que configurar
  `trustProxies` en el backend o el puesto deja de reconocerse.
