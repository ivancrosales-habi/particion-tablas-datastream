-- =============================================================================
-- Pruebas de que la partición y el cluster funcionan en broker_activity.
-- Probadas el 2026-11-05 sobre brokers-main-prod.tmp.habi_brokers_broker_activity
-- (resultados en RESULTADOS_20261105.md).
-- Para producción, reemplazar la tabla por brokers-main-prod.co_habi_brokers.broker_activity
-- y el dataset de INFORMATION_SCHEMA por co_habi_brokers.
-- Todas son de solo lectura.
-- =============================================================================

-- T1. Configuración: created_at con partición = YES y cluster 1; broker_id con cluster 2.
SELECT column_name, is_partitioning_column, clustering_ordinal_position
FROM `brokers-main-prod.tmp.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'habi_brokers_broker_activity'
  AND (is_partitioning_column = 'YES' OR clustering_ordinal_position IS NOT NULL);

-- T2. Cada fila está en la partición de su mes: el conteo por mes calculado tiene que coincidir con
--     los metadatos de la partición. Solo el mes en curso puede diferir, por las filas que siguen
--     en el buffer de streaming. Además, 0 filas en __NULL__.
WITH por_mes AS (
  SELECT FORMAT_TIMESTAMP('%Y%m', created_at) AS partition_id, COUNT(*) AS filas_consulta
  FROM `brokers-main-prod.tmp.habi_brokers_broker_activity` GROUP BY 1
),
meta AS (
  SELECT partition_id, total_rows FROM `brokers-main-prod.tmp.INFORMATION_SCHEMA.PARTITIONS`
  WHERE table_name = 'habi_brokers_broker_activity'
)
SELECT COUNT(*) AS meses,
       COUNTIF(m.total_rows = p.filas_consulta) AS meses_que_cuadran,
       COUNTIF(m.total_rows IS NULL) AS meses_sin_particion,
       (SELECT IFNULL(SUM(total_rows), 0) FROM meta WHERE partition_id = '__NULL__') AS filas_created_at_null
FROM por_mes p LEFT JOIN meta m USING (partition_id);

-- T3. Poda de particiones (dry-run, sin ejecutar). Comparar los bytes estimados:
--   sin filtro                                      -> tabla completa (~1,14 GB en 3 columnas)
--   created_at >= TIMESTAMP('2026-10-01')           -> ~28 MB
--   created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) -> ~28 MB
--   DATE(created_at, 'America/Bogota') >= '2026-10-01' -> ~28 MB (también poda)
--   datastream_metadata.source_timestamp >= ...     -> NO poda (lee más que la tabla completa)
SELECT id, broker_id, created_at FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`
WHERE created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY);

-- T4. Cluster (hay que EJECUTAR; el dry-run no muestra la poda por cluster).
--     Correr sin caché y leer total_bytes_processed en T5.
--     bq query --use_cache=false --label=prueba_particion:<nombre> ...
SELECT COUNT(DISTINCT id), MAX(broker_id) FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`
WHERE created_at >= TIMESTAMP('2026-10-01') AND created_at < TIMESTAMP('2026-11-01');                -- mes completo
SELECT COUNT(DISTINCT id), MAX(broker_id) FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`
WHERE created_at >= TIMESTAMP('2026-10-15') AND created_at < TIMESTAMP('2026-10-16');                -- 1 día: debe leer menos que el mes
SELECT COUNT(DISTINCT id), MAX(broker_id) FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`
WHERE broker_id = 17480;                                                                             -- 1 broker en toda la tabla

-- T5. Bytes reales de las ejecuciones de T4.
SELECT (SELECT value FROM UNNEST(labels) WHERE key = 'prueba_particion') AS prueba,
       total_bytes_processed, total_bytes_billed, total_slot_ms
FROM `brokers-main-prod.region-us.INFORMATION_SCHEMA.JOBS_BY_USER`
WHERE creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
  AND EXISTS (SELECT 1 FROM UNNEST(labels) WHERE key = 'prueba_particion')
ORDER BY prueba;

-- T6. Los datos nuevos de Datastream caen en la partición del mes en curso (correr dos veces con 1 h).
SELECT partition_id, total_rows, last_modified_time
FROM `brokers-main-prod.tmp.INFORMATION_SCHEMA.PARTITIONS`
WHERE table_name = 'habi_brokers_broker_activity'
ORDER BY partition_id DESC LIMIT 3;

-- T7. Mismo resultado que la tabla sin partición (solo en producción, contra el respaldo):
--     el conteo por mes de broker_activity tiene que ser igual al del respaldo, salvo el mes en curso.
-- SELECT FORMAT_TIMESTAMP('%Y-%m', created_at) AS mes, COUNT(*) FROM `...broker_activity` GROUP BY 1
-- EXCEPT DISTINCT
-- SELECT FORMAT_TIMESTAMP('%Y-%m', created_at), COUNT(*) FROM `...broker_activity_respaldo_AAAAMMDD` GROUP BY 1;
