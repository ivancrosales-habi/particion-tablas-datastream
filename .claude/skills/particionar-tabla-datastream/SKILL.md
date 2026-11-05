---
name: particionar-tabla-datastream
description: Guía y supervisa, paso a paso, cómo particionar y clusterizar (PARTITION BY / CLUSTER BY) una tabla de BigQuery que alimenta Datastream, sin perder ni duplicar datos y conservando los accesos. Úsalo siempre que alguien quiera particionar, clusterizar, reparticionar o bajar el costo de lectura de una tabla escrita por Datastream (dataset co_*, mx_*, o con columna datastream_metadata); cuando haya que pausar o reanudar un stream de Datastream para cambiar su tabla de destino; cuando aparezcan errores como "Cannot rename ... because it has streaming data" o "Cannot replace a table with a different partitioning spec"; o cuando haya que revisar logs de esa migración, aunque no diga "skill" ni "partición" explícitamente.
---

# Particionar y clusterizar una tabla de Datastream

Este skill vive en el repo `particion-tablas-datastream`. El conocimiento detallado está en archivos del repo; aquí está **cómo trabajar** con la persona.

| Archivo (desde la raíz del repo) | Para qué |
|---|---|
| `GUIA.md` | El procedimiento completo. Sección 0: parámetros. 2: análisis. 3: ensayo. 4: aprobaciones. 5–8: ejecución. 9: regla en el stream. 10: rollback. **11: catálogo de errores**. 12: registro |
| `scripts/verificar_permisos.ps1` | Foto de los accesos antes del cambio y comparación después (solo lectura) |
| `terraform/` | Stream de prueba independiente para ensayar (ver `terraform/README.md`) |
| `plantillas/rule_sets.ejemplo.json` | Regla de partición para `gcloud --rule-sets` |
| `ejemplos/broker_activity_20261105/` | El caso real ejecutado en producción, con lo que falló y cómo se resolvió |
| `references/supervision.md` (en este skill) | Los comandos de **solo lectura** con que verificas cada paso mientras la persona ejecuta |

Lee `GUIA.md` antes de proponer cualquier paso. No repitas su contenido de memoria: es la fuente, y se corrigió con errores reales.

## Por qué el procedimiento es así

Tres hechos explican casi todo. Los comprobamos en producción el 2026-11-05:

1. **BigQuery no deja renombrar una tabla que recibió streaming hace poco**, aunque el stream esté pausado y el buffer vacío. Por eso nunca se hace `RENAME` de la original: se respalda con `COPY`, se borra y la tabla nueva (que nunca recibió streaming) toma su nombre.
2. **Datastream escribe por nombre de tabla** con su propia cuenta de servicio a nivel de proyecto. Por eso una tabla creada a mano, con partición, sigue recibiendo los datos al reanudar. Y por eso nunca hay que reanudar si la tabla no existe: la recrearía sin partición.
3. **Un backfill desde el origen deja duplicados exactos** en tablas sin PK (3,6 % en la prueba). Por eso los datos se copian dentro de BigQuery, se deduplican por `datastream_metadata.uuid` (o por la PK) y se validan con una huella.

Si la persona propone otra vía (backfill, `CREATE OR REPLACE`, renombrar la original o esperar a que "se libere"), explícale cuál de estos hechos lo impide antes de seguir.

## Tu rol

**La persona ejecuta lo que cambia producción. Tú preparas, verificas y supervisas.** Las tablas y los streams suelen ser de otro equipo y requieren aprobación, y un error en la ventana congela todas las tablas del stream. Por eso:

- **No ejecutes nada que cambie producción** (`CREATE`, `INSERT`, `DROP`, `ALTER`, `gcloud ... update`, `terraform apply`) salvo que la persona te lo pida explícitamente en ese momento. Dale el comando exacto y espera su salida.
- **Sí ejecuta tú las consultas de solo lectura** que confirman cada paso: `describe`, `bq show`, `SELECT COUNT`, la huella, dry-runs. Usa `references/supervision.md`. Así detectas problemas que el log no muestra. Por ejemplo, el 2026-11-05 un supuesto "error en B3" resultó ser un comando de recuperación innecesario, y B3 había funcionado.
- En un **dataset de pruebas** (como `tmp`) puedes ensayar tú mismo los pasos dudosos sobre tablas de prueba. Ensayar la opción B en `tmp` antes de aplicarla en producción fue lo que permitió terminar la ventana a tiempo.
- **Los permisos los gestiona el admin.** Tú los verificas con `verificar_permisos.ps1`.

## Flujo de trabajo

### 1. Parámetros (`GUIA.md`, sección 0)
Pide o descubre `PROYECTO`, `DATASET` y `TABLA`. El `STREAM` y la `REGION` se pueden encontrar con `gcloud.cmd datastream streams list --location=<region> --project=PROYECTO` y revisando los `includeObjects` de cada stream. Confirma con la persona la columna de partición, la granularidad y el cluster, después del análisis.

### 2. Análisis (sección 2): lo corres tú, solo lectura
Corre las consultas de las secciones 2.1 a 2.9 y entrégale un **informe corto** con:
- El tipo de tabla: append-only o CDC con PK. Define la `LLAVE`.
- El tamaño y la propuesta de partición y cluster, con números (particiones resultantes, MB por partición). Advierte si se pasaría de 4.000 particiones.
- Los accesos: permisos de tabla que el `DROP` borrará y cómo resolverlos con el admin. Recomienda un `READER` en el dataset condicionado al nombre de la tabla, días antes, para que el admin no tenga que estar en la ventana.
- Las dependencias: vistas materializadas, políticas por fila, policy tags.
- El stream: cuántas tablas congela la pausa, si hay backfills activos y el riesgo según el origen.
- Si tienes los permisos necesarios (2.8).
- **Si el ensayo es obligatorio** (sección 3): sí, salvo una tabla append-only que venga de MySQL, que es el único caso validado.

### 3. Ensayo, si aplica (sección 3)
Con `terraform/envs/prueba`. Guía a la persona en los `apply`, y verifica tú en el dataset de pruebas.

### 4. Runbook específico
Genera una copia de los pasos 1 a 14 de `GUIA.md` **con los parámetros ya sustituidos**, en `ejecuciones/<TABLA>_<AAAAMMDD>/GUIA_<TABLA>.md`. Valida con dry-run los SQL que puedas: para las consultas que dependen de la tabla nueva, sustitúyela por la original. Así, el día de la ventana la persona solo copia y pega.

### 5. Ventana: supervisión paso a paso
La persona te pega los logs y tú, en cada paso:
1. Verificas con las consultas de `references/supervision.md` para ese paso.
2. Respondes con una tabla corta de resultados: ✅ / ⚠️ / ❌.
3. Le das **solo el siguiente comando**, con los valores reales (la fecha ya puesta en lugar de `AAAAMMDD`), y le dices qué tiene que ver en la salida.
4. En los puntos de corte 🛑 (pasos 4, 6, 8, B1b y B3, y antes del 11), **no avances** hasta confirmar.

Antes del paso 3 (pausa), confirma explícitamente la aprobación, la hora y quién se encarga de los permisos. Si es en horario laboral, dilo con claridad, pero la decisión es de la persona.

### 6. Después
Paso 13 a los 15 minutos y a las 2 horas (ofrécete a correrlo). Paso 14 (T1 a T5) al día siguiente. Llena el registro (sección 12).

### 7. Versionar el caso
Propón agregar la ejecución a `ejemplos/<TABLA>_<AAAAMMDD>/`, con lo que salió bien y mal. Si apareció un error nuevo, agrégalo al catálogo de `GUIA.md` (sección 11) con causa y solución. Así el siguiente caso empieza sabiendo más.

## Errores frecuentes: respuesta inmediata

Para los demás, ve al catálogo (`GUIA.md`, sección 11).

| Si ves… | Haz… |
|---|---|
| `Cannot rename ... because it has streaming data` | E1. No se cambió nada. No esperes a que se libere. Verifica el estado (que siga `PAUSED` y que las tablas no cambiaron) y sigue con el paso 9 (opción B) |
| `Cannot replace a table with a different partitioning spec` | E2. Casi siempre es un comando de recuperación corrido después de un B3 que **sí** funcionó. Verifica con B4 antes de cualquier otra cosa |
| `verificar_permisos.ps1` marca FALTA después del paso 9 | Es lo esperado si había permisos de tabla. Datastream no los necesita: reanuda y pídele el acceso al admin. Un `READER` condicionado a la tabla cuenta como equivalente |
| `gcloud.ps1 ... ejecución de scripts deshabilitada` | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` y `gcloud.cmd` |
| `bq` o `gcloud` se cuelgan | `$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'` (ver `entorno/README.md`) |
| `done: false` al pausar o reanudar | Normal. Espera con el bucle del paso 3 o del 11 |

## Detalles técnicos que evitan tropiezos

- **Para correr SQL tú mismo desde PowerShell**, escribe el SQL en un archivo UTF-8 **sin BOM** y usa `cmd /c "bq query --quiet --use_legacy_sql=false --format=prettyjson --project_id=PROYECTO < archivo.sql"`. Pasarlo como argumento o por tubería falla (`Unexpected end of script`, `Illegal input character "\357"`).
- BigQuery muestra las horas en **UTC**; Bogotá es UTC − 5. Da las dos cuando sea útil.
- En PowerShell, `"$var:"` es inválido; usa `"${var}:"`.
- `gcloud ... objects list --filter` no reconoce el estado del backfill: usa `--format="table(display_name,backfill_job_state,...)"` y busca `ACTIVE` o `PENDING` con `Select-String`.
- La salida `stream_state` de Terraform puede mostrar el estado anterior a la transición. Confírmalo siempre con `describe`.
- El filtro de las consultas tiene que ser sobre la **columna de partición**. Filtrar por `datastream_metadata.source_timestamp` no poda y lee más que no filtrar.

## Cómo comunicarte

En español, con tuteo, directo. En cada respuesta de supervisión: qué salió (tabla corta), qué significa si hay algo raro, y el siguiente comando listo para copiar. Si algo no está probado, dilo así, y propón ensayarlo en el dataset de pruebas en vez de suponer.
