# Resultados de la prueba `pruebapartition` (2026-11-04/05)

> Evidencia del **sub-issue #142 (B2)** del issue #110. Repositorio de origen del análisis: `dbt-cloud-habi-dlh` (sub-issue #142).

**Conclusión:** Datastream crea y llena una tabla de BigQuery **particionada por mes y con cluster** a partir de `habi_brokers.broker_activity` (Aurora MySQL, sin partición). Funcionó tanto con la carga continua (CDC) como con el backfill completo:
- Los ids coinciden 1:1 con producción.
- El filtro de los últimos 30 días pasa a leer más de un 95 % menos.
- **Riesgo encontrado:** el backfill dejó 1,7 M de filas duplicadas exactas, un 3,6 % de la tabla.

Producción (`habi-brokers-co` y `co_habi_brokers.broker_activity`) no tuvo ningún cambio durante toda la prueba. Lo comprueba `validaciones\validar.ps1` contra la línea base.

## Cronología

| Bogotá | UTC | Paso | Resultado |
|---|---|---|---|
| 4-nov 16:18 | 21:18 | Fase 1: `apply` con `NOT_STARTED` | Stream creado. Datastream validó la conexión con Aurora y BigQuery |
| 4-nov 16:26 | 21:26 | Fase 2: `apply` con `RUNNING` y `backfill = none` | Tabla creada **con partición y cluster** desde el primer dato. 0 filas faltantes contra producción en la misma ventana |
| 4-nov 20:10 | 01:10 | Cambio a `backfill = all` (`update in-place`) | **No disparó el backfill** de la tabla, que ya estaba en el stream (`backfill_job_state` vacío) |
| 4-nov 20:29 | 01:29 | `DROP TABLE` de la tabla de prueba | El stream viejo la recreó con la partición durante el borrado |
| 4-nov 20:32 | 01:32 | `terraform apply -replace` (stream recreado con `backfill_all`) | El stream se recreó con el mismo nombre |
| 4-nov 20:36 | 01:36 | Backfill automático | `ACTIVE`, disparado como `AUTOMATIC` |
| 4-nov 20:50 | 01:50 | Backfill terminado | `COMPLETED` en **13 min 24 s** |

## Configuración probada

| | Valor |
|---|---|
| Stream | `pruebapartition` (us-central1), Terraform en `envs/pruebapartition` |
| Origen | Perfil `habi-prod-co`, solo `habi_brokers.broker_activity` |
| Destino | `brokers-main-prod.tmp.habi_brokers_broker_activity` (perfil `destino-prueba-ocd`) |
| Modo | `merge`, `data_freshness = 3600s`, igual que producción |
| Partición | `created_at`, `PARTITIONING_TIME_GRANULARITY_MONTH` (`rule_sets` de Datastream) |
| Cluster | `created_at, broker_id` |
| Provider | `hashicorp/google` 8.10.0, Terraform 1.16.5 |

## Resultados

### Carga del backfill

| Hora UTC | Filas | Meses |
|---|---|---|
| 01:37:59 | 2.992.448 | — |
| 01:39:05 | 3.688.003 | 17 |
| 01:43:30 | 24.610.346 | 45 |
| 01:51:46 | 49.142.358 | 68 |

El ritmo pasó de unas 10.500 filas por segundo al principio a unos 5 M por minuto, porque Datastream fue sumando tareas en paralelo.

### A. Historia completa

| Tabla | Filas | Ids distintos | Desde | Hasta |
|---|---|---|---|---|
| Producción | 47.437.837 | 47.436.917 | 2021-04-01 00:36:01 | 2026-11-05 01:52:02 |
| Prueba | 49.142.364 | 47.436.911 | 2021-04-01 00:36:01 | 2026-11-05 01:51:54 |

**MySQL conserva toda la historia desde 2021-04-01.** Los 6 ids de diferencia son actividad que llegó en los segundos entre una consulta y la otra.

### B. Comparación de ids con producción (creados antes de 2026-11-05 01:29 UTC)

| Faltan en la prueba | Sobran en la prueba |
|---|---|
| **0** | **0** |

### C. Particiones (2026-11-05 ~01:55 UTC)

- **67 particiones mensuales consolidadas**: 45.704.176 filas y 5,05 GB.
- Además había ~3,44 M filas en el buffer de streaming (`estimatedRows`), que BigQuery consolida solo.
- Particiones recientes: `202611`=356, `202610`=172.846, `202609`=869.145, `202608`=908.476, `202607`=1.039.377. Son conteos parciales, porque el resto seguía en el buffer.

### D. Ahorro (bytes del dry-run)

| Consulta | Producción | Prueba | Reducción |
|---|---|---|---|
| `id, broker_id, created_at` de los últimos 30 días | 1.138.483.368 B (1,14 GB) | 4.156.848 B (~4 MB)* | >99 %* |
| `id, broker_id, created_at` desde 2026-11-01 | 1.138.483.368 B | 8.544 B* | — |
| `SELECT *` desde 2026-11-01 | 5.632.650.816 B (5,63 GB) | 42.066 B* | — |

\* Medido con parte de los datos recientes todavía en el buffer de streaming, que el dry-run no cuenta. **Hay que repetir la medición cuando el buffer se vacíe.** Lo esperable es unos 30-40 MB para los 30 días, más de un 95 % menos.

### E. Duplicados

| Copias por id | Ids | Filas |
|---|---|---|
| 1 | 45.731.471 | 45.731.471 |
| 2 | 1.705.453 | 3.410.906 |

Detalle de los ids duplicados:

| Tipo | Ids | Qué es |
|---|---|---|
| Copia exacta: mismo `uuid`, mismo `source_timestamp` y mismos datos | **1.705.273** | El mismo evento del backfill escrito dos veces. **Causa probable:** Datastream reintentó esos tramos de lectura, y en una tabla sin PK nada evita la segunda escritura. No está confirmado en la documentación |
| `uuid` distinto con los mismos datos | 180 | Cruce esperado: la fila llegó por CDC y otra vez por el backfill, en los minutos en que corrieron a la vez |

Ids duplicados por mes de `created_at`: 2022-05: 58.326 · 2022-06: 117.142 · 2022-07: 203.504 · 2022-08: 278.942 · 2022-09: 245.420 · 2022-10: 41.308 · 2024-01: 50.470 · 2024-02: 710.157 · 2026-11: 184.

Producción tiene 920 ids repetidos, que son actualizaciones agregadas como filas nuevas. En la prueba, cada id tiene una sola versión de los datos, porque el backfill lee el estado actual de MySQL.

## Lo que se aprendió

1. **Las `rule_sets` de Datastream funcionan**, con partición mensual por `created_at` y cluster de 2 columnas. Solo se aplican cuando Datastream crea la tabla.
2. **Cambiar a `backfill_all` en un stream que ya existe no lanza el backfill** de las tablas que ya están en él. Las formas que funcionan son:
   - Lanzarlo a mano. Requiere `datastream.objects.startBackfillJob`, que Iván no tiene.
   - **Recrear el stream** (`terraform apply -replace`). Eso solo requiere `streams.create` y `streams.delete`. El nombre se puede reutilizar enseguida.
3. **El backfill automático es completo**, sin filtro `WHERE`. Para las 47 M filas tardó 13 minutos y no hubo errores en el stream. No se midió la carga sobre Aurora.
4. **MySQL tiene toda la historia**, así que en producción se podría recrear la tabla desde el origen sin perder datos.
5. **En tablas sin PK, el backfill puede dejar duplicados exactos** (3,6 % en esta prueba). Se identifican por `datastream_metadata.uuid`.
6. **Recrear una tabla en `tmp` pierde su expiración extendida.** Vuelve a la expiración por defecto de 5 días.

## Implicaciones para producción (camino A del sub-issue #142)

- **Es viable:** se configura la regla en `habi-brokers-co`, se renombra `co_habi_brokers.broker_activity` a un respaldo y Datastream crea la tabla particionada con backfill.
- **Pero:**
  - Recrear `habi-brokers-co` afectaría sus 46 tablas. Habría que lanzar el backfill **a mano y solo para `broker_activity`**, y eso requiere a alguien con `datastream.objects.startBackfillJob`.
  - Hay que **limpiar los duplicados** después del backfill, por `uuid`, o confirmar que todos los consumidores deduplican:
    - `ent_actividad_brokers` (dbt): sí deduplica, por `id`.
    - Core `buyers_medalion_co`: sin verificar.
    - Proceso MX (`buyers-mx-dwh-hour-sa`): sin verificar.
  - Los permisos IAM a nivel de tabla (`dataViewer` de `buyers-mx-dwh-hour-sa` y el usuario lector) hay que volver a aplicarlos sobre la tabla nueva, y eso lo hace el admin.

## Pendientes de la prueba

- [x] Expiración extendida: la tabla vence el **2026-12-05 02:07 UTC** (4-dic 21:07 en Bogotá). Tiene 49.142.908 filas.
- [x] Stream `pruebapartition` **pausado** el 2026-11-05 a las 02:13 UTC con `gcloud`. Pasó por `DRAINING` y quedó `PAUSED` a las 21:18 en Bogotá. `terraform.tfvars` ya tiene `desired_state = "PAUSED"`.
- [ ] Sincronizar el estado de Terraform con `terraform apply`. El plan muestra solo `desired_state: RUNNING -> PAUSED`.
- [ ] Repetir el dry-run del punto D cuando el buffer de streaming esté vacío.
- [ ] Al cerrar la prueba: `terraform destroy` y `DROP TABLE` de la tabla en `tmp`.

## Ensayo del procedimiento de producción (`ENSAYO_TMP.sql`), 2026-11-05

| UTC | Paso | Resultado |
|---|---|---|
| 02:13 | Stream pausado (`gcloud`, pasó por `DRAINING`) | Último evento escrito: 02:13:17 |
| 14:01 | Tabla particionada **creada a mano** (mismo DDL que Datastream) + `INSERT` con `QUALIFY` por uuid | 49.142.908 → **47.437.635 filas = 47.437.635 uuids** (1,7 M duplicados eliminados) |
| ~14:05 | Intercambio de nombres: original → `ensayo_respaldo`, nueva → `habi_brokers_broker_activity` | — |
| 14:24 | Reanudación (`terraform apply`, `desired_state = RUNNING`) | Stream `RUNNING`. **No se repitió el backfill**: sigue `COMPLETED` con inicio a las 01:36:52, aunque el stream tiene `backfill_all` |
| 14:36 | Revisión E9/E10 | Ver abajo |

**E9 y E10, a los 11 minutos de reanudar:**
- **Datastream escribe en la tabla creada a mano.** Llegaron 7.742 filas nuevas y el último cambio es de las 14:35:52.
- **El respaldo renombrado no recibió nada.** Sigue con 49.142.908 filas y el último cambio es de las 02:13:17.
- **La partición y el cluster siguen intactos.** La tabla mantiene su `creation_time` de 14:01:01, así que no se recreó.
- **Se recuperaron las 12 h de pausa sin huecos.** El primer evento después de la pausa es de las 02:13:19. Ids creados entre 02:13 y 14:30: 7.476 en producción y 7.476 en la prueba, con **0 faltantes y 0 sobrantes**. El binlog alcanzó para una pausa de 12 horas.
- **0 uuid repetidos** en ese momento: 47.445.377 filas = 47.445.377 uuids.

**E11, revisión de las 15:46 UTC (1 h 22 min después de reanudar):**
- **0 uuid repetidos:** 47.449.356 filas = 47.449.356 uuids. Las filas de la reanudación (14:24) ya estaban consolidadas: la entrada más antigua del buffer era de las 15:25 y quedaban solo 1.127 filas en él.
- Desde la pausa llegaron 11.721 filas. Ids creados después de las 02:13 contra producción: 11.207 y 11.207, con **0 faltantes y 0 sobrantes**.
- El respaldo sigue igual: 49.142.908 filas, último cambio a las 02:13:17.
- La partición sigue igual: `creation_time` 14:01:01, con partición mensual y cluster.
- El backfill sigue `COMPLETED`, sin repetirse.

**El ensayo pasa todos los criterios de go / no-go.**

## Ensayo 2: stream sin `rule_sets`, igual que `habi-brokers-co` (2026-11-05)

El ensayo 1 se hizo con un stream que tenía la regla de partición, y producción no la tiene.

| UTC | Paso | Resultado |
|---|---|---|
| ~16:05 | `terraform apply` con `aplicar_reglas_particion = false` | Cambio en el lugar (0 / 1 / 0). El `describe` ya no muestra `ruleSets` |
| 16:06:20 | Pausa con `gcloud` (igual que P3 en producción) | `PAUSED` a las 16:11. Último evento escrito durante el `DRAINING`: 16:11:57 |
| 16:46:42 | Reanudación con `gcloud` (igual que P11) | `RUNNING`. El primer dato nuevo llegó a las 16:49:38 |
| 16:52 | Revisión S4 | Ver abajo |

- **La tabla sigue siendo la creada a mano:** `creation_time` 2026-11-05 14:01:01, con partición mensual por `created_at` y cluster `created_at, broker_id`. **Un stream sin regla escribe en la tabla particionada y no la recrea.**
- **0 uuid repetidos:** 47.452.798 filas.
- **La pausa de 40 minutos se recuperó completa:** ids creados entre 16:00 y 16:47, 2.596 en producción y 2.596 en la prueba, con 0 faltantes y 0 sobrantes.
- **El backfill no se repitió:** sigue `COMPLETED` con inicio a las 01:36:52.

**Conclusión: la migración de producción no requiere cambiar la configuración de `habi-brokers-co`. Solo hay que pausarlo y reanudarlo.**

## Ahorro definitivo (dry-run del 2026-11-05 a las 15:47 UTC, con 1.127 filas en el buffer)

| Consulta | Producción (sin partición) | Particionada | Reducción |
|---|---|---|---|
| `id, broker_id, created_at` de los últimos 30 días | 1.138.786.032 B (1,139 GB) | 27.669.288 B (27,7 MB) | **−97,6 %** |
| Columnas que usa `ent_actividad_brokers`*, mes en curso | 2.336.243.776 B (2,336 GB) | 6.070.515 B (6,1 MB) | **−99,7 %** |
| Columnas que usa `ent_actividad_brokers`*, mes en curso y anterior | 2.336.243.776 B | 56.730.933 B (56,7 MB) | **−97,6 %** |
| Columnas que usa `ent_actividad_brokers`*, tabla completa | 2.336.243.776 B | 2.336.184.558 B | 0 % (es lo esperado) |
| `SELECT *` del mes en curso | 5.634.172.459 B (5,634 GB) | 14.878.829 B (14,9 MB) | **−99,7 %** |

\* `id, broker_id, activity, created_at, datastream_metadata.source_timestamp, datastream_metadata.is_deleted`

Tamaño de las particiones: `202611` = 112.680 filas y 13,6 MB, `202610` = 1.029.626 filas y 124,1 MB, `202609` = 1.074.896 filas y 129,0 MB.

**Qué significa para el #142b:** hoy, leer la fuente cuesta 2,34 GB por corrida en `ent_actividad_brokers`. Con la fuente particionada y un filtro **constante** sobre `created_at`, baja a ~6 MB (mes en curso) o ~57 MB (mes en curso y anterior). BigQuery factura un mínimo de 10 MB por tabla leída.

## Ensayo 3: agregar `rule_sets` a un stream que ya escribe en una tabla existente (2026-11-05)

Es el caso del paso 17 de la guía de producción: agregar la regla a `habi-brokers-co` después de la migración.

| UTC | Paso | Resultado |
|---|---|---|
| 19:39 | Foto de antes | 47.460.627 filas, 0 repetidos, `creation_time` 14:01:01 |
| 19:41:14 | `terraform apply` con `aplicar_reglas_particion = true` (`+ rule_sets`, 0 / 1 / 0) | Tardó 24 s. El stream sigue `RUNNING`, sin errores y con `ruleSets` |
| 19:41 | Objetos | **El backfill no se disparó**: sigue `COMPLETED` con inicio a las 01:36:52 |
| 19:44 | Datos | Siguen llegando a la **misma** tabla: `creation_time` 14:01:01, último cambio 19:44:21. 47.460.841 filas, **0 repetidos** |
| 19:46 | Contra producción | Ids creados entre 19:30 y 19:44: 642 en producción y 642 en la prueba, **0 faltantes y 0 sobrantes**. Partición y cluster intactos |

**Conclusión:** agregar la regla a un stream que ya está corriendo no recrea la tabla, no dispara un backfill y no interrumpe la carga. El paso 17 (regla en `habi-brokers-co`) queda respaldado.

## Pruebas de partición y cluster (2026-11-05 ~17:00 UTC, `PRUEBAS_PARTICION_CLUSTER.sql`)

**Configuración y reparto:** `created_at` es la columna de partición y la primera del cluster; `broker_id` es la segunda. En **67 de 68 meses**, el conteo calculado coincide exacto con los metadatos de su partición. El mes en curso difiere solo por el buffer de streaming. 0 filas en `__NULL__`.

**Poda de particiones (dry-run, columnas `id, broker_id, created_at`):**

| Filtro | Bytes | ¿Poda? |
|---|---|---|
| Sin filtro | 1.138.807.560 | — |
| `created_at >= TIMESTAMP('2026-10-01')` | 27.719.664 | ✅ |
| Un mes (`>=` y `<`) | 25.015.344 | ✅ |
| `created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)` | 27.719.664 | ✅ |
| `created_at >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)` | 3.008.640 | ✅ |
| `DATE(created_at) >= '2026-10-01'` | 27.719.664 | ✅ |
| `DATE(created_at, 'America/Bogota') >= '2026-10-01'` | 27.719.664 | ✅ |
| Solo `broker_id = 17480` | 140.811.336 | Solo por cluster |
| `datastream_metadata.source_timestamp >= ...` | 1.518.410.080 | ❌ Lee **más** que sin filtro |

**Ejecución real (`--use_cache=false`, bytes de `INFORMATION_SCHEMA.JOBS_BY_USER`, columnas `id, broker_id`):**

| Prueba | Filas | Bytes procesados | Slot ms |
|---|---|---|---|
| Sin filtro | 47.454.251 | 759.205.040 | 39.299 |
| Mes completo (oct-2026) | 1.029.626 | 24.711.024 | 771 |
| **Un día** dentro del mes (cluster por `created_at`) | 38.407 | **7.315.944** (−70 % contra el mes) | 64 |
| Un broker dentro del mes (cluster por `broker_id`) | 12.186 | 24.711.024 (**igual que el mes**) | 107 |
| Un broker en toda la tabla | 55.996 | 93.874.224 (−88 % contra sin filtro) | 707 |
| `created_at >=` subconsulta sobre **otra tabla** | 129.295 | 396.151.904 | 22.353 |

**Conclusiones:**
1. La **partición** poda con cualquier filtro directo sobre `created_at`, incluidos `DATE()` con zona horaria y `CURRENT_TIMESTAMP()`.
2. El **cluster por `created_at`** sí reduce la lectura dentro del mes: un día lee un 70 % menos.
3. El **cluster por `broker_id`** no reduce bytes dentro de un mes, porque como segunda columna casi no agrupa, aunque sí baja los slots. En toda la tabla reduce un 88 %, gracias a la poda por bloques.
4. **Una subconsulta sobre otra tabla sí poda en la ejecución.** La tabla principal leyó ~3 MB y los ~393 MB restantes son la propia subconsulta, que recorrió `created_at` del respaldo. El dry-run no lo muestra. En dbt conviene igual usar constantes o `CURRENT_TIMESTAMP()`: el costo es predecible y la subconsulta se paga aparte.
5. **Nunca hay que filtrar por `datastream_metadata.source_timestamp`**: no poda y lee más que sin filtro.

## Consultas usadas

```sql
-- A. Historia completa
SELECT 'prueba' AS tabla, COUNT(*) AS filas, COUNT(DISTINCT id) AS ids, MIN(created_at) AS desde, MAX(created_at) AS hasta
FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`
UNION ALL
SELECT 'produccion', COUNT(*), COUNT(DISTINCT id), MIN(created_at), MAX(created_at)
FROM `brokers-main-prod.co_habi_brokers.broker_activity`;

-- B. Ids faltantes o sobrantes
WITH p AS (SELECT DISTINCT id FROM `brokers-main-prod.co_habi_brokers.broker_activity` WHERE created_at < TIMESTAMP('2026-11-05 01:29:00')),
     t AS (SELECT DISTINCT id FROM `brokers-main-prod.tmp.habi_brokers_broker_activity` WHERE created_at < TIMESTAMP('2026-11-05 01:29:00'))
SELECT
  (SELECT COUNT(*) FROM p LEFT JOIN t USING (id) WHERE t.id IS NULL) AS faltan_en_prueba,
  (SELECT COUNT(*) FROM t LEFT JOIN p USING (id) WHERE p.id IS NULL) AS sobran_en_prueba;

-- C. Particiones
SELECT COUNT(*) AS particiones, SUM(total_rows) AS filas_consolidadas,
       ROUND(SUM(total_logical_bytes)/POW(1024,3),2) AS gb
FROM `brokers-main-prod.tmp.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name = 'habi_brokers_broker_activity';

-- D. Ahorro (correr con dry run)
SELECT id, broker_id, created_at FROM `brokers-main-prod.co_habi_brokers.broker_activity`
WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY);
SELECT id, broker_id, created_at FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`
WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY);

-- E. Duplicados
SELECT copias, COUNT(*) AS ids, SUM(copias) AS filas
FROM (SELECT id, COUNT(*) AS copias FROM `brokers-main-prod.tmp.habi_brokers_broker_activity` GROUP BY id)
GROUP BY copias ORDER BY copias;

-- E2. Tipo de duplicado
WITH d AS (
  SELECT id, COUNT(*) AS copias,
         COUNT(DISTINCT TO_JSON_STRING((SELECT AS STRUCT t.* EXCEPT (datastream_metadata)))) AS versiones_distintas_datos,
         COUNT(DISTINCT datastream_metadata.uuid) AS uuids,
         MIN(datastream_metadata.source_timestamp) AS ts1, MAX(datastream_metadata.source_timestamp) AS ts2
  FROM `brokers-main-prod.tmp.habi_brokers_broker_activity` t
  GROUP BY id HAVING COUNT(*) > 1
)
SELECT versiones_distintas_datos, uuids, (ts1 = ts2) AS mismo_source_ts, COUNT(*) AS ids
FROM d GROUP BY 1, 2, 3 ORDER BY ids DESC;

-- Limpieza de duplicados exactos (referencia para producción; NO ejecutada)
-- CREATE OR REPLACE TABLE ... AS
-- SELECT * FROM `...broker_activity` WHERE TRUE
-- QUALIFY ROW_NUMBER() OVER (PARTITION BY datastream_metadata.uuid ORDER BY datastream_metadata.source_timestamp) = 1;
```
