# Guía genérica: particionar y clusterizar una tabla de BigQuery que escribe Datastream

| | |
|---|---|
| Para qué | Convertir una tabla **existente** que alimenta Datastream en una tabla **particionada y con cluster**, sin perder datos, sin duplicarlos y conservando los accesos |
| Basada en | La ejecución real en `brokers-main-prod.co_habi_brokers.broker_activity` del 2026-11-05 (sub-issue #142) y tres ensayos en `brokers-main-prod.tmp`. Ver `ejemplos/broker_activity_20261105/` |
| Script de apoyo | `scripts/verificar_permisos.ps1` |
| Regla de oro | **Nunca se hace `RENAME` de la tabla que recibe streaming.** Se copia, se borra y se renombra la nueva (sección 7, paso 9) |

Las secciones marcadas **[OBLIGATORIO]** no se saltan. El **catálogo de errores** (sección 11) dice qué hacer con cada error conocido.

---

## 0. Hoja de parámetros (llénala antes de empezar)

En todos los SQL y comandos de esta guía, **busca y reemplaza** estos marcadores:

| Marcador | Qué es | Ejemplo (`broker_activity`, 2026-11-05) |
|---|---|---|
| `PROYECTO` | Proyecto de BigQuery donde está la tabla y el stream | `brokers-main-prod` |
| `DATASET` | Dataset de la tabla | `co_habi_brokers` |
| `TABLA` | Tabla que escribe Datastream | `broker_activity` |
| `STREAM` | Stream de Datastream que escribe la tabla | `habi-brokers-co` |
| `REGION` | Región del stream | `us-central1` |
| `BASE_ORIGEN` / `TABLA_ORIGEN` | Base de datos y tabla en el origen (para `rule_sets`) | `habi_brokers` / `broker_activity` |
| `COL_PART` | Columna de partición (TIMESTAMP, DATETIME o DATE) | `created_at` |
| `GRAN` | Granularidad: `HOUR`, `DAY`, `MONTH` o `YEAR` | `MONTH` |
| `CLUSTER` | Hasta 4 columnas de cluster | `created_at, broker_id` |
| `LLAVE` | Llave para deduplicar (sección 2.3) | `datastream_metadata.uuid` |
| `AAAAMMDD` | Fecha de la ventana | `20261105` |
| `MAX_STALENESS` | El `max_staleness` actual de la tabla (sección 2.1) | `INTERVAL 1 HOUR` |

Comandos de PowerShell que van al inicio de **cada** ventana nueva:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass   # si no, gcloud.ps1 y los scripts no corren
$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'                       # arreglo de IPv6 de esta máquina (si no, bq se cuelga)
cd "<ruta donde clonaste el repo>\particion-tablas-datastream"
```
Usa siempre **`gcloud.cmd`**, no `gcloud`.

---

## 1. Cómo funciona (en una página)

1. Se crea a mano una tabla **vacía** igual a la original, con `PARTITION BY` y `CLUSTER BY` (`TABLA_nueva`).
2. Se **pausa** el stream y se espera a que la tabla deje de cambiar.
3. Se **copia** la original a la nueva dentro de BigQuery, con una fila por `LLAVE`, y se valida con una huella.
4. Se hace un **respaldo** de la original con `COPY`, se **borra** la original y la nueva **toma su nombre** con `RENAME`.
5. Se **reanuda** el stream. Datastream escribe por nombre de tabla y sigue en la nueva.
6. Se verifican los accesos, los duplicados y la partición, y después a los consumidores.

**Por qué así:**

| Alternativa | Por qué no |
|---|---|
| `RENAME` de la tabla original | ❌ BigQuery lo bloquea si la tabla recibió streaming hace poco: `Cannot rename ... because it has streaming data`. Pasó en producción con 10 min de pausa. El bloqueo puede durar horas o días |
| Configurar la regla en el stream y dejar que Datastream recree la tabla con backfill | ❌ El backfill desde el origen dejó un **3,6 % de duplicados exactos** y carga la base de origen. Además, lanzar un backfill a mano requiere `datastream.objects.startBackfillJob` |
| `CREATE OR REPLACE TABLE` con otra partición | ❌ BigQuery no deja reemplazar una tabla con un esquema de partición distinto (`Cannot replace a table with a different partitioning spec`) |
| Particionar "en caliente" | ❌ BigQuery no permite agregar partición ni cambiarla en una tabla existente |

---

## 2. [OBLIGATORIO] Análisis de la tabla (días antes, solo lectura)

### 2.1 Tipo de tabla, tamaño y opciones
```sql
SELECT table_name, creation_time,
       REGEXP_CONTAINS(ddl, r'PRIMARY KEY') AS tiene_pk,
       upsert_stream_apply_watermark IS NOT NULL AS es_cdc_merge,
       REGEXP_CONTAINS(ddl, r'PARTITION BY') AS ya_particionada,
       ddl
FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLES`
WHERE table_name = 'TABLA';
```
```powershell
bq show --format=prettyjson PROYECTO:DATASET.TABLA    # numRows, numBytes, streamingBuffer, maxStaleness, labels, description
```

| Resultado | Qué significa | Qué cambia en la guía |
|---|---|---|
| `tiene_pk = false` | Tabla **append-only**: cada cambio del origen es una fila nueva. Es el caso validado en producción el 2026-11-05 | `LLAVE = datastream_metadata.uuid` |
| `tiene_pk = true` y `es_cdc_merge = true` | Tabla **CDC con merge**: BigQuery aplica upserts por PK | `LLAVE` = la PK. **No está validado:** el ensayo de la sección 3 es obligatorio y hay que comprobar que la tabla nueva tenga la misma `PRIMARY KEY ... NOT ENFORCED` |
| `ya_particionada = true` | Ya tiene partición | Cambiarla sigue el mismo procedimiento |
| Hay `labels` o `description` | Metadatos | El `DROP` los pierde: vuelve a aplicarlos en la nueva (sección 6) |

📝 Anota el `max_staleness` del `ddl` en `MAX_STALENESS`.

**Expiraciones por defecto del dataset [OBLIGATORIO].** Una tabla nueva **hereda** la expiración por defecto del dataset. Si no se quita, la tabla de producción se borraría sola días después del cambio de nombre, o perdería sus particiones viejas:
```powershell
$d = bq show --format=json PROYECTO:DATASET | Out-String | ConvertFrom-Json
"defaultTableExpirationMs=$($d.defaultTableExpirationMs)  defaultPartitionExpirationMs=$($d.defaultPartitionExpirationMs)"
```
```sql
-- Y las opciones actuales de la tabla (expiration_timestamp, partition_expiration_days, labels, description)
SELECT option_name, option_value FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLE_OPTIONS` WHERE table_name = 'TABLA';
```
Si cualquiera de los dos valores del dataset tiene algo, el paso 1b quita la expiración heredada. Comprobado el 2026-11-05 en `tmp`, que tiene 5 días por defecto: la tabla nueva los heredó y `ALTER TABLE ... SET OPTIONS (expiration_timestamp = NULL, partition_expiration_days = NULL)` los quitó.

### 2.2 Elegir partición y cluster
```sql
-- Cambia COL_PART por la columna candidata
SELECT COUNT(*) AS filas,
       COUNTIF(COL_PART IS NULL) AS nulos,
       MIN(COL_PART) AS minimo, MAX(COL_PART) AS maximo,
       COUNT(DISTINCT TIMESTAMP_TRUNC(TIMESTAMP(COL_PART), DAY))   AS dias,
       COUNT(DISTINCT TIMESTAMP_TRUNC(TIMESTAMP(COL_PART), MONTH)) AS meses
FROM `PROYECTO.DATASET.TABLA`;
```

| Regla | Por qué |
|---|---|
| La columna tiene que ser `DATE`, `DATETIME` o `TIMESTAMP` (o `INT64` si se usa partición por rango) | BigQuery no particiona por `STRING`, `JSON`, `ARRAY` ni campos de `STRUCT` |
| Elige la columna **por la que filtran las consultas reales**, que no cambie y que no sea nula | Si no se filtra por ella, la partición no sirve. Los nulos van a `__NULL__` |
| **Nunca** `datastream_metadata.source_timestamp` | Es un campo de `STRUCT` (no se puede usar) y además filtrar por él no poda nada: medido el 2026-11-05, lee más que no filtrar |
| `meses` o `dias` tiene que dar **menos de 4.000** particiones | BigQuery permite hasta 4.000 particiones por consulta y 10.000 por tabla. Con muchos días, usa `MONTH` |
| Evita particiones diminutas | Con ~2 MB por día conviene `MONTH` (en `broker_activity` fueron ~77 MB por mes) |
| Cluster: hasta 4 columnas de tipo `INT64`, `STRING`, `DATE`, `TIMESTAMP`, `DATETIME`, `BOOL`, `NUMERIC` o `GEOGRAPHY`. Ordénalas de la que más se filtra a la que menos | Con `created_at` primero, filtrar un día lee un 70 % menos que el mes completo. Una segunda columna casi única no aporta |
| En tablas CDC con PK: incluye la PK en el cluster | Datastream, por defecto, clusteriza por la PK para aplicar los upserts |

### 2.3 Llave de deduplicación y línea base de duplicados
```sql
-- Append-only (LLAVE = datastream_metadata.uuid). En tablas con PK, cambia la LLAVE por las columnas de la PK.
SELECT COUNT(*) AS filas, COUNT(DISTINCT LLAVE) AS llaves, COUNT(*) - COUNT(DISTINCT LLAVE) AS repetidas
FROM `PROYECTO.DATASET.TABLA`;
```
**No deduplicues por el `id` de negocio** en tablas append-only: borrarías la historia de actualizaciones (en `broker_activity` había 920 ids con varias versiones legítimas).

### 2.4 Accesos [OBLIGATORIO]
```powershell
.\scripts\verificar_permisos.ps1 -Fase antes -Proyecto PROYECTO -Dataset DATASET -Tabla TABLA
bq get-iam-policy --format=prettyjson PROYECTO:DATASET.TABLA
```
- Si la tabla **tiene permisos de tabla** (`bindings`), el `DROP` del paso 9 **los borra**. Hay dos formas de resolverlo con el admin:
  - **Recomendada (no hace falta el admin en la ventana):** días antes, el admin da el mismo acceso como **`READER` en el dataset con condición** `resource.name == "projects/PROYECTO/datasets/DATASET/tables/TABLA"`. Esa condición va por **nombre**, así que sobrevive al cambio. Así se resolvió el 2026-11-05.
  - Alternativa: el admin corre el `GRANT` sobre `TABLA` justo después del paso 9. En ese caso tiene que estar disponible durante la ventana.
- Los accesos del dataset no cambian.

### 2.5 Dependencias que el `DROP` puede romper [OBLIGATORIO]
```sql
-- Vistas materializadas, vistas y snapshots del dataset que nombran la tabla
SELECT table_name, table_type FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLES`
WHERE table_type IN ('MATERIALIZED VIEW', 'VIEW', 'SNAPSHOT') AND REGEXP_CONTAINS(ddl, r'TABLA');

-- Políticas de acceso por fila (requiere bigquery.rowAccessPolicies.list: si da "Access Denied", pídeselo al admin, error E21)
SELECT * FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.ROW_ACCESS_POLICIES` WHERE table_name = 'TABLA';
```
```powershell
# Policy tags (seguridad por columna): busca "policyTags" en el esquema
bq show --schema --format=prettyjson PROYECTO:DATASET.TABLA | Select-String policyTags
```

| Si aparece | Qué hacer |
|---|---|
| **Vista materializada** sobre la tabla | Después del cambio, recrearla (`CREATE OR REPLACE MATERIALIZED VIEW ...` con su DDL), porque puede quedar inválida |
| Vista normal | No hace nada: resuelve por nombre |
| **Política por fila** | `RENAME` no está permitido y `LIKE` no la copia: hay que recrearla en la nueva. **Ensayo obligatorio** |
| **Policy tags** | Comprueba que la tabla nueva los tenga (paso 1b). Si no, aplícalos con `bq update --schema` |
| Snapshots o clones de la tabla | Siguen existiendo, pero apuntan a la tabla vieja |

### 2.6 Stream y origen [OBLIGATORIO]
```powershell
gcloud.cmd datastream streams describe STREAM --location=REGION --project=PROYECTO --format="json(state,errors,ruleSets,backfillAll,backfillNone,destinationConfig,sourceConfig.sourceConnectionProfile)"
gcloud.cmd datastream objects list --stream=STREAM --location=REGION --project=PROYECTO --format="table(display_name,backfill_job_state,last_backfill_job_start_time)"
```
- El stream tiene que estar `RUNNING`, sin errores y **sin objetos en `ACTIVE` ni `PENDING`** (no se hace la ventana con un backfill corriendo).
- Cuenta **cuántas tablas** tiene el stream: la pausa las congela todas.
- **Riesgo de la pausa según el origen:**

| Origen | Qué pasa durante la pausa | Qué confirmar con el DBA |
|---|---|---|
| MySQL | Datastream retoma desde la posición del binlog | Que la retención del binlog sea mayor que la pausa. En `habi-prod-co`, una pausa de 12 h se recuperó sin pérdidas |
| PostgreSQL | El slot de replicación **retiene WAL en el origen**: el disco crece | Espacio para el WAL de la pausa. Pausas cortas |
| Oracle / SQL Server | Retoma desde los logs o tablas de CDC | Retención de los logs o del CDC |

### 2.7 Ventana de recuperación
```powershell
(bq show --format=json PROYECTO:DATASET | Out-String | ConvertFrom-Json).maxTimeTravelHours   # time travel; en co_habi_brokers era 168 h
```
Si es menor que 48 h, la única red de seguridad es el respaldo del paso 9 (B1).

### 2.8 Permisos de quien ejecuta [OBLIGATORIO]
```powershell
$tok = gcloud.cmd auth print-access-token
$perms = 'bigquery.tables.create','bigquery.tables.update','bigquery.tables.updateData','bigquery.tables.getData','bigquery.tables.delete','bigquery.tables.getIamPolicy','bigquery.jobs.create','datastream.streams.get','datastream.streams.update'
foreach ($p in $perms) {
  $r = Invoke-RestMethod -Method Post -Uri "https://cloudresourcemanager.googleapis.com/v1/projects/PROYECTO:testIamPermissions" -Headers @{Authorization="Bearer $tok"} -ContentType 'application/json' -Body ('{"permissions":["' + $p + '"]}')
  "{0,-34} {1}" -f $p, $(if ($r.permissions) {'SI'} else {'NO'})
}
```
Todos tienen que dar `SI`. `bigquery.tables.setIamPolicy` no hace falta: los permisos los gestiona el admin. Si alguno falta y el acceso viene por el dataset y no por el proyecto, comprueba los accesos del dataset con `bq show --format=prettyjson PROYECTO:DATASET`.

### 2.9 Consumidores
Haz una lista de quién lee la tabla (jobs de dbt, procesos de otros proyectos, usuarios) para avisarles y para revisarlos en la sección 8. Los que leen con permisos de tabla son los que se ven afectados en el paso 10.

---

## 3. [OBLIGATORIO si la tabla no es append-only o no viene de MySQL] Ensayo en `tmp`

El procedimiento está **validado en producción solo para una tabla append-only (sin PK) que viene de MySQL**. Para cualquier otro caso (PK con merge, PostgreSQL, Oracle, políticas por fila, vistas materializadas), **ensáyalo antes** con un stream de prueba:

> El módulo de `terraform/` solo soporta **origen MySQL** (`mysql_source_config`). Para PostgreSQL u Oracle hay que adaptarlo (`postgresql_source_config`, `oracle_source_config` en el recurso `google_datastream_stream`) o crear el stream de prueba desde la consola de Datastream con el mismo perfil de origen.

1. Copia `terraform/envs/prueba` a una carpeta nueva. Copia `terraform.tfvars.example` a `terraform.tfvars` y cambia `stream_id`, los perfiles, `mysql_tables` y `table_rules` (ver `terraform/README.md`).
2. Fase 1, `terraform apply` con `desired_state = "NOT_STARTED"`. Fase 2, `RUNNING` con `backfill = "none"`.
3. Repite **en `tmp`** los pasos 1 a 13 de esta guía sobre la tabla del stream de prueba.
4. Criterios para seguir adelante:
   - Datastream sigue escribiendo en la tabla renombrada (misma `creation_time`, datos posteriores a la reanudación).
   - 0 llaves repetidas.
   - 0 filas faltantes contra producción en la ventana.
   - No se dispara un backfill.
   - Sin errores en el stream.
5. Cierra el entorno de prueba: `terraform destroy` y `DROP TABLE` en `tmp`.

---

## 4. [OBLIGATORIO] Aprobaciones y avisos

- [ ] El **equipo dueño** del proyecto y del stream aprueba la ventana. El stream se pausa, así que **todas sus tablas se congelan**.
- [ ] El **admin** acepta la parte de permisos (2.4) y, si no se hace días antes, está disponible en la ventana.
- [ ] El **DBA** confirma la retención del origen (2.6).
- [ ] Los **consumidores** (2.9) están avisados de la hora.
- [ ] Quien ejecuta tiene todos los permisos de 2.8.
- [ ] Hora fuera de horario (después de las 20:00 en Bogotá, o el fin de semana). Si se aprueba en horario, dejarlo registrado.

---

## 5. [OBLIGATORIO] Días antes

### Paso 1: crear la tabla nueva vacía
```sql
CREATE TABLE `PROYECTO.DATASET.TABLA_nueva`
LIKE `PROYECTO.DATASET.TABLA`
PARTITION BY TIMESTAMP_TRUNC(COL_PART, GRAN)     -- si COL_PART es DATE: DATE_TRUNC(COL_PART, GRAN); DATETIME: DATETIME_TRUNC
CLUSTER BY CLUSTER
OPTIONS (max_staleness = MAX_STALENESS);
```

### Paso 1b: verificar
```sql
-- Las dos filas tienen que tener exactamente el mismo texto en "columnas"
SELECT table_name, STRING_AGG(CONCAT(field_path, ':', data_type), ', ' ORDER BY field_path) AS columnas
FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS`
WHERE table_name IN ('TABLA', 'TABLA_nueva') GROUP BY table_name;

-- PARTITION BY, CLUSTER BY, max_staleness y, si la original la tiene, PRIMARY KEY ... NOT ENFORCED
SELECT table_name, ddl FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLES`
WHERE table_name IN ('TABLA', 'TABLA_nueva');
```
Si a la nueva le falta la PK:
```sql
ALTER TABLE `PROYECTO.DATASET.TABLA_nueva` ADD PRIMARY KEY (col1, col2) NOT ENFORCED;
```

**Expiraciones heredadas [OBLIGATORIO].** La nueva **no** puede tener `expiration_timestamp` ni `partition_expiration_days`, salvo que la original los tuviera:
```sql
SELECT option_name, option_value FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLE_OPTIONS`
WHERE table_name = 'TABLA_nueva' AND option_name IN ('expiration_timestamp', 'partition_expiration_days');
-- Si devuelve algo (expiración heredada del dataset):
ALTER TABLE `PROYECTO.DATASET.TABLA_nueva` SET OPTIONS (expiration_timestamp = NULL, partition_expiration_days = NULL);
```
🛑 Si no se quita, **la tabla de producción se borra sola** días después del cambio (error E23).

### Paso 2: accesos
```powershell
.\scripts\verificar_permisos.ps1 -Fase antes -Proyecto PROYECTO -Dataset DATASET -Tabla TABLA
```
Si el admin aplicó el acceso condicionado por nombre (2.4), ejecuta esto y comprueba que dé `OK` en todo:
```powershell
.\scripts\verificar_permisos.ps1 -Fase despues -Proyecto PROYECTO -Dataset DATASET -Tabla TABLA
```

---

## 5b. Varias tablas del mismo stream

Si vas a particionar **varias tablas que escribe el mismo stream**, hazlas en **una sola ventana**. Cada pausa congela todas las tablas del stream, así que conviene pausar una sola vez:

1. Haz el análisis (sección 2) y los pasos 1, 1b y 2 **para cada tabla**, con su propia hoja de parámetros.
2. En la ventana: arranque y **paso 3 (pausar) una sola vez**.
3. Para cada tabla, en orden, los pasos **4 a 10**. Termina una antes de empezar la siguiente, y llena el registro de cada una.
4. **Paso 11 (reanudar) una sola vez**, al final. Antes de reanudar, confirma con `bq show` que **todas** las tablas existen.
5. Pasos 12 a 14 para cada tabla.

Si una tabla falla en un punto de corte, vacía su `TABLA_nueva`, déjala como estaba y sigue con las demás o reanuda. Las que ya terminaron el paso 9 quedan bien.

Con muchas tablas grandes, la pausa se alarga: los pasos 7 y 8 se suman tabla por tabla. Es mejor partirlas en varias ventanas que pasar de unas 2 horas de pausa sin el visto bueno del DBA (sección 2.6).

---

## 6. Mapa de la ventana

| Paso | Qué | Stream |
|---|---|---|
| Arranque | Comprobaciones, respaldo de la configuración, foto de accesos, repetir el paso 1b | ▶️ RUNNING |
| **3** | **⏸️ PAUSAR** | ⏸️ → PAUSED |
| 4 | Esperar a que no quede nada en el buffer y el conteo sea estable | ⏸️ |
| 5–6 | Línea base y comprobar que la nueva está vacía | ⏸️ |
| 7–8 | Copiar y validar la huella | ⏸️ |
| **9** | **Respaldo con `COPY`, `DROP` de la original y `RENAME` de la nueva** | ⏸️ |
| 10 | Verificar accesos | ⏸️ |
| **11** | **▶️ REANUDAR** | ▶️ → RUNNING |
| 12 | Expiración del respaldo (solo del respaldo) y metadatos | ▶️ |

Tiempo real del 2026-11-05: pausa a las 16:27 y reanudación a las 17:26, con unos 25 minutos perdidos por el error de `RENAME`. Sin ese error, son unos 30 minutos.

---

## 7. [OBLIGATORIO] La ventana

### Arranque
```powershell
(Get-Date).ToString('dddd HH:mm')
gcloud.cmd datastream streams describe STREAM --location=REGION --project=PROYECTO --format="json(state,errors)"
gcloud.cmd datastream streams describe STREAM --location=REGION --project=PROYECTO --format=json | Out-File -Encoding utf8 STREAM_antes_AAAAMMDD.json
.\scripts\verificar_permisos.ps1 -Fase antes -Proyecto PROYECTO -Dataset DATASET -Tabla TABLA -Sobrescribir
bq ls --max_results=1000 PROYECTO:DATASET | Select-String 'TABLA'   # que no exista ya un TABLA_respaldo_AAAAMMDD
```
Repite el **paso 1b**: si el origen agregó una columna desde que creaste la nueva, el esquema ya no coincide. En ese caso, haz `DROP` de la nueva y vuelve al paso 1.

🛑 El stream tiene que estar `RUNNING` y sin errores.

### Paso 3: ⏸️ PAUSAR el stream
```powershell
# Revisa el nombre antes de dar Enter
gcloud.cmd datastream streams update STREAM --location=REGION --project=PROYECTO --state=PAUSED --update-mask=state

do {
  $s = gcloud.cmd datastream streams describe STREAM --location=REGION --project=PROYECTO --format="value(state)"
  "$((Get-Date).ToString('HH:mm:ss'))  $s"
  if ($s -ne 'PAUSED') { Start-Sleep -Seconds 30 }
} while ($s -ne 'PAUSED')
```
📝 Anota la hora. Pasa por `DRAINING` (unos 5 minutos con 46 tablas). 🛑 No sigas hasta que diga `PAUSED`.

### Paso 4: esperar a que no quede nada en tránsito
```powershell
# Repite hasta que no imprima nada (en 2026-11-05 tardó ~6 min después de PAUSED)
bq show --format=prettyjson PROYECTO:DATASET.TABLA | Select-String streamingBuffer
```
```sql
-- Dos veces, con 3 minutos de diferencia: tiene que dar exactamente lo mismo
SELECT COUNT(*) AS filas, MAX(datastream_metadata.source_timestamp) AS max_ts FROM `PROYECTO.DATASET.TABLA`;
```

### Paso 5: línea base
```sql
SELECT COUNT(*) AS filas, COUNT(DISTINCT LLAVE) AS llaves, COUNT(*) - COUNT(DISTINCT LLAVE) AS repetidas
FROM `PROYECTO.DATASET.TABLA`;
```
📝 Anota los números.

### Paso 6: la nueva tiene que estar vacía
```sql
SELECT COUNT(*) AS filas_nueva FROM `PROYECTO.DATASET.TABLA_nueva`;
-- Si no da 0:  TRUNCATE TABLE `PROYECTO.DATASET.TABLA_nueva`;
```

### Paso 7: copiar (una sola vez)
```sql
INSERT INTO `PROYECTO.DATASET.TABLA_nueva`
SELECT * FROM `PROYECTO.DATASET.TABLA`
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (PARTITION BY LLAVE ORDER BY datastream_metadata.source_timestamp DESC) = 1;
```
Con `GRAN = DAY` y más de 4.000 días, este `INSERT` falla por el límite de particiones (error E10). En ese caso, cópialo en tramos de fechas.

**Costo y tiempo.** El paso 7 lee la tabla completa una vez. El paso 8 la lee dos veces más y la nueva una vez. B1 (`COPY`) no factura bytes. Para `broker_activity` (5,6 GB) fueron unos 17 GB facturados y pocos minutos en total. Para tablas grandes (cientos de GB o más), estímalo antes con un dry-run de los pasos 7 y 8, porque alarga la pausa.

### Paso 8: validar con la huella
```sql
WITH o AS (
  SELECT * FROM `PROYECTO.DATASET.TABLA` WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY LLAVE ORDER BY datastream_metadata.source_timestamp DESC) = 1
)
SELECT 'original' AS tabla, COUNT(*) AS filas, COUNT(DISTINCT LLAVE) AS llaves,
       BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(o))) AS huella FROM o
UNION ALL
SELECT 'nueva', COUNT(*), COUNT(DISTINCT LLAVE), BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(n)))
FROM `PROYECTO.DATASET.TABLA_nueva` AS n;
```
🛑 **Las dos filas tienen que ser idénticas, y `filas = llaves`.** Si no, mira el error E7 y no sigas.

### Paso 9: respaldo, `DROP` y `RENAME`
**B1. Respaldo:**
```sql
CREATE TABLE `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD` COPY `PROYECTO.DATASET.TABLA`;
```
**B1b. Validar el respaldo contra la original.** Se compara contra la original tal cual, sin deduplicar, porque en este momento las dos existen:
```sql
SELECT 'original' AS tabla, COUNT(*) AS filas, BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t))) AS huella
FROM `PROYECTO.DATASET.TABLA` AS t
UNION ALL
SELECT 'respaldo', COUNT(*), BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t)))
FROM `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD` AS t;
```
🛑 Las dos filas tienen que ser **idénticas**. Si no, **no sigas**.

Si la original no tenía repetidos (paso 5), esta huella también coincide con la del paso 8. Si tenía repetidos, no coincide, y está bien: la nueva quedó deduplicada a propósito.

**B2 y B3. Borrar la original y renombrar la nueva**, las dos sentencias juntas:
```sql
DROP TABLE `PROYECTO.DATASET.TABLA`;
ALTER TABLE `PROYECTO.DATASET.TABLA_nueva` RENAME TO TABLA;
```
🛑 Si B3 falla: **NO reanudes**. Mira el error E3.

**B4. Comprobar:**
```sql
SELECT table_name, creation_time, REGEXP_CONTAINS(ddl, r'PARTITION BY') AS particionada
FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLES` WHERE table_name LIKE 'TABLA%';
```
✅ Tiene que verse así:
- `TABLA`, con la `creation_time` del paso 1 y particionada;
- `TABLA_respaldo_AAAAMMDD`, sin partición;
- ninguna `TABLA_nueva`.

⚠️ **No corras el comando de recuperación si B3 funcionó.** Si lo haces, aparece el error E2 (no causa daño, pero confunde).

### Paso 10: accesos
```powershell
.\scripts\verificar_permisos.ps1 -Fase despues -Proyecto PROYECTO -Dataset DATASET -Tabla TABLA
```
- `OK` en todo: sigue.
- **FALTA**: pásale la salida al admin (2.4). **Puedes reanudar igual** (paso 11): Datastream escribe con su propia cuenta de servicio a nivel de proyecto, no con permisos de tabla. Solo los lectores con permiso de tabla esperan el acceso.

### Paso 11: ▶️ REANUDAR
```powershell
# 🛑 Primero: TABLA tiene que existir. NUNCA reanudes si no existe (Datastream la recrearía sin partición)
bq show PROYECTO:DATASET.TABLA

gcloud.cmd datastream streams update STREAM --location=REGION --project=PROYECTO --state=RUNNING --update-mask=state
do {
  $s = gcloud.cmd datastream streams describe STREAM --location=REGION --project=PROYECTO --format="value(state)"
  "$((Get-Date).ToString('HH:mm:ss'))  $s"
  if ($s -ne 'RUNNING') { Start-Sleep -Seconds 30 }
} while ($s -ne 'RUNNING')
gcloud.cmd datastream streams describe STREAM --location=REGION --project=PROYECTO --format="json(state,errors)"
```
```sql
SELECT CURRENT_TIMESTAMP() AS hora_reanudacion;   -- 📝 anótala
```

### Paso 12: expiración del respaldo y metadatos
```sql
ALTER TABLE `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD`
SET OPTIONS (expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY));

-- Solo si la original tenía descripción o labels (2.1)
-- ALTER TABLE `PROYECTO.DATASET.TABLA` SET OPTIONS (description = '...', labels = [('clave', 'valor')]);
```
Si había vistas materializadas (2.5), recréalas ahora.

---

## 8. [OBLIGATORIO] Después de la ventana

### Paso 13: a los 15 minutos y a las 2 horas
```powershell
gcloud.cmd datastream streams describe STREAM --location=REGION --project=PROYECTO --format="json(state,errors)"
# Tiene que dar 0
gcloud.cmd datastream objects list --stream=STREAM --location=REGION --project=PROYECTO --format="table(display_name,backfill_job_state)" | Select-String -Pattern '\bACTIVE\b|\bPENDING\b' | Measure-Object | Select-Object -ExpandProperty Count
.\scripts\verificar_permisos.ps1 -Fase despues -Proyecto PROYECTO -Dataset DATASET -Tabla TABLA
```
```sql
SELECT 'TABLA' AS tabla, COUNT(*) AS filas, COUNT(*) - COUNT(DISTINCT LLAVE) AS repetidas,
       TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp)) AS ultimo_cambio,
       (SELECT creation_time FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'TABLA') AS creation_time
FROM `PROYECTO.DATASET.TABLA`
UNION ALL
SELECT 'respaldo', COUNT(*), COUNT(*) - COUNT(DISTINCT LLAVE),
       TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp)), NULL
FROM `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD`;
```
✅ Está bien si:
- `repetidas = 0`;
- `ultimo_cambio` es posterior a `hora_reanudacion`;
- `creation_time` es la del paso 1;
- el respaldo tiene las filas del paso 5;
- no hay backfill;
- los accesos dan `OK`.

Si hay repetidos a las 2 horas, mira el error E12.

### Paso 14: al día siguiente
```sql
-- T1. Configuración
SELECT column_name, is_partitioning_column, clustering_ordinal_position
FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'TABLA' AND (is_partitioning_column = 'YES' OR clustering_ordinal_position IS NOT NULL);

-- T2. Cada fila está en su partición: meses_que_cuadran = meses (o meses - 1 por el buffer); nulos fuera de lo esperado = 0
WITH por_part AS (SELECT FORMAT_TIMESTAMP('%Y%m', TIMESTAMP(COL_PART)) AS partition_id, COUNT(*) AS n FROM `PROYECTO.DATASET.TABLA` GROUP BY 1),
     meta AS (SELECT partition_id, total_rows FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.PARTITIONS` WHERE table_name = 'TABLA')
SELECT COUNT(*) AS meses, COUNTIF(m.total_rows = p.n) AS meses_que_cuadran,
       (SELECT IFNULL(SUM(total_rows), 0) FROM meta WHERE partition_id = '__NULL__') AS filas_nulas
FROM por_part p LEFT JOIN meta m USING (partition_id);
-- (con GRAN = DAY, usa '%Y%m%d'; con HOUR, '%Y%m%d%H')

-- T3. Poda (dry-run, sin ejecutar): tiene que procesar mucho menos que antes
SELECT * FROM `PROYECTO.DATASET.TABLA` WHERE COL_PART >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY);

-- T4. Mismo contenido que el respaldo, salvo el periodo en curso
SELECT FORMAT_TIMESTAMP('%Y-%m', TIMESTAMP(COL_PART)) AS mes, COUNT(*) AS filas FROM `PROYECTO.DATASET.TABLA` GROUP BY 1
EXCEPT DISTINCT
SELECT FORMAT_TIMESTAMP('%Y-%m', TIMESTAMP(COL_PART)), COUNT(*) FROM `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD` GROUP BY 1;
```
```sql
-- T6. La tabla de producción no tiene expiración (E23); solo debe aparecer require_partition_filter
SELECT option_name, option_value FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLE_OPTIONS` WHERE table_name = 'TABLA';
```
T5, consumidores:
- Los jobs que leen la tabla, en verde.
- Pídele a cada lector con permiso propio que corra un `SELECT COUNT(*)`.

### Paso 15: aprovechar la partición en los consumidores
La partición solo ahorra si las consultas filtran por `COL_PART`. Revisa los modelos y procesos que leen la tabla:

| Filtro | ¿Poda? (medido en `broker_activity`) |
|---|---|
| `COL_PART >= TIMESTAMP('2026-10-01')` (constante) | ✅ |
| `COL_PART >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)` | ✅ |
| `COL_PART >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)` | ✅ |
| `DATE(COL_PART, 'America/Bogota') >= '2026-10-01'` | ✅ |
| `COL_PART >= (SELECT ... FROM otra_tabla)` | ✅ En la ejecución, pero el dry-run no lo muestra, y la subconsulta se factura aparte |
| `datastream_metadata.source_timestamp >= ...` | ❌ **No poda:** lee más que no filtrar |

En dbt, un modelo incremental sobre esta fuente debe filtrar por `COL_PART`, no por la marca de tiempo de CDC. Por ejemplo:
```sql
{% if is_incremental() %}
WHERE COL_PART >= TIMESTAMP_TRUNC(TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY), MONTH)
{% endif %}
```
Mide antes y después con dry-run, o con `total_bytes_processed` en `INFORMATION_SCHEMA.JOBS`.

### Paso 16: versionar la ejecución
Guarda el registro (sección 12) y lo que salió distinto en `ejemplos/<TABLA>_<AAAAMMDD>/` de este repo. Si apareció un error que no está en la sección 11, agrégalo con su causa y su solución. Cambia los correos personales por roles, y no subas estados de Terraform, fotos de permisos ni configuraciones exportadas.

---

## 9. [OPCIONAL] Regla de partición en el stream

Hace que, si Datastream algún día **recrea** la tabla, la cree particionada. No cambia nada existente. Se ensayó agregándola con el stream corriendo: 24 s, sin backfill y sin recrear la tabla.
```powershell
# rule_sets_TABLA.json
# [{"objectFilter":{"sourceObjectIdentifier":{"mysqlIdentifier":{"database":"BASE_ORIGEN","table":"TABLA_ORIGEN"}}},
#   "customizationRules":[{"bigqueryPartitioning":{"timeUnitPartition":{"column":"COL_PART","partitioningTimeGranularity":"PARTITIONING_TIME_GRANULARITY_GRAN"}}},
#                         {"bigqueryClustering":{"columns":["col1","col2"]}}]}]
# (PostgreSQL: postgresqlIdentifier con schema/table; Oracle: oracleIdentifier)

gcloud.cmd datastream streams update STREAM --location=REGION --project=PROYECTO --rule-sets=rule_sets_TABLA.json --update-mask=rule_sets --validate-only
gcloud.cmd datastream streams update STREAM --location=REGION --project=PROYECTO --rule-sets=rule_sets_TABLA.json --update-mask=rule_sets
```
⚠️ `--rule-sets` **reemplaza todas** las reglas del stream. Si ya tenía reglas para otras tablas, el JSON tiene que incluirlas todas: revisa `ruleSets` en `STREAM_antes_AAAAMMDD.json`.

---

## 10. Rollback (si algo sale mal después de reanudar)

1. ⏸️ Pausar el stream (paso 3) y esperar (paso 4).
2. Pasar al respaldo lo que llegó después del cambio:
   ```sql
   INSERT INTO `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD`
   SELECT * FROM `PROYECTO.DATASET.TABLA` AS n
   WHERE NOT EXISTS (SELECT 1 FROM `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD` AS r WHERE r.LLAVE = n.LLAVE)
   QUALIFY ROW_NUMBER() OVER (PARTITION BY n.LLAVE ORDER BY n.datastream_metadata.source_timestamp DESC) = 1;
   ```
3. Quitarle la expiración al respaldo:
   ```sql
   ALTER TABLE `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD` SET OPTIONS (expiration_timestamp = NULL);
   ```
4. Volver con la misma técnica del paso 9. La tabla particionada recibió streaming, así que **no se puede renombrar**:
   ```sql
   CREATE TABLE `PROYECTO.DATASET.TABLA_fallida_AAAAMMDD` COPY `PROYECTO.DATASET.TABLA`;
   DROP TABLE `PROYECTO.DATASET.TABLA`;
   ALTER TABLE `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD` RENAME TO TABLA;
   ```
5. Verificar accesos (paso 10) y ▶️ reanudar (paso 11).

---

## 11. Catálogo de errores y cómo resolverlos

### BigQuery

| # | Error o síntoma | Causa | Qué hacer |
|---|---|---|---|
| **E1** | `Cannot rename PROYECTO:DATASET.TABLA because it has streaming data` | La tabla recibió streaming hace poco, aunque el buffer esté vacío. **Pasó en producción el 2026-11-05** | No hay que esperar. Usa el paso 9 (respaldo con `COPY`, `DROP` y `RENAME` de la nueva). La nueva nunca recibió streaming y sí se puede renombrar. No se cambió nada, así que todo sigue igual |
| **E2** | `Cannot replace a table with a different partitioning spec. Instead, DROP the table, and then recreate it` | Se intentó crear o copiar sobre un nombre que **ya existe** con otra partición. Pasó el 2026-11-05 al correr el comando de recuperación **después** de que B3 había funcionado | Revisa con B4. Si `TABLA` ya es la particionada, **no hay nada que corregir**: el comando falló y no cambió nada. Si de verdad hay que reemplazarla, primero `DROP` |
| **E3** | B3 falla después de un B2 exitoso: `TABLA` no existe | Error en el `RENAME` (nombre mal escrito, `TABLA_nueva` inexistente, permisos) | 🛑 **No reanudes.** Corrige y repite B3. Si no se puede: `CREATE TABLE \`PROYECTO.DATASET.TABLA\` COPY \`PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD\`` y reanuda. Segunda red: time travel (E4) |
| **E4** | Hay que recuperar una tabla borrada | — | `bq cp -n PROYECTO:DATASET.TABLA@<ms_antes_del_DROP> PROYECTO:DATASET.TABLA_recuperada`. Funciona aunque ya exista otra tabla con ese nombre (probado el 2026-11-05). Solo dentro de `maxTimeTravelHours` (2.7) |
| **E5** | `Already exists: Table PROYECTO:DATASET.TABLA_nueva` (paso 1) o `TABLA_respaldo_AAAAMMDD` (B1) | Queda de un intento anterior | Revisa qué es con `bq show`. La nueva: si está vacía y tiene el esquema correcto, úsala; si no, `DROP` y créala otra vez. El respaldo: usa otro sufijo (`AAAAMMDD_2`) |
| **E6** | `Not found: Table ...` en el paso 7 u 8 | Nombre mal escrito o `TABLA_nueva` no creada | Revisa la hoja de parámetros y vuelve al paso 1 |
| **E7** | En el paso 8, las huellas o los conteos no coinciden | El stream no estaba del todo pausado, el buffer no se había vaciado o el esquema no coincide | `TRUNCATE TABLE ...TABLA_nueva`. Vuelve al paso 4 (confirma `PAUSED` y que no haya buffer) y repite los pasos 7 y 8. Si sigue igual, repite el paso 1b (esquema). **Nunca hagas el paso 9 con huellas distintas** |
| **E8** | `INSERT` del paso 7: `Inserted row has wrong column count` o `Column ... has type ... which differs` | El origen agregó o cambió una columna después del paso 1 | `DROP` de la nueva, vuelve al paso 1 y repite el paso 1b |
| **E9** | `UPDATE or DELETE statement over table ... would affect rows in the streaming buffer` | DML sobre filas que todavía no se consolidan | Espera 30 a 90 minutos y repite |
| **E10** | `Too many partitions produced by query, allowed 4000` | El `INSERT` toca más de 4.000 particiones (por ejemplo, con `DAY` sobre más de 11 años) | Copia en tramos: `INSERT ... WHERE COL_PART >= X AND COL_PART < Y`, uno por cada bloque de menos de 4.000 particiones. Valida con la huella completa al final |
| **E11** | Una tabla con más de 10.000 particiones | Límite por tabla | Usa una granularidad más gruesa (`MONTH` o `YEAR`) |
| **E12** | Paso 13: `repetidas > 0` | Reentrega de eventos al reanudar (*at-least-once*) | A partir de las 2 h: `BEGIN TRANSACTION; CREATE TEMP TABLE r AS SELECT * FROM T WHERE COL_PART >= <inicio del periodo> AND LLAVE IN (SELECT LLAVE FROM T WHERE ... GROUP BY 1 HAVING COUNT(*) > 1) QUALIFY ROW_NUMBER() OVER (PARTITION BY LLAVE ORDER BY datastream_metadata.source_timestamp) = 1; DELETE FROM T WHERE COL_PART >= <inicio> AND LLAVE IN (SELECT LLAVE FROM r); INSERT INTO T SELECT * FROM r; COMMIT TRANSACTION;`. Si falla, mira E9 |
| **E13** | `Type ARRAY is not supported in INTERSECT DISTINCT or EXCEPT DISTINCT operation` | Comparar tablas con columnas `ARRAY` | Compara `TO_JSON_STRING(t)` en vez de `SELECT *` |
| **E14** | `Cannot query over table ... without a filter over column(s) ... that can be used for partition elimination` | La tabla tiene `require_partition_filter = true` | Agrega un filtro por `COL_PART`. Esta guía no activa esa opción |
| **E15** | El dry-run de T3 lee igual que antes | El filtro no es sobre `COL_PART`, o usa `datastream_metadata.source_timestamp` | Filtra directamente por `COL_PART`. Sirven `DATE(COL_PART, 'America/Bogota')` y `CURRENT_TIMESTAMP()`; también una subconsulta (en la ejecución, aunque el dry-run no lo muestre) |
| **E16** | `PARTITION BY` rechazado: tipo inválido o campo anidado | `COL_PART` es `STRING`, o es un campo de `STRUCT` | Elige otra columna (2.2). Una `STRING` con fecha no sirve sin crear una columna nueva, y Datastream no la llenaría |
| **E17** | `CLUSTER BY` rechazado | Más de 4 columnas, o de tipo `JSON`, `ARRAY` o `STRUCT` | Hasta 4 columnas de tipos válidos (2.2) |
| **E18** | La nueva no tiene la `PRIMARY KEY`, policy tags o descripción | `LIKE` no copió todo | Paso 1b: `ALTER TABLE ... ADD PRIMARY KEY (...) NOT ENFORCED`, `bq update --schema` para los policy tags y `ALTER TABLE ... SET OPTIONS` para la descripción y los labels |
| **E19** | Una vista materializada falla después del cambio | Dependía de la tabla borrada | Recréala con su DDL (2.5) |
| **E20** | `Access Denied: ... bigquery.tables.setIamPolicy` | El `GRANT` no lo puede hacer quien ejecuta | Lo hace el admin (2.4) |
| **E21** | `Access Denied: ... INFORMATION_SCHEMA.ROW_ACCESS_POLICIES` (2.5) | Falta `bigquery.rowAccessPolicies.list`. Pasó el 2026-11-05 en `co_habi_brokers` | El admin confirma si la tabla tiene políticas por fila. Si las tiene, el `DROP` las borra y hay que recrearlas en la nueva: ensayo obligatorio (sección 3) |
| **E22** | `Access Denied` en `CREATE TABLE`, `INSERT`, `COPY`, `DROP` o `ALTER TABLE` | Faltan `bigquery.tables.create`, `updateData`, `delete` o `update` sobre el dataset | Revísalo **antes** de la ventana con `testIamPermissions` (sección 2), o pídele al admin que haga esos pasos |
| **E23** | La tabla de producción tiene `expiration_timestamp` después del cambio, o desaparece días después | La nueva heredó la expiración por defecto del dataset (`defaultTableExpirationMs`). Comprobado en `tmp` (5 días) | **Urgente:** `ALTER TABLE \`PROYECTO.DATASET.TABLA\` SET OPTIONS (expiration_timestamp = NULL)`. Si ya se borró: time travel (E4). Evítalo con el paso 1b |
| **E24** | Desaparecen las particiones viejas de la tabla | La nueva heredó `defaultPartitionExpirationMs` del dataset (`partition_expiration_days`) | `ALTER TABLE ... SET OPTIONS (partition_expiration_days = NULL)` y recupera lo borrado desde el respaldo, filtrando por `COL_PART` y deduplicando por `LLAVE`. Evítalo con el paso 1b |
| **E25** | Los pasos 7 u 8 tardan mucho o facturan mucho | Tabla muy grande (lectura completa varias veces) | Estímalo antes con un dry-run (paso 7). Si alarga demasiado la pausa, hazlo en otra ventana o con la tabla sola (sección 5b) |

### Datastream

| # | Error o síntoma | Causa | Qué hacer |
|---|---|---|---|
| **D1** | `update` responde `done: false` | La operación es asíncrona | Normal: espera con los bucles de los pasos 3 y 11 |
| **D2** | Se queda mucho tiempo en `DRAINING` | Está terminando de escribir lo pendiente (con 46 tablas tardó ~5,5 min) | Espera. Revisa `errors` con `describe`. No lo fuerces |
| **D3** | Después de reanudar: `FAILED` o errores en `describe` | La tabla no existe, el esquema cambió o el origen no está disponible | Revisa `errors`. Si `TABLA` no existe, mira E3. Si es el esquema, `ALTER TABLE ... ADD COLUMN` en `TABLA`. Si es el origen (binlog o WAL expirado), habla con el DBA: puede requerir backfill |
| **D4** | Datastream recreó `TABLA` **sin partición** | Se reanudó sin que `TABLA` existiera | Pausa. Repite el procedimiento: los datos nuevos están en la recreada y los viejos en el respaldo. Copia los dos a una nueva particionada, deduplicando por `LLAVE`, y valida con la huella |
| **D5** | Después de reanudar, un objeto en `ACTIVE` o `PENDING` | Se disparó un backfill | Pausa. El backfill deja duplicados exactos (3,6 % en la prueba). Al terminar, limpia por `LLAVE` (E12, pero sobre toda la tabla) |
| **D6** | No llegan datos después de reanudar | Poca actividad en el origen, o `max_staleness` alto (los datos tardan en verse) | Espera hasta el valor de `max_staleness`. Compara contra el origen o contra otro consumidor en la misma ventana |
| **D7** | `--rule-sets` borró reglas de otras tablas | La opción reemplaza todas las reglas | Vuelve a aplicar el JSON con todas las reglas (sección 9) |
| **D8** | `Permission denied` al pausar o reanudar | Falta `datastream.streams.update` | Lo hace alguien con `roles/datastream.admin` |
| **D9** | Origen PostgreSQL: el disco del origen crece durante la pausa | El slot de replicación retiene WAL | Reanuda cuanto antes y coordina con el DBA (2.6) |

### Entorno (PowerShell, gcloud y bq en esta máquina)

| # | Error o síntoma | Qué hacer |
|---|---|---|
| **W1** | `No se puede cargar el archivo ...gcloud.ps1 porque la ejecución de scripts está deshabilitada` | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` y usar `gcloud.cmd` |
| **W2** | `bq` o `gcloud` se cuelgan o dan timeout | `$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'`. Comprueba que exista `...\google-cloud-sdk\platform\bundledpython\Lib\site-packages\sitecustomize.py`; si `gcloud components update` lo borró, hay una copia en `entorno/sitecustomize.py` (ver `entorno/README.md`) |
| **W3** | `can't open file ...\lib\gcloud.py` | Hay un `gcloud components update` en curso. Espera a que termine |
| **W4** | `Illegal input character "\357"` o `Unexpected end of script` al pasar SQL a `bq` | Usa la consola de BigQuery, o pásale a `bq` un archivo UTF-8 **sin BOM**: `cmd /c "bq query ... < archivo.sql"` |
| **W5** | `La referencia de variable no es válida. El carácter ':' ...` | En PowerShell, usa `${variable}:` en vez de `$variable:` |
| **W6** | Un archivo `.ps1` muestra acentos rotos | Guárdalo como UTF-8 **con BOM** (PowerShell 5.1) |
| **W7** | `verificar_permisos.ps1` marca FALTA pero el admin dice que ya dio el acceso | Si lo dio como `READER` en el dataset con condición a la tabla, el script lo reconoce como equivalente. Si dio otro rol o una condición distinta, revísalo con el admin |
| **W8** | Una consulta muestra horas raras | BigQuery usa UTC. Bogotá es UTC − 5. Desde las 19:00 de Bogotá, en UTC ya es el día siguiente |

---

## 12. Registro de la ejecución (llenar)

| Dato | Valor |
|---|---|
| Tabla / stream / fecha | |
| Tipo (append-only / CDC con PK) y `LLAVE` | |
| Partición (`COL_PART`, `GRAN`) y cluster | |
| ¿Ensayo en `tmp` (sección 3)? Resultado | |
| Hora de la pausa / `PAUSED` | |
| Paso 5: filas / llaves | |
| Paso 8: huella (original = nueva) | |
| B1b: huella del respaldo | |
| Paso 1b: ¿la nueva heredó una expiración? ¿Se quitó? | |
| Hora de B2 y B3 | |
| Paso 10: accesos (OK / qué faltó / cómo se resolvió) | |
| Hora de la reanudación / `RUNNING` | |
| Paso 13 (+15 min y +2 h): repetidos, último cambio | |
| T3: bytes antes y después | |
| Errores del catálogo que aparecieron | |
