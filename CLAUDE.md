# particion-tablas-datastream

Este repo sirve para particionar y clusterizar tablas de BigQuery que escribe Datastream. Para cualquier tarea de ese tipo (planear, ensayar, ejecutar o supervisar una ventana, o resolver un error), usa el skill **`particionar-tabla-datastream`** (`.claude/skills/particionar-tabla-datastream/`). La fuente del procedimiento es `GUIA.md`.

## Reglas
- Escribe en español, con tuteo.
- No ejecutes nada que cambie producción (`CREATE`, `INSERT`, `DROP`, `ALTER`, `gcloud ... update`, `terraform apply`) sin que la persona lo pida en ese momento. Las consultas de solo lectura sí puedes correrlas para verificar.
- Nunca hagas `RENAME` de la tabla que recibe streaming. Nunca reanudes un stream si su tabla no existe. No uses backfill para llenar la tabla particionada.
- No subas al repo estados ni planes de Terraform, `terraform.tfvars` reales, fotos de permisos ni configuraciones exportadas de streams (ya están en `.gitignore`). Cambia los correos personales por roles.
- Si aparece un error nuevo, agrégalo al catálogo de `GUIA.md` (sección 11) con su causa y solución. Guarda cada ejecución en `ejemplos/<tabla>_<AAAAMMDD>/`.
