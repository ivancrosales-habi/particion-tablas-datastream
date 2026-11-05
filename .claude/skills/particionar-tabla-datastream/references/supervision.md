# Comandos de supervisión (solo lectura)

Son los que corres **tú** para confirmar cada paso mientras la persona ejecuta. Ninguno cambia nada. Reemplaza `PROYECTO`, `DATASET`, `TABLA`, `STREAM`, `REGION`, `LLAVE` y `AAAAMMDD`.

## Preparación en PowerShell (una vez por sesión)
```powershell
$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'
$sp = "<carpeta temporal tuya>"     # para los archivos .sql
function Q([string]$nombre, [string]$sql) {
  [IO.File]::WriteAllText("$sp\$nombre.sql", $sql, (New-Object Text.UTF8Encoding $false))   # sin BOM
  cmd /c "bq query --quiet --use_legacy_sql=false --format=pretty --project_id=PROYECTO < `"$sp\$nombre.sql`""
}
```
Para un dry-run, cambia `--quiet ... --format=pretty` por `--dry_run`.

## Estado del stream
```powershell
gcloud.cmd datastream streams describe STREAM --location=REGION --project=PROYECTO --format="json(state,errors,ruleSets,updateTime)"
```

## Backfills activos (tiene que dar 0)
```powershell
$t = gcloud.cmd datastream objects list --stream=STREAM --location=REGION --project=PROYECTO --format="table(display_name,backfill_job_state,last_backfill_job_start_time)"
@($t | Select-String -Pattern '\bACTIVE\b|\bPENDING\b').Count
$t | Select-String 'TABLA'
```

## Tablas del dataset relacionadas
```powershell
bq ls --max_results=1000 PROYECTO:DATASET | Select-String 'TABLA'
```
```sql
SELECT table_name, creation_time,
  REGEXP_CONTAINS(ddl, r'PARTITION BY') AS particionada,
  REGEXP_CONTAINS(ddl, r'CLUSTER BY') AS con_cluster
FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLES`
WHERE table_name LIKE 'TABLA%';
```

## Buffer de streaming (paso 4)
```powershell
$j = bq show --format=json PROYECTO:DATASET.TABLA | Out-String | ConvertFrom-Json
if ($j.streamingBuffer) { "buffer: $($j.streamingBuffer.estimatedRows) filas" } else { 'buffer: VACIO' }
"consolidadas: $($j.numRows)"
```
Para esperar: repite cada 60 s hasta que diga VACIO. En 2026-11-05 tardó ~6 min después de `PAUSED`.

## Conteo estable (paso 4) y línea base (paso 5)
```sql
SELECT COUNT(*) AS filas, COUNT(DISTINCT LLAVE) AS llaves, COUNT(*) - COUNT(DISTINCT LLAVE) AS repetidas,
       TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp)) AS ultimo_cambio
FROM `PROYECTO.DATASET.TABLA`;
```

## Esquemas iguales (paso 1b y arranque)
```sql
WITH c AS (
  SELECT table_name, STRING_AGG(CONCAT(field_path, ':', data_type), ', ' ORDER BY field_path) AS columnas
  FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS`
  WHERE table_name IN ('TABLA', 'TABLA_nueva') GROUP BY table_name
)
SELECT COUNT(DISTINCT columnas) AS versiones_de_esquema, COUNT(*) AS tablas FROM c;   -- tiene que dar 1 versión y 2 tablas
```

## Huellas de dos tablas (pasos 8, B1b y después del 9)
```sql
SELECT 'A' AS tabla, COUNT(*) AS filas, COUNT(DISTINCT LLAVE) AS llaves, BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t))) AS huella
FROM `PROYECTO.DATASET.TABLA` AS t
UNION ALL
SELECT 'B', COUNT(*), COUNT(DISTINCT LLAVE), BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t)))
FROM `PROYECTO.DATASET.TABLA_respaldo_AAAAMMDD` AS t;
```

## Después de reanudar: ¿llegan datos a la tabla correcta? (pasos 11 y 13)
```sql
SELECT
  (SELECT creation_time FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'TABLA') AS creation_time,  -- la del paso 1
  COUNT(*) AS filas,
  COUNT(*) - COUNT(DISTINCT LLAVE) AS repetidas,
  TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp)) AS ultimo_cambio                                            -- posterior a la reanudación
FROM `PROYECTO.DATASET.TABLA`;
```
Para esperar el primer dato: repítelo cada 60 s. En 2026-11-05 llegó a los ~90 s.

## Ventana de la pausa contra otra fuente (opcional)
Si existe otra copia de la misma tabla que **no** se pausó (por ejemplo, la de un stream de prueba), compara los ids creados durante la pausa:
```sql
WITH p AS (SELECT DISTINCT id FROM `OTRA.TABLA` WHERE created_at BETWEEN TIMESTAMP('<inicio>') AND TIMESTAMP('<fin>')),
     t AS (SELECT DISTINCT id FROM `PROYECTO.DATASET.TABLA` WHERE created_at BETWEEN TIMESTAMP('<inicio>') AND TIMESTAMP('<fin>'))
SELECT (SELECT COUNT(*) FROM p) AS ids_a, (SELECT COUNT(*) FROM t) AS ids_b,
       (SELECT COUNT(*) FROM p LEFT JOIN t USING (id) WHERE t.id IS NULL) AS faltan,
       (SELECT COUNT(*) FROM t LEFT JOIN p USING (id) WHERE p.id IS NULL) AS sobran;
```

## Accesos
```powershell
.\scripts\verificar_permisos.ps1 -Fase despues -Proyecto PROYECTO -Dataset DATASET -Tabla TABLA
bq get-iam-policy --format=prettyjson PROYECTO:DATASET.TABLA
```

## Expiración del respaldo (paso 12)
```sql
SELECT table_name, option_value FROM `PROYECTO.DATASET.INFORMATION_SCHEMA.TABLE_OPTIONS`
WHERE table_name LIKE 'TABLA%' AND option_name = 'expiration_timestamp';
```

## Hora (Bogotá y UTC)
```powershell
"Bogota: " + (Get-Date).ToString('dddd HH:mm:ss') + "  UTC: " + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
```
