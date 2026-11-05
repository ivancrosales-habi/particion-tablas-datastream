# particion-tablas-datastream

Procedimiento, scripts y Terraform para **particionar y clusterizar una tabla de BigQuery que escribe Datastream**, sin perder datos, sin duplicarlos y conservando los accesos.

Se usó en producción el 2026-11-05 con `brokers-main-prod.co_habi_brokers.broker_activity`: 47,4 M de filas, partición mensual por `created_at` y cluster `created_at, broker_id`. Leer el mes en curso pasó de **2,34 GB a ~6 MB** por consulta (−99,7 %).

## Por dónde empezar

1. Lee **[`GUIA.md`](GUIA.md)**: el paso a paso obligatorio y el **catálogo de errores** (sección 11).
2. Llena la **hoja de parámetros** (sección 0) con tu tabla, dataset y stream.
3. Mira el caso real en **[`ejemplos/broker_activity_20261105/`](ejemplos/broker_activity_20261105/)**.

## Usarlo con Claude

El repo trae un skill, **`particionar-tabla-datastream`**, en `.claude/skills/`. Con él, Claude sabe qué hacer en cada fase:
- correr el análisis de solo lectura;
- decidir si hace falta un ensayo;
- generar el runbook con tus parámetros;
- **supervisar la ventana**: tú pegas los logs, él verifica en BigQuery y te da el siguiente comando;
- resolver los errores del catálogo.

- **Claude Code:** clona el repo y abre Claude Code en la carpeta. El skill y el `CLAUDE.md` se cargan solos. Pídele, por ejemplo: *"quiero particionar `mi-proyecto.mi_dataset.mi_tabla` que escribe el stream `mi-stream`"*.
- **Otra cuenta o equipo:** copia `.claude/skills/particionar-tabla-datastream/` a `~/.claude/skills/` para tenerlo disponible fuera del repo. Igual va a necesitar el repo para leer `GUIA.md` y los scripts.
- Pruebas del skill: `.claude/skills/particionar-tabla-datastream/evals/` (formato de `claude plugin eval`).

Claude **no ejecuta cambios en producción por su cuenta**: te da los comandos, y él solo corre consultas de verificación.

## Contenido

| Ruta | Qué es |
|---|---|
| `GUIA.md` | Guía genérica: análisis, ensayo, aprobaciones, ventana (pausar, copiar, validar, `COPY` + `DROP` + `RENAME`, reanudar), verificación, regla opcional en el stream, rollback, varias tablas en una ventana, cómo aprovechar la partición en los consumidores, **catálogo de 42 errores** y registro |
| `scripts/verificar_permisos.ps1` | Foto de los accesos (tabla y dataset) antes del cambio y comparación después. Solo lectura. Reconoce un acceso `READER` en el dataset condicionado a la tabla como equivalente a un permiso de tabla |
| `plantillas/rule_sets.ejemplo.json` | Plantilla para agregar la regla de partición a un stream con `gcloud --rule-sets` |
| `terraform/` | Módulo y entorno para crear un **stream de prueba independiente** y ensayar antes de producción. Ver `terraform/README.md` |
| `entorno/` | Arreglo para `bq` y `gcloud` cuando la red tiene IPv6 roto (Windows) |
| `.claude/skills/particionar-tabla-datastream/` | Skill de Claude: flujo de trabajo, rol de supervisión, comandos de verificación de solo lectura y casos de prueba |
| `CLAUDE.md` | Reglas para Claude Code en este repo |
| `ejemplos/broker_activity_20261105/` | El caso real: la guía específica usada en producción, los resultados de la prueba y de los ensayos, las pruebas de partición y cluster, y el ensayo en `tmp` |

## Reglas que no se negocian

1. **Nunca se hace `RENAME` de la tabla que recibe streaming.** BigQuery lo bloquea: `Cannot rename ... because it has streaming data`, aunque el stream esté pausado y el buffer vacío. Se usa **respaldo con `COPY`, `DROP` de la original y `RENAME` de la nueva**.
2. **No se hace backfill desde el origen** para llenar la tabla particionada: en tablas sin PK dejó un 3,6 % de duplicados exactos. Los datos se copian dentro de BigQuery y se validan con una huella.
3. **Nunca se reanuda el stream si la tabla no existe**: Datastream la crearía sin partición.
4. **Se deduplica por `datastream_metadata.uuid`** (tablas append-only) o por la PK (tablas CDC). Nunca por el `id` de negocio.
5. **Los permisos los gestiona el admin.** Quien ejecuta solo los verifica con `verificar_permisos.ps1`.

## Qué está validado y qué no

| Caso | Estado |
|---|---|
| Tabla **append-only** (sin PK) de origen **MySQL**, stream en modo `merge` | ✅ Validado en producción y con 3 ensayos |
| Tabla **CDC con PK** (upserts) | ⚠️ Sin validar. El ensayo de la sección 3 de la guía es obligatorio |
| Origen **PostgreSQL**, Oracle o SQL Server | ⚠️ Sin validar. Ensayo obligatorio. En PostgreSQL, la pausa retiene WAL en el origen |
| Tablas con políticas por fila o vistas materializadas | ⚠️ Sin validar. Ensayo obligatorio |

## Requisitos

- Windows PowerShell 5.1 con `gcloud` y `bq` (Google Cloud SDK) con la sesión iniciada. Usa `gcloud.cmd`.
- En cada ventana: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` y `$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'`.
- Para el ensayo: Terraform ≥ 1.5.
- Permisos de quien ejecuta: ver la sección 2.8 de la guía. `setIamPolicy` **no** hace falta.

## Qué no está en el repo (y por qué)

- Estados y planes de Terraform, `terraform.tfvars` reales, fotos de permisos y la configuración exportada de los streams: contienen configuración y accesos reales de producción (`.gitignore`).
- Los scripts de la primera versión del plan, que usaban `RENAME` de la tabla original: ese enfoque falla en producción.
