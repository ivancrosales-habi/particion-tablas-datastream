# Guía de producción: particionar y clusterizar `co_habi_brokers.broker_activity`

| | |
|---|---|
| Sub-issue | #142 (B2), issue padre #110 |
| Tabla | `brokers-main-prod.co_habi_brokers.broker_activity` (Datastream `habi-brokers-co`) |
| Resultado | Partición **mensual por `created_at`** y cluster **`created_at, broker_id`** |
| Versión | 2026-11-05, ensayada completa en `brokers-main-prod.tmp` |
| Responsable | Iván Rosales |

Este archivo reúne todo lo necesario para hacer el cambio en producción. Reemplaza a `PASO_A_PASO.sql`, `PRODUCCION_PASO_A_PASO_v2.sql` y `RUNBOOK_PRODUCCION_POR_ROLES.md`, que contienen lo mismo por partes.

---

## 1. Resumen

**Qué se hace:**
1. Se crea a mano una tabla vacía, igual a la actual pero particionada y con cluster.
2. Con el stream pausado, se copian los datos dentro de BigQuery, una fila por `uuid`.
3. Se guarda un respaldo de la original con `COPY`, se borra la original y la nueva toma su nombre. El respaldo queda 30 días. La original **no se puede renombrar**, porque BigQuery bloquea el `RENAME` de una tabla que recibió streaming hace poco (ver paso 9).
4. Se reanuda el stream.

**Qué NO se hace:**
- Durante la migración no se cambia la configuración del Datastream. Agregarle la regla de partición es un paso opcional y aparte, después (sección 10).
- No se hace backfill desde MySQL, porque en la prueba dejó un 3,6 % de duplicados.
- No se borra la tabla original.

**Por qué:** leer el mes en curso baja de **2,34 GB a ~6 MB** por consulta (−99,7 %), y los últimos 30 días de **1,14 GB a ~28 MB** (−97,6 %).

**Evidencia** (`RESULTADOS_20261105.md`):

| Se probó que… | Resultado |
|---|---|
| Datastream escribe en una tabla particionada creada a mano y con el nombre cambiado | ✅ Con el stream con regla de partición y sin ella, como producción |
| La tabla no se recrea ni pierde la partición al reanudar | ✅ |
| Pausar y reanudar no pierde datos | ✅ 0 faltantes, con pausas de 12 h y de 40 min |
| Pausar y reanudar no duplica datos | ✅ 0 `uuid` repetidos |
| Reanudar no repite el backfill (el stream tiene `backfill_all`) | ✅ |
| La partición poda y el cluster por `created_at` reduce la lectura | ✅ Un día lee un 70 % menos que el mes completo |
| `COPY` y `DROP` de una tabla con streaming activo, y `RENAME` de una tabla sin streaming al nombre recién borrado (opción B) | ✅ Ensayado el 2026-11-05 a las 22:06 UTC; Datastream siguió escribiendo en la tabla renombrada |
| `RENAME` de una tabla con streaming reciente | ❌ **BigQuery lo bloquea** ("has streaming data"). Pasó en producción el 2026-11-05 con 10 min de pausa. En una tabla con 15 h de pausa sí funcionó |

**Duración de la ventana:** entre 30 y 60 minutos con el stream pausado. Durante ese tiempo, **las 46 tablas `co_*` dejan de actualizarse** y después se ponen al día solas.

---

## 2. Roles

| Rol | Qué hace |
|---|---|
| **Iván** | Todo lo técnico. Tiene `tables.create`, `update`, `updateData`, `getData`, `delete` y `getIamPolicy`; `jobs.create`; `datasets.create`; `datastream.streams.update` |
| **Admin** (con `bigquery.tables.setIamPolicy`) | **Todo lo de permisos:** la prueba de la sección 4 (si la quiere hacer) y el `GRANT` de la sección 5, en el momento que corresponda. Iván no tiene ese permiso |
| **Iván, sobre los permisos** | Solo **verificar**, con `verificar_permisos.ps1`, que la tabla termine con los mismos permisos que tenía al inicio |
| **Equipo dueño de `brokers-main-prod`** | Aprueba la ventana |
| **Consumidores** | Reciben el aviso: job `buyers` de dbt Cloud, core `buyers_medalion_co` y proceso MX `buyers-mx-dwh-hour-sa` |

Permisos de tabla que hay que conservar (vigentes al 2026-11-05):
- `roles/bigquery.dataViewer` para `serviceAccount:buyers-mx-dwh-hour-sa@papyrus-master.iam.gserviceaccount.com`
- `roles/bigquery.dataViewer` para `user:usuario.lector@habi.co`

Los demás lectores tienen acceso por el dataset y el cambio no los afecta.

---

## 3. Antes de empezar: convenciones

- Los **SQL** van en la consola de BigQuery, con el proyecto `brokers-main-prod`.
- Los **comandos** van en PowerShell. En cada ventana nueva, corre primero:
  ```powershell
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  $env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'
  ```
- Reemplaza **`AAAAMMDD`** por la fecha de la ventana (por ejemplo `20261110`) en todos los SQL.
- Las horas de BigQuery están en **UTC**. Bogotá es UTC − 5.
- 🛑 marca un **punto de corte**: si la validación no da lo esperado, no sigas y aplica lo que dice.

---

## 4. Permisos: quién los gestiona y cómo verifica Iván

**Los permisos los gestiona el admin, no Iván.** Lo que hace Iván es comprobar, con `verificar_permisos.ps1` (en esta carpeta, solo lectura), que al final `broker_activity` tenga exactamente los mismos permisos que al inicio. El script revisa dos niveles:
1. Los **permisos de la tabla** (hoy, 2 `dataViewer` directos).
2. Los **accesos del dataset** `co_habi_brokers` (38 entradas al 2026-11-05), que es por donde leen los demás.

| Cuándo | Comando | Resultado esperado |
|---|---|---|
| Antes de la ventana (arranque, sección 7) | `.\verificar_permisos.ps1 -Fase antes` | Guarda la foto en `salida_permisos\` |
| Variante A, días antes (paso 2) | `.\verificar_permisos.ps1 -Fase despues -Tabla broker_activity_nueva` | La tabla nueva ya tiene los 2 permisos |
| Después del cambio de nombres (paso 10) | `.\verificar_permisos.ps1 -Fase despues` | Todo `OK`, o la lista de lo que **FALTA** para pasársela al admin |
| +15 min y al día siguiente (pasos 13 y 15) | `.\verificar_permisos.ps1 -Fase despues` | Todo `OK` |

El script sale con código 1 si falta algún permiso. Lo que **SOBRA** se muestra en amarillo, pero no cuenta como falla. Se probó el 2026-11-05 contra la tabla actual (todo OK) y contra otra tabla (detectó lo que faltaba y lo que sobraba).

### 4.1 Prueba opcional para el admin: ¿los permisos sobreviven al cambio de nombre?

La documentación de BigQuery no lo dice, y la respuesta define en qué momento interviene el admin. **La hace el admin** si quiere saberlo antes. Se prueba en un dataset propio y temporal: quien crea el dataset queda como su dueño y puede dar permisos sobre sus tablas.

```sql
CREATE SCHEMA `brokers-main-prod.tmp_ivan_prueba_iam`
OPTIONS (location = 'US', default_table_expiration_days = 1);

CREATE TABLE `brokers-main-prod.tmp_ivan_prueba_iam.t_original` (x INT64);

GRANT `roles/bigquery.dataViewer`
ON TABLE `brokers-main-prod.tmp_ivan_prueba_iam.t_original`
TO "user:usuario.lector@habi.co";
```
```powershell
# Tiene que mostrar el dataViewer
bq get-iam-policy --format=prettyjson brokers-main-prod:tmp_ivan_prueba_iam.t_original
```
```sql
-- El mismo cambio de nombres que se hará en producción
CREATE TABLE `brokers-main-prod.tmp_ivan_prueba_iam.t_nueva` (x INT64);
ALTER TABLE `brokers-main-prod.tmp_ivan_prueba_iam.t_original` RENAME TO t_respaldo;
ALTER TABLE `brokers-main-prod.tmp_ivan_prueba_iam.t_nueva` RENAME TO t_original;
```
```powershell
bq get-iam-policy --format=prettyjson brokers-main-prod:tmp_ivan_prueba_iam.t_respaldo
bq get-iam-policy --format=prettyjson brokers-main-prod:tmp_ivan_prueba_iam.t_original
```
```sql
DROP SCHEMA `brokers-main-prod.tmp_ivan_prueba_iam` CASCADE;
```

| Dónde quedó el permiso | Variante | Qué hace el admin |
|---|---|---|
| En `t_respaldo`: sigue a la tabla | **A** | El `GRANT` sobre `broker_activity_nueva`, **días antes** (sección 5.1). No hace falta en la ventana |
| En `t_original`: sigue al nombre | **C** | Nada. La tabla nueva hereda el permiso al tomar el nombre |
| En ninguna | **B** | El `GRANT` sobre `broker_activity` **en la ventana, justo después del paso 9** (sección 5.2). Tiene que estar disponible |

Si el `GRANT` del paso 0 falla por permisos, el dataset propio no alcanza. En ese caso, haz la prueba en `habi-datalakehouse-ocd` con `02_prueba_rename_iam.ps1`.

---

## 5. Solicitudes [Iván]

**Al equipo dueño de `brokers-main-prod`:**
> Queremos particionar `co_habi_brokers.broker_activity` (por mes sobre `created_at`, con cluster `created_at, broker_id`) para bajar el costo de lectura en más de un 95 %. El procedimiento se ensayó completo en `tmp`, con 0 filas perdidas y 0 duplicadas. Implica pausar el stream `habi-brokers-co` entre 30 y 60 minutos, fuera de horario, el ___ a las ___. Durante la migración no se cambia la configuración del stream, y la tabla original queda como respaldo durante 30 días.
>
> Una vez validada la migración, también proponemos agregar a `habi-brokers-co` una regla de partición (`ruleSets`) solo para `habi_brokers.broker_activity`. No cambia ninguna tabla existente: solo hace que, si Datastream algún día recrea `broker_activity`, salga particionada. Se aplica con `--update-mask=rule_sets` y se valida antes con `--validate-only`.
>
> ¿Nos aprueban la ventana y la regla?

**A los consumidores (dbt Cloud `buyers`, core `buyers_medalion_co`, MX):**
> El ___ entre las ___ y las ___ (Bogotá), las tablas `brokers-main-prod.co_habi_brokers.*` no se actualizarán mientras hacemos un mantenimiento de `broker_activity`. Al terminar se ponen al día solas. El nombre de la tabla y sus columnas no cambian.

### 5.1 Al admin, variante A (días antes)
> ¿Me ayudas con un permiso de tabla en `brokers-main-prod`? Hay que correr esto una vez en la consola de BigQuery:
> ```sql
> GRANT `roles/bigquery.dataViewer`
> ON TABLE `brokers-main-prod.co_habi_brokers.broker_activity_nueva`
> TO "serviceAccount:buyers-mx-dwh-hour-sa@papyrus-master.iam.gserviceaccount.com",
>    "user:usuario.lector@habi.co";
> ```
> Son los mismos 2 permisos que tiene hoy `broker_activity`. La tabla nueva la reemplazará en la ventana del ___.

### 5.2 Al admin, variante B (en la ventana)
> El ___ a las ___ (Bogotá) te escribo para que corras esto, unos minutos después de cambiar los nombres:
> ```sql
> GRANT `roles/bigquery.dataViewer`
> ON TABLE `brokers-main-prod.co_habi_brokers.broker_activity`
> TO "serviceAccount:buyers-mx-dwh-hour-sa@papyrus-master.iam.gserviceaccount.com",
>    "user:usuario.lector@habi.co";
> ```
> Hasta que lo corras, el proceso de MX y el usuario lector no pueden leer la tabla.

---

## 6. Días antes [Iván]

### Paso 1: crear la tabla nueva vacía
```sql
CREATE TABLE `brokers-main-prod.co_habi_brokers.broker_activity_nueva`
LIKE `brokers-main-prod.co_habi_brokers.broker_activity`
PARTITION BY TIMESTAMP_TRUNC(created_at, MONTH)
CLUSTER BY created_at, broker_id
OPTIONS (max_staleness = INTERVAL 1 HOUR);
```

### Paso 1b: verificar
```sql
-- Las dos filas deben tener exactamente el mismo texto en "columnas"
SELECT table_name, STRING_AGG(CONCAT(field_path, ':', data_type), ', ' ORDER BY field_path) AS columnas
FROM `brokers-main-prod.co_habi_brokers.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS`
WHERE table_name IN ('broker_activity', 'broker_activity_nueva')
GROUP BY table_name;

-- Debe contener: PARTITION BY TIMESTAMP_TRUNC(created_at, MONTH) y CLUSTER BY created_at, broker_id
SELECT ddl FROM `brokers-main-prod.co_habi_brokers.INFORMATION_SCHEMA.TABLES`
WHERE table_name = 'broker_activity_nueva';
```

### Paso 2: foto de permisos y, en la variante A, verificar la tabla nueva
```powershell
cd "<repo>\ejemplos\broker_activity_20261105"

# Foto de referencia: los permisos tal como están hoy (se repite en el arranque de la ventana)
.\verificar_permisos.ps1 -Fase antes

# Solo si el admin aplicó el GRANT sobre la tabla nueva antes de la ventana (variante A)
.\verificar_permisos.ps1 -Fase despues -Tabla broker_activity_nueva
```

### Go / no-go para la ventana
- [ ] El equipo dueño aprobó la fecha y la hora.
- [ ] Los consumidores están avisados.
- [ ] `broker_activity_nueva` existe, está vacía y tiene el mismo esquema.
- [ ] Variante A: la tabla nueva tiene los 2 permisos. Variante B: el admin confirmó que estará disponible.
- [ ] La hora es fuera de horario (después de las 20:00 en Bogotá, o el fin de semana).
- [ ] Recomendado: el **entorno de prueba** ya está cerrado (anexo 14, que **no es producción**), para que no haya otro stream activo que se pueda confundir con `habi-brokers-co`.

---

## 7. La ventana [Iván]

**Mapa de la ventana.** El stream de producción se **pausa en el paso 3** y se **reanuda en el paso 11**. Todo lo que hay en medio pasa con el stream detenido.

| Paso | Qué | Stream `habi-brokers-co` |
|---|---|---|
| Arranque | Comprobar el estado, respaldo de la configuración y foto de permisos | ▶️ RUNNING |
| **3** | **⏸️ PAUSAR el stream** | ⏸️ → PAUSED |
| 4 | Esperar a que no quede nada en el buffer | ⏸️ PAUSED |
| 5–8 | Línea base, comprobar que la nueva está vacía, copiar y validar | ⏸️ PAUSED |
| 9 | Respaldo con `COPY`, `DROP` de la original y `RENAME` de la nueva (opción B) | ⏸️ PAUSED |
| 10 | Verificar los permisos | ⏸️ PAUSED |
| **11** | **▶️ REANUDAR el stream** | ▶️ → RUNNING |
| 12 | Expiración del respaldo | ▶️ RUNNING |

### Arranque de la ventana
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'
cd "<repo>\ejemplos\broker_activity_20261105"

(Get-Date).ToString('dddd HH:mm')   # hora de Bogotá: después de las 20:00 o fin de semana
gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="json(state,errors)"

# Respaldo de la configuración del stream antes de tocar nada
gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format=json | Out-File -Encoding utf8 habi-brokers-co_antes.json

# Foto de los permisos justo antes del cambio (reemplaza la del paso 2)
.\verificar_permisos.ps1 -Fase antes -Sobrescribir
```
🛑 Tiene que decir `RUNNING` y no mostrar errores. Repasa también el go / no-go de la sección 6.

### Paso 3: ⏸️ PAUSAR el stream de Datastream de producción (`habi-brokers-co`)
📝 Anota la hora. Desde aquí, las 46 tablas `co_*` dejan de actualizarse.
```powershell
# Revisa el nombre antes de dar Enter: habi-brokers-co (no habi-brokers-mx ni pruebapartition)
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --state=PAUSED --update-mask=state

# El comando responde "done: false": la pausa sigue en segundo plano.
# Este bucle espera hasta PAUSED (pasa antes por DRAINING; en la prueba, ~5 min).
do {
  $s = gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="value(state)"
  "$((Get-Date).ToString('HH:mm:ss'))  $s"
  if ($s -ne 'PAUSED') { Start-Sleep -Seconds 30 }
} while ($s -ne 'PAUSED')
```
🛑 No sigas al paso 4 hasta que diga `PAUSED`.

### Paso 4: esperar a que no quede nada en tránsito
```powershell
# No tiene que imprimir nada (sin streamingBuffer). Puede tardar hasta ~90 min.
bq show --format=prettyjson brokers-main-prod:co_habi_brokers.broker_activity | Select-String streamingBuffer
```
```sql
-- Córrelo dos veces, con 3 minutos de diferencia: tiene que dar exactamente lo mismo
SELECT COUNT(*) AS filas, MAX(datastream_metadata.source_timestamp) AS max_ts
FROM `brokers-main-prod.co_habi_brokers.broker_activity`;
```

### Paso 5: línea base
```sql
SELECT COUNT(*) AS filas, COUNT(DISTINCT datastream_metadata.uuid) AS uuids,
       COUNT(*) - COUNT(DISTINCT datastream_metadata.uuid) AS repetidas_por_uuid
FROM `brokers-main-prod.co_habi_brokers.broker_activity`;
```
📝 Anota `filas` y `uuids`. Se espera `repetidas_por_uuid = 0` (al 2026-11-05 era 0).

### Paso 6: la tabla nueva tiene que estar vacía
```sql
SELECT COUNT(*) AS filas_nueva FROM `brokers-main-prod.co_habi_brokers.broker_activity_nueva`;
```
🛑 Si no da 0:
```sql
TRUNCATE TABLE `brokers-main-prod.co_habi_brokers.broker_activity_nueva`;
```

### Paso 7: copiar (una sola vez)
```sql
INSERT INTO `brokers-main-prod.co_habi_brokers.broker_activity_nueva`
SELECT * FROM `brokers-main-prod.co_habi_brokers.broker_activity`
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (PARTITION BY datastream_metadata.uuid ORDER BY datastream_metadata.source_timestamp) = 1;
```

### Paso 8: validar la copia
```sql
WITH o AS (
  SELECT * FROM `brokers-main-prod.co_habi_brokers.broker_activity` WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY datastream_metadata.uuid ORDER BY datastream_metadata.source_timestamp) = 1
)
SELECT 'original' AS tabla, COUNT(*) AS filas, COUNT(DISTINCT datastream_metadata.uuid) AS uuids,
       COUNT(DISTINCT id) AS ids, MAX(created_at) AS max_created,
       BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(o))) AS huella
FROM o
UNION ALL
SELECT 'nueva', COUNT(*), COUNT(DISTINCT datastream_metadata.uuid), COUNT(DISTINCT id), MAX(created_at),
       BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(n)))
FROM `brokers-main-prod.co_habi_brokers.broker_activity_nueva` AS n;
```
🛑 **Las dos filas tienen que ser idénticas**, y en cada una `filas` tiene que ser igual a `uuids`. Si algo difiere, **no cambies los nombres**: vacía la nueva y salta al paso 11 para reanudar.
```sql
TRUNCATE TABLE `brokers-main-prod.co_habi_brokers.broker_activity_nueva`;
```

### Paso 9: respaldo, `DROP` de la original y `RENAME` de la nueva (opción B)

**Por qué no se renombra la original:** BigQuery bloquea el `RENAME` de una tabla que recibió streaming hace poco, aunque el buffer esté vacío. El error es `Cannot rename ... because it has streaming data`. Pasó en producción el 2026-11-05 con 10 minutos de pausa. Según reportes de la comunidad, el bloqueo puede durar horas o días; en una tabla de prueba con 15 h de pausa ya no estaba.

**Opción B:** la original se respalda con `COPY` y se borra, y la nueva, que nunca recibió streaming, toma el nombre. Se ensayó el 2026-11-05 en `tmp`, sobre una tabla con streaming activo:
- el `RENAME` falló, igual que en producción;
- `COPY`, `DROP` y el `RENAME` de la nueva funcionaron;
- Datastream siguió escribiendo en la tabla renombrada.

**B1. Respaldo de la original por copia:**
```sql
CREATE TABLE `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD`
COPY `brokers-main-prod.co_habi_brokers.broker_activity`;
```

**B1b. Validar el respaldo.** Tiene que dar **lo mismo que la fila `original` del paso 8**: mismas filas, mismos uuids y misma huella.
```sql
SELECT COUNT(*) AS filas, COUNT(DISTINCT datastream_metadata.uuid) AS uuids,
       BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t))) AS huella
FROM `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD` AS t;
```
🛑 Si no coincide, **no sigas a B2**.

**B2 y B3. Borrar la original y renombrar la nueva.** Las dos sentencias juntas, en una sola ejecución:
```sql
DROP TABLE `brokers-main-prod.co_habi_brokers.broker_activity`;
ALTER TABLE `brokers-main-prod.co_habi_brokers.broker_activity_nueva` RENAME TO broker_activity;
```
🛑 **Si B3 falla, NO reanudes el stream** (paso 11): Datastream crearía otra tabla sin partición. Pon la tabla de vuelta desde el respaldo y después reanuda:
```sql
CREATE TABLE `brokers-main-prod.co_habi_brokers.broker_activity`
COPY `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD`;
```
BigQuery también conserva la tabla borrada durante 7 días (*time travel*), así que hay una segunda forma de recuperarla.

**B4. Comprobar el resultado:**
```sql
SELECT table_name, creation_time, REGEXP_CONTAINS(ddl, r'PARTITION BY TIMESTAMP_TRUNC\(created_at, MONTH\)') AS particionada
FROM `brokers-main-prod.co_habi_brokers.INFORMATION_SCHEMA.TABLES`
WHERE table_name LIKE 'broker_activity%';
```
✅ Debe mostrar:
- `broker_activity`, con la `creation_time` del paso 1 y `particionada = true`;
- `broker_activity_respaldo_AAAAMMDD`, sin partición;
- ninguna `broker_activity_nueva`.

### Paso 10: verificar los permisos de la nueva `broker_activity`
```powershell
.\verificar_permisos.ps1 -Fase despues
```
Con la opción B del paso 9, los 2 permisos de tabla de la original se pierden con el `DROP`. **Lo esperado es que el script marque FALTA en los 2 `dataViewer`**, salvo que el admin ya se los haya dado a `broker_activity_nueva` antes de la ventana. Los 38 accesos del dataset no cambian.
El admin puede dar el acceso de dos formas, y las dos sirven:
- un `GRANT` sobre la tabla;
- un acceso `READER` **en el dataset con una condición** `resource.name == ".../tables/broker_activity"`. Así se hizo el 2026-11-05 (título "acceso_gestionado ..."). Además se mantiene aunque la tabla se recree.

El script reconoce la segunda forma como equivalente.
- Todo `OK`: sigue.
- Algo marcado **FALTA**: es la variante B. Pásale la salida al admin **ahora** para que aplique los permisos (sección 5.2). Puedes reanudar (paso 11) mientras tanto: los datos están bien, solo esos lectores esperan el permiso. Cuando el admin termine, repite el comando hasta que todo dé `OK`.

### Paso 11: ▶️ REANUDAR el stream de Datastream de producción (`habi-brokers-co`)
```powershell
# 🛑 Primero confirma que broker_activity existe. NUNCA reanudes si no existe:
#    Datastream crearía otra tabla sin partición.
bq show brokers-main-prod:co_habi_brokers.broker_activity

gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --state=RUNNING --update-mask=state

# Espera hasta RUNNING
do {
  $s = gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="value(state)"
  "$((Get-Date).ToString('HH:mm:ss'))  $s"
  if ($s -ne 'RUNNING') { Start-Sleep -Seconds 30 }
} while ($s -ne 'RUNNING')

# Sin errores
gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="json(state,errors)"
```
```sql
SELECT CURRENT_TIMESTAMP() AS hora_reanudacion;   -- 📝 anótala (UTC)
```

### Paso 12: el respaldo expira en 30 días
```sql
ALTER TABLE `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD`
SET OPTIONS (expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY));
```

---

## 8. Después de la ventana [Iván]

### Paso 13: a los 15 minutos y a las 2 horas
```sql
SELECT 'broker_activity' AS tabla, COUNT(*) AS filas,
       COUNT(*) - COUNT(DISTINCT datastream_metadata.uuid) AS repetidas_por_uuid,
       TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp)) AS ultimo_cambio
FROM `brokers-main-prod.co_habi_brokers.broker_activity`
UNION ALL
SELECT 'respaldo', COUNT(*), COUNT(*) - COUNT(DISTINCT datastream_metadata.uuid),
       TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp))
FROM `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD`;

-- La tabla sigue siendo la particionada (Datastream no la recreó)
SELECT creation_time, ddl FROM `brokers-main-prod.co_habi_brokers.INFORMATION_SCHEMA.TABLES`
WHERE table_name = 'broker_activity';
```
```powershell
# Los permisos siguen como al inicio
.\verificar_permisos.ps1 -Fase despues
```
✅ Está bien si:
- `repetidas_por_uuid` es 0 en las dos tablas;
- el respaldo tiene las mismas filas que en el paso 5;
- `ultimo_cambio` de `broker_activity` es posterior a `hora_reanudacion`;
- el DDL tiene `PARTITION BY` y `CLUSTER BY`, y `creation_time` es la del paso 1;
- `verificar_permisos.ps1` termina con "tiene todos los permisos que tenía al inicio".

### Paso 14: solo si el paso 13 muestra `repetidas_por_uuid` > 0, a partir de las 2 h
Deja una fila por `uuid` y toca solo el mes en curso, porque la reentrega solo afecta filas recientes.
```sql
BEGIN TRANSACTION;
CREATE TEMP TABLE repetidas AS
SELECT * FROM `brokers-main-prod.co_habi_brokers.broker_activity`
WHERE created_at >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)
  AND datastream_metadata.uuid IN (
    SELECT datastream_metadata.uuid FROM `brokers-main-prod.co_habi_brokers.broker_activity`
    WHERE created_at >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)
    GROUP BY 1 HAVING COUNT(*) > 1)
QUALIFY ROW_NUMBER() OVER (PARTITION BY datastream_metadata.uuid ORDER BY datastream_metadata.source_timestamp) = 1;
DELETE FROM `brokers-main-prod.co_habi_brokers.broker_activity`
WHERE created_at >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)
  AND datastream_metadata.uuid IN (SELECT datastream_metadata.uuid FROM repetidas);
INSERT INTO `brokers-main-prod.co_habi_brokers.broker_activity` SELECT * FROM repetidas;
COMMIT TRANSACTION;
```
Después repite el paso 13.

Si falla con un error de "streaming buffer", alguna fila repetida todavía no se consolidó. Espera 30 minutos y vuelve a correrlo. Si algo falla, la transacción no deja cambios a medias. La sintaxis se validó con dry-run en `tmp`, pero nunca se ejecutó (en los ensayos no hubo repetidos).

### Paso 15: al día siguiente, pruebas de partición y cluster

**T1. Configuración.** Debe dar `created_at` con partición = YES y cluster 1, y `broker_id` con cluster 2.
```sql
SELECT column_name, is_partitioning_column, clustering_ordinal_position
FROM `brokers-main-prod.co_habi_brokers.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'broker_activity'
  AND (is_partitioning_column = 'YES' OR clustering_ordinal_position IS NOT NULL);
```

**T2. Cada fila está en la partición de su mes.** `meses_que_cuadran` debe ser `meses` o `meses` − 1 (el mes en curso puede tener filas en el buffer). `filas_created_at_null` debe ser 0.
```sql
WITH por_mes AS (
  SELECT FORMAT_TIMESTAMP('%Y%m', created_at) AS partition_id, COUNT(*) AS filas_consulta
  FROM `brokers-main-prod.co_habi_brokers.broker_activity` GROUP BY 1
),
meta AS (
  SELECT partition_id, total_rows FROM `brokers-main-prod.co_habi_brokers.INFORMATION_SCHEMA.PARTITIONS`
  WHERE table_name = 'broker_activity'
)
SELECT COUNT(*) AS meses,
       COUNTIF(m.total_rows = p.filas_consulta) AS meses_que_cuadran,
       (SELECT IFNULL(SUM(total_rows), 0) FROM meta WHERE partition_id = '__NULL__') AS filas_created_at_null
FROM por_mes p LEFT JOIN meta m USING (partition_id);
```

**T3. Poda de particiones.** Pega la consulta en la consola **sin ejecutarla** y mira el mensaje "Esta consulta procesará X". Antes procesaba ~1,14 GB; ahora debe ser ~28 MB.
```sql
SELECT id, broker_id, created_at FROM `brokers-main-prod.co_habi_brokers.broker_activity`
WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY);
```

**T4. Cluster.** Hay que ejecutarlo: el dry-run no muestra el efecto del cluster. Corre las dos consultas y compara "Bytes procesados" en la pestaña de detalles del job. La de un día tiene que leer bastante menos que la del mes completo (en la prueba, −70 %).
```sql
-- Mes completo (cambia las fechas por el mes anterior al actual)
SELECT COUNT(DISTINCT id), MAX(broker_id) FROM `brokers-main-prod.co_habi_brokers.broker_activity`
WHERE created_at >= TIMESTAMP('2026-10-01') AND created_at < TIMESTAMP('2026-11-01');

-- Un día de ese mes
SELECT COUNT(DISTINCT id), MAX(broker_id) FROM `brokers-main-prod.co_habi_brokers.broker_activity`
WHERE created_at >= TIMESTAMP('2026-10-15') AND created_at < TIMESTAMP('2026-10-16');
```

**T5. Mismo contenido que el respaldo.** Debe devolver solo el mes en curso, que siguió recibiendo datos. Si aparece un mes viejo con unas pocas filas de más, es una actividad antigua actualizada después del cambio: Datastream agrega una fila nueva con su `created_at` original. Es raro, pero válido.
```sql
SELECT FORMAT_TIMESTAMP('%Y-%m', created_at) AS mes, COUNT(*) AS filas
FROM `brokers-main-prod.co_habi_brokers.broker_activity` GROUP BY 1
EXCEPT DISTINCT
SELECT FORMAT_TIMESTAMP('%Y-%m', created_at), COUNT(*)
FROM `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD` GROUP BY 1;
```

**T6. Consumidores y permisos:**
- `.\verificar_permisos.ps1 -Fase despues`: todo `OK`.
- Job `buyers` de dbt Cloud en verde.
- Core `buyers_medalion_co` sin errores.
- El proceso MX (`buyers-mx-dwh-hour-sa`) sigue leyendo la tabla. Pregúntale a su dueño: Iván no puede ver los jobs de `papyrus-master`.
- `usuario.lector@habi.co` puede consultar la tabla. Pídele que corra un `SELECT COUNT(*)`.

---

## 9. Rollback (solo si algo sale mal después de reanudar)

**R1.** ⏸️ Pausar el stream con el paso 3 y esperar con el paso 4.

**R2.** Pasar al respaldo lo que llegó después del cambio, filtrando por `uuid` para no duplicar:
```sql
INSERT INTO `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD`
SELECT * FROM `brokers-main-prod.co_habi_brokers.broker_activity` AS n
WHERE NOT EXISTS (
  SELECT 1 FROM `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD` AS r
  WHERE r.datastream_metadata.uuid = n.datastream_metadata.uuid
)
QUALIFY ROW_NUMBER() OVER (PARTITION BY n.datastream_metadata.uuid ORDER BY n.datastream_metadata.source_timestamp) = 1;
```

**R3.** Quitarle la expiración al respaldo:
```sql
ALTER TABLE `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD`
SET OPTIONS (expiration_timestamp = NULL);
```

**R4.** Volver a la original. `broker_activity` acaba de recibir streaming y **no se puede renombrar**, así que se usa la misma técnica de la opción B. Corre las sentencias juntas:
```sql
-- Copia de la particionada, por si hay que revisarla después
CREATE TABLE `brokers-main-prod.co_habi_brokers.broker_activity_fallida_AAAAMMDD`
COPY `brokers-main-prod.co_habi_brokers.broker_activity`;
-- El respaldo nunca recibió streaming: se puede renombrar
DROP TABLE `brokers-main-prod.co_habi_brokers.broker_activity`;
ALTER TABLE `brokers-main-prod.co_habi_brokers.broker_activity_respaldo_AAAAMMDD` RENAME TO broker_activity;
```
🛑 Si el `RENAME` falla, no reanudes. Recupera con `CREATE TABLE ...broker_activity COPY ...broker_activity_respaldo_AAAAMMDD`.

**R5.** Verificar los permisos con `.\verificar_permisos.ps1 -Fase despues` (si falta algo, se lo pasas al admin) y ▶️ reanudar con el paso 11.

**R6.** Que la tabla particionada que se retiró expire en 30 días:
```sql
ALTER TABLE `brokers-main-prod.co_habi_brokers.broker_activity_fallida_AAAAMMDD`
SET OPTIONS (expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY));
```

En la variante B, R4 también borra los 2 permisos de tabla, así que el admin tiene que correr el `GRANT` de la sección 5.2 otra vez.

---

## 10. Paso opcional, después de la migración: regla de partición en el stream

### Qué hace y qué no hace

| Aspecto | Qué pasa |
|---|---|
| La tabla actual `broker_activity` | **Nada.** La regla solo se aplica cuando Datastream crea la tabla |
| Las otras 45 tablas `co_*` | Nada. La regla filtra solo `habi_brokers.broker_activity` |
| El stream | Se actualiza sin recrearse. En la prueba tardó 13 s y siguió `RUNNING` |
| Si algún día Datastream recrea `broker_activity` (alguien la borra, o se saca y se vuelve a meter el objeto) | Sale **particionada y con cluster**, en vez de sin partición |

**No reemplaza la migración.** Para que la regla actúe sobre la tabla actual, habría que dejar que Datastream la recree con backfill desde Aurora, que en la prueba dejó un 3,6 % de duplicados.

**Requisitos:**
- La migración ya está validada (paso 15 completo).
- El equipo dueño aprobó la regla (sección 5).
- El ensayo 3 pasó.
- La regla tiene que ser **idéntica** a la tabla creada en el paso 1: mensual por `created_at`, con cluster `created_at, broker_id`.

### Paso 16: ensayo 3 (✅ ya hecho el 2026-11-05; no hay que repetirlo ni correr nada)

Se ensayó en el entorno de prueba lo único que faltaba: **agregar** la regla a un stream que ya escribe en una tabla existente. **Resultado: aprobado.** Se aplicó a las 19:41 UTC en 24 s:
- el stream siguió `RUNNING` y con `ruleSets`;
- el backfill no se repitió;
- la tabla no se recreó (`creation_time` 14:01:01);
- siguieron llegando datos, con 0 repetidos;
- contra producción, 642 ids de 642, con 0 faltantes.

Detalle en `RESULTADOS_20261105.md`.

### Paso 17 [Iván]: agregar la regla a `habi-brokers-co`

El stream de producción no está en Terraform, así que se usa `gcloud` con el archivo **`rule_sets_broker_activity.json`**, que está en esta misma carpeta:
```json
[
  {
    "objectFilter": {
      "sourceObjectIdentifier": {
        "mysqlIdentifier": { "database": "habi_brokers", "table": "broker_activity" }
      }
    },
    "customizationRules": [
      { "bigqueryPartitioning": { "timeUnitPartition": { "column": "created_at", "partitioningTimeGranularity": "PARTITIONING_TIME_GRANULARITY_MONTH" } } },
      { "bigqueryClustering": { "columns": ["created_at", "broker_id"] } }
    ]
  }
]
```
```powershell
cd "<repo>\ejemplos\broker_activity_20261105"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'

# a) Estado antes (guárdalo)
gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format=json | Out-File -Encoding utf8 habi-brokers-co_antes_regla.json

# b) Solo valida; no cambia nada
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --rule-sets=rule_sets_broker_activity.json --update-mask=rule_sets --validate-only
```
🛑 Si la validación da error, no sigas.
```powershell
# c) Aplica (el update-mask limita el cambio a rule_sets)
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --rule-sets=rule_sets_broker_activity.json --update-mask=rule_sets

# d) Verifica
gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="json(state,errors,ruleSets)"
gcloud.cmd datastream objects list --stream=habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="table(display_name,backfill_job_state,last_backfill_job_start_time)"
```
✅ Está bien si:
- el stream sigue `RUNNING`, sin errores y con `ruleSets`;
- ningún objeto pasó a `ACTIVE` en `backfill_job_state`;
- a los 15 min, el paso 13 muestra datos nuevos en `broker_activity`, con el mismo `creation_time` y 0 repetidos.

**Si hay que quitar la regla:** se aplica una lista vacía con la misma máscara. No está probado; ensáyalo antes en `pruebapartition` si llega a hacer falta.
```powershell
'[]' | Out-File -Encoding ascii rule_sets_vacio.json
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --rule-sets=rule_sets_vacio.json --update-mask=rule_sets --validate-only
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --rule-sets=rule_sets_vacio.json --update-mask=rule_sets
```

`validaciones\validar.ps1` compara `habi-brokers-co` con la línea base del 2026-11-04. Después de este paso va a marcar diferencias, y eso es lo esperado: la nueva línea base es `habi-brokers-co_antes_regla.json` más la regla.

---

## 11. Después: lo que habilita y lo que queda

- **#142b (dbt):** `ent_actividad_brokers` puede leer solo el mes en curso. Para que la partición sirva, el filtro tiene que ser **sobre `created_at`**, por ejemplo `created_at >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MONTH)`.
  - **Nunca sobre `datastream_metadata.source_timestamp`.** No aprovecha la partición y lee más que no filtrar (medido el 2026-11-05).
- **Cerrar el entorno de prueba:** anexo 14.

## 12. Registro de la ejecución (llenar el día de la ventana)

| Dato | Valor |
|---|---|
| Fecha (`AAAAMMDD`) | |
| Variante de permisos (A / B / C) | |
| Hora de la pausa (UTC) | |
| Paso 5: filas / uuids | |
| Paso 8: ¿huellas idénticas? | |
| Paso 10: `verificar_permisos.ps1` (¿OK / qué faltó?) | |
| Hora en que el admin dejó los permisos completos (UTC) | |
| Paso 9 B1b: filas / uuids / huella del respaldo | |
| Hora de B2+B3 (`DROP` y `RENAME`, UTC) | |
| Hora de reanudación (UTC) | |
| Paso 13 (+15 min): repetidos / último cambio | |
| Paso 13 (+2 h): repetidos | |
| T3: bytes del filtro de 30 días | |
| T4: bytes del mes / bytes del día | |
| Paso 16: ensayo 3 (¿OK?) | |
| Paso 17: fecha y hora de la regla (UTC) / ¿`validate-only` OK? | |
| Incidencias | |

---

## 13. Anexo: comandos `gcloud` del stream (pausar, agregar la regla y reanudar)

**¿Por qué con `gcloud`?** Es lo que se ensayó (ensayos 2 y 3). `--update-mask` garantiza que solo cambia el campo indicado. El comando es siempre el mismo y la salida deja un id de operación como registro. La consola hace la misma llamada a la API, pero es más fácil equivocarse de stream (`habi-brokers-mx` está al lado) o tocar otros campos. Terraform no aplica, porque `habi-brokers-co` no está en Terraform.

**Para agregar la regla no hace falta pausar.** El ensayo 3 la agregó con el stream corriendo. La pausa es solo para la migración de la tabla.

**Cuidados:**
- Usa `gcloud.cmd`, no `gcloud`, por la política de scripts de Windows.
- Revisa el nombre del stream antes de dar Enter: `habi-brokers-co`, no `habi-brokers-mx` ni `pruebapartition`.
- `update` responde `done: false`: el cambio sigue en segundo plano. Espera el estado con los bucles de abajo.

### 13.1 Preparación (en cada ventana nueva de PowerShell)
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'
cd "<repo>\ejemplos\broker_activity_20261105"

# Estado actual: tiene que decir RUNNING y no mostrar errores
gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="json(state,errors,ruleSets)"

# Respaldo de la configuración antes de tocar nada
gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format=json | Out-File -Encoding utf8 habi-brokers-co_antes.json
```

### 13.2 Pausar (paso 3)
```powershell
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --state=PAUSED --update-mask=state

# Espera hasta PAUSED (pasa por DRAINING; en la prueba tardó ~5 min, con 46 tablas puede tardar más)
do {
  $s = gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="value(state)"
  "$((Get-Date).ToString('HH:mm:ss'))  $s"
  if ($s -ne 'PAUSED') { Start-Sleep -Seconds 30 }
} while ($s -ne 'PAUSED')
```

### 13.3 Reanudar (paso 11)
```powershell
# 🛑 Primero: broker_activity tiene que existir. NUNCA reanudes si no existe.
bq show brokers-main-prod:co_habi_brokers.broker_activity

gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --state=RUNNING --update-mask=state

# Espera hasta RUNNING
do {
  $s = gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="value(state)"
  "$((Get-Date).ToString('HH:mm:ss'))  $s"
  if ($s -ne 'RUNNING') { Start-Sleep -Seconds 30 }
} while ($s -ne 'RUNNING')
```

### 13.4 Agregar la regla de partición (paso 17, con el stream corriendo)
Usa `rule_sets_broker_activity.json`, que está en esta carpeta: partición mensual por `created_at` y cluster `created_at, broker_id`, solo para `habi_brokers.broker_activity`.
```powershell
# a) Solo valida; no cambia nada
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --rule-sets=rule_sets_broker_activity.json --update-mask=rule_sets --validate-only
```
🛑 Si da error, no sigas.
```powershell
# b) Aplica: la máscara limita el cambio a rule_sets
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --rule-sets=rule_sets_broker_activity.json --update-mask=rule_sets

# c) Verifica: tiene que aparecer ruleSets, con el stream RUNNING y sin errores
gcloud.cmd datastream streams describe habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="json(state,errors,ruleSets)"

# d) Ningún objeto tiene que haber pasado a ACTIVE (no se disparó un backfill)
gcloud.cmd datastream objects list --stream=habi-brokers-co --location=us-central1 --project=brokers-main-prod --format="table(display_name,backfill_job_state,last_backfill_job_start_time)"
```
A los 15 minutos, repite el paso 13: siguen llegando datos a `broker_activity`, con el mismo `creation_time` y 0 repetidos.

### 13.5 Quitar la regla (solo si hace falta)
No está probado; ensáyalo antes en `pruebapartition`.
```powershell
'[]' | Out-File -Encoding ascii rule_sets_vacio.json
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --rule-sets=rule_sets_vacio.json --update-mask=rule_sets --validate-only
gcloud.cmd datastream streams update habi-brokers-co --location=us-central1 --project=brokers-main-prod --rule-sets=rule_sets_vacio.json --update-mask=rule_sets
```

### 13.6 Orden si haces todo el mismo día

| Orden | Qué | Dónde |
|---|---|---|
| 1 | Pausar | 13.2 (paso 3) |
| 2 | Esperar el buffer, copiar, validar y cambiar los nombres | Pasos 4 a 10 |
| 3 | Reanudar | 13.3 (paso 11) |
| 4 | Revisar a los 15 min que todo esté bien | Paso 13 |
| 5 | **Agregar la regla con el stream corriendo** | 13.4 (paso 17) |

La regla va **después** de reanudar y validar, no durante la pausa. Con el stream corriendo está ensayado; en pausa no se probó. Además, así un problema con la regla no se mezcla con la migración.

Ambas operaciones cambian `habi-brokers-co`, que es de otro equipo. Hazlas solo con su aprobación (sección 5) y fuera de horario.

---

## 14. Anexo: cerrar el entorno de PRUEBA (⚠️ esto NO es producción)

> ⚠️ Esta sección **no toca `habi-brokers-co`**. Cierra el stream de prueba `pruebapartition` y sus tablas en el dataset `tmp`. Hazlo **antes** de la ventana de producción, en otro momento, para que no quede otro stream activo que se pueda confundir. El entorno de prueba lo gestiona Terraform, así que se cierra con Terraform, no con `gcloud`.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'
cd "<repo>\terraform\envs\prueba"

# Revisa: debe listar SOLO module.stream.google_datastream_stream.this (stream_id = "pruebapartition")
terraform plan -destroy -out="cerrar_prueba.tfplan"
terraform apply "cerrar_prueba.tfplan"
```
Después, en BigQuery. Comprueba que el dataset sea **`tmp`**:
```sql
DROP TABLE `brokers-main-prod.tmp.habi_brokers_broker_activity`;
DROP TABLE `brokers-main-prod.tmp.ensayo_respaldo`;
```
Las dos tablas expiran solas el 2026-12-05 si no las borras.
