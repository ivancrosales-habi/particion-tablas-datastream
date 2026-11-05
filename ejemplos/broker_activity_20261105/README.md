# Caso real: `brokers-main-prod.co_habi_brokers.broker_activity` (2026-11-05)

| | |
|---|---|
| Tabla | 47,4 M filas, ~5,6 GB, append-only (sin PK), origen MySQL (Aurora), stream `habi-brokers-co` (46 tablas, modo `merge`, `data_freshness` 3600 s) |
| Resultado | Partición mensual por `created_at` y cluster `created_at, broker_id`. 0 filas perdidas, 0 duplicadas, huella idéntica (`1948009887354143778`) |
| Pausa del stream | 16:27 a 17:26 (Bogotá), incluidos ~25 min por el error de `RENAME` |
| Contexto | Sub-issue #142 (optimización de `ent_actividad_brokers` en dbt) |

## Archivos

| Archivo | Qué es |
|---|---|
| `GUIA_PRODUCCION_broker_activity.md` | La guía específica que se siguió, con los valores reales y los cambios hechos durante la ejecución (opción B en el paso 9) |
| `RESULTADOS_20261105.md` | Prueba con un stream independiente, backfill (y sus duplicados), ensayos 1, 2 y 3, y medición de partición y cluster |
| `ENSAYO_TMP.sql` | Ensayo del procedimiento en el dataset `tmp` (ensayos 1 y 2) |
| `PRUEBAS_PARTICION_CLUSTER.sql` | Pruebas T1 a T7: configuración, reparto por partición, poda (dry-run), cluster (ejecución real) y bytes |
| `rule_sets_broker_activity.json` | La regla de partición para el stream |

## Lo que pasó y se aprendió

1. **El `RENAME` de la tabla original falló:** `Cannot rename ... because it has streaming data`, con el stream pausado 10 minutos y el buffer vacío. En el ensayo no apareció porque esa tabla llevaba 12 horas pausada.
   - Se resolvió en la misma ventana con la **opción B**: respaldo con `COPY`, `DROP` de la original y `RENAME` de la nueva.
   - Antes de aplicarla en producción se ensayó en `tmp`, sobre una tabla con streaming activo.
2. Después de B3 se corrió por error el comando de recuperación y dio `Cannot replace a table with a different partitioning spec`. No causó daño: la tabla ya era la particionada.
3. **Permisos:** el `DROP` borró los 2 permisos de tabla. El admin los repuso como `READER` en el dataset con condición `resource.name == ".../tables/broker_activity"`. Esa forma sobrevive a que la tabla se recree.
4. Al reanudar no se disparó ningún backfill, y llegaron los 2.807 eventos de la pausa sin duplicados.
5. Ahorro medido:
   - Los últimos 30 días pasaron de 1,14 GB a ~28 MB.
   - El mes en curso, con las columnas que usa el modelo de dbt, pasó de 2,34 GB a ~6 MB.
   - Filtrar por `datastream_metadata.source_timestamp` **no** poda nada.
