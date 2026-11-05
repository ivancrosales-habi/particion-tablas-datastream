-- =============================================================================
-- FASE 0 - ENSAYO en tmp del procedimiento de producción (sin tocar producción)
--
-- Usa la tabla y el stream de la prueba:
--   tabla : brokers-main-prod.tmp.habi_brokers_broker_activity (49,14 M filas, 1,7 M duplicados)
--   stream: pruebapartition (hoy PAUSED)
-- Responde: ¿Datastream escribe en una tabla particionada creada a mano y renombrada?
--           ¿Reanudar deja uuid repetidos?
-- =============================================================================

-- E1. El stream de prueba tiene que estar PAUSED (terminal):
--   gcloud.cmd datastream streams describe pruebapartition --location=us-central1 --project=brokers-main-prod --format="value(state)"

-- E2. Línea base de la tabla de prueba.
SELECT COUNT(*) AS filas, COUNT(DISTINCT datastream_metadata.uuid) AS uuids,
       COUNT(*) - COUNT(DISTINCT datastream_metadata.uuid) AS repetidas_por_uuid
FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`;
-- Esperado (2026-11-05): 49.142.908 filas, 47.437.635 uuids.

-- E3. Crear la tabla manual vacía, con el MISMO DDL que generó Datastream.
CREATE TABLE `brokers-main-prod.tmp.ensayo_nueva`
LIKE `brokers-main-prod.tmp.habi_brokers_broker_activity`
PARTITION BY TIMESTAMP_TRUNC(created_at, MONTH)
CLUSTER BY created_at, broker_id
OPTIONS (
  max_staleness = INTERVAL 1 HOUR,
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)  -- tmp borra a los 5 días
);

-- E4. Copiar deduplicando por uuid (la nueva debe estar vacía).
INSERT INTO `brokers-main-prod.tmp.ensayo_nueva`
SELECT * FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (PARTITION BY datastream_metadata.uuid ORDER BY datastream_metadata.source_timestamp) = 1;

-- E5. Validar: filas = uuids, 0 repetidos y huella igual a la original deduplicada.
WITH o AS (
  SELECT * FROM `brokers-main-prod.tmp.habi_brokers_broker_activity` WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY datastream_metadata.uuid ORDER BY datastream_metadata.source_timestamp) = 1
)
SELECT 'original_dedup' AS tabla, COUNT(*) AS filas, COUNT(DISTINCT datastream_metadata.uuid) AS uuids,
       BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(o))) AS huella
FROM o
UNION ALL
SELECT 'nueva', COUNT(*), COUNT(DISTINCT datastream_metadata.uuid),
       BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(n)))
FROM `brokers-main-prod.tmp.ensayo_nueva` AS n;
-- Las dos filas deben ser idénticas. Esperado: 47.437.635 filas = uuids.

-- E6. Intercambiar nombres (uno inmediatamente después del otro).
ALTER TABLE `brokers-main-prod.tmp.habi_brokers_broker_activity` RENAME TO ensayo_respaldo;
ALTER TABLE `brokers-main-prod.tmp.ensayo_nueva` RENAME TO habi_brokers_broker_activity;

-- E7. Anotar la foto del respaldo (para comprobar que Datastream ya no le escribe).
SELECT COUNT(*) AS filas_respaldo, CURRENT_TIMESTAMP() AS hora_reanudacion
FROM `brokers-main-prod.tmp.ensayo_respaldo`;

-- E8. Reanudar el stream de prueba (terminal), igual que se hará en producción:
--   gcloud.cmd datastream streams update pruebapartition --location=us-central1 --project=brokers-main-prod --state=RUNNING --update-mask=state
-- y en terraform.tfvars: desired_state = "RUNNING"

-- E9. A los 15 min y a las 2 h: ¿a dónde llegan los datos nuevos?
SELECT 'nueva' AS tabla, COUNT(*) AS filas,
       TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp)) AS ultimo_cambio
FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`
UNION ALL
SELECT 'respaldo', COUNT(*), TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp))
FROM `brokers-main-prod.tmp.ensayo_respaldo`;
-- OK si: "nueva" tiene ultimo_cambio posterior a hora_reanudacion
--        y "respaldo" sigue con filas_respaldo del paso E7.

-- E10. La partición sigue intacta (Datastream no recreó la tabla).
SELECT ddl FROM `brokers-main-prod.tmp.INFORMATION_SCHEMA.TABLES`
WHERE table_name = 'habi_brokers_broker_activity';
-- Debe tener PARTITION BY TIMESTAMP_TRUNC(created_at, MONTH) y CLUSTER BY created_at, broker_id.

-- E11. A las 2 h: ¿la reanudación dejó uuid repetidos?
SELECT COUNT(*) AS filas, COUNT(DISTINCT datastream_metadata.uuid) AS uuids,
       COUNT(*) - COUNT(DISTINCT datastream_metadata.uuid) AS repetidas_por_uuid
FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`;
-- Esperado: repetidas_por_uuid = 0. Si hay, ensayar aquí la limpieza P14 del archivo de producción.

-- =============================================================================
-- ENSAYO 2: stream SIN rule_sets, igual que habi-brokers-co
-- El ensayo 1 se hizo con un stream que SÍ tenía la regla de partición. Producción no la tiene.
-- Hay que confirmar que un stream sin regla también escribe en la tabla particionada a mano,
-- y que una pausa y reanudación hechas con gcloud (como en producción) no la recrean.
-- =============================================================================

-- S1. Quitar la regla (terminal, envs\pruebapartition). Es un update in-place, verificado con plan el 2026-11-05.
--   En terraform.tfvars:  aplicar_reglas_particion = false
--   terraform plan -out="ensayo2_sin_reglas.tfplan"   # 0 to add, 1 to change, 0 to destroy; solo "- rule_sets"
--   terraform apply "ensayo2_sin_reglas.tfplan"
--   gcloud.cmd datastream streams describe pruebapartition --location=us-central1 --project=brokers-main-prod --format="json(state,ruleSets)"
--   -> state RUNNING, sin ruleSets

-- S2. Foto antes de la pausa.
SELECT COUNT(*) AS filas, CURRENT_TIMESTAMP() AS hora_pausa
FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`;

-- S3. Pausar y reanudar con gcloud, igual que en producción (P3 y P11):
--   gcloud.cmd datastream streams update pruebapartition --location=us-central1 --project=brokers-main-prod --state=PAUSED --update-mask=state
--   (esperar PAUSED)
--   gcloud.cmd datastream streams update pruebapartition --location=us-central1 --project=brokers-main-prod --state=RUNNING --update-mask=state

-- S4. A los 15 min y a la 1 h: la tabla sigue siendo la creada a mano y recibe datos, sin repetidos.
SELECT
  (SELECT creation_time FROM `brokers-main-prod.tmp.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'habi_brokers_broker_activity') AS creation_time,  -- debe seguir siendo 2026-11-05 14:01:01
  (SELECT REGEXP_CONTAINS(ddl, r'PARTITION BY TIMESTAMP_TRUNC\(created_at, MONTH\)') FROM `brokers-main-prod.tmp.INFORMATION_SCHEMA.TABLES` WHERE table_name = 'habi_brokers_broker_activity') AS sigue_particionada,
  COUNT(*) AS filas,
  COUNT(*) - COUNT(DISTINCT datastream_metadata.uuid) AS repetidas_por_uuid,
  TIMESTAMP_MILLIS(MAX(datastream_metadata.source_timestamp)) AS ultimo_cambio
FROM `brokers-main-prod.tmp.habi_brokers_broker_activity`;
-- OK si: creation_time sin cambio, sigue_particionada = true, repetidas = 0, ultimo_cambio posterior a la reanudación.
-- Y en la terminal: backfill_job_state sigue COMPLETED con inicio 2026-11-05T01:36:52.

-- E12. Cierre del ensayo: pausar el stream de prueba de nuevo y dejar que ensayo_respaldo expire
--      (o DROP TABLE `brokers-main-prod.tmp.ensayo_respaldo`;).
