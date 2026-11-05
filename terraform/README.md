# Terraform: stream de prueba para ensayar el particionamiento

Sirve para la **sección 3 de `GUIA.md`**: ensayar en un dataset de pruebas, con un stream de Datastream **independiente**, antes de tocar producción.

```
terraform/
├── modules/datastream_mysql_bigquery/   Módulo: stream MySQL -> un dataset de BigQuery, con rule_sets (partición y cluster)
└── envs/prueba/                         Entorno de ejemplo (estado local)
```

- El módulo **no crea perfiles de conexión**: los recibe por nombre. Así no puede modificar los de producción.
- El entorno tiene **candados**: rechaza los `stream_id` de `streams_produccion` y los datasets que coinciden con `patron_datasets_produccion`.
- Provider `hashicorp/google` ≥ 6 (probado con 8.10.0) y Terraform ≥ 1.5 (probado con 1.16.5).

## Uso

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$env:CLOUDSDK_PYTHON_SITEPACKAGES = '1'
cd terraform\envs\prueba
Copy-Item terraform.tfvars.example terraform.tfvars    # y ajústalo

terraform init
terraform plan -out="fase1.tfplan"                      # desired_state = "NOT_STARTED"
terraform apply "fase1.tfplan"                          # valida la conexión, no lee nada
# Cambia desired_state = "RUNNING" y repite plan y apply: Datastream crea la tabla <base>_<tabla> en el dataset de prueba
```

| Para… | Cambia en `terraform.tfvars` | Tipo de cambio (verificado) |
|---|---|---|
| Arrancar o pausar | `desired_state` | In-place |
| Quitar o agregar las reglas | `aplicar_reglas_particion` | In-place: no recrea el stream ni la tabla ni dispara un backfill |
| Pasar de `backfill = "none"` a `"all"` | `backfill` | In-place, pero **no dispara** el backfill de tablas que ya están en el stream. Para eso: `terraform apply -replace="module.stream.google_datastream_stream.this"` |
| Cerrar el ensayo | — | `terraform plan -destroy -out=cerrar.tfplan` y `terraform apply cerrar.tfplan`. Después, `DROP TABLE` en el dataset de prueba: Terraform no gestiona las tablas que crea Datastream |

## Cuidado

- El dataset de prueba puede tener **expiración por defecto**: `tmp` borra las tablas a los 5 días. Extiéndela con `ALTER TABLE ... SET OPTIONS (expiration_timestamp = ...)`.
- Datastream nombra la tabla `<base>_<tabla>` en modo de dataset único. No se puede elegir otro nombre.
- El estado es local (`terraform.tfstate`, en `.gitignore`). **No lo borres** mientras el stream exista.
- El stream de prueba es **otro lector del origen de producción**: con `backfill = "all"` lee toda la tabla.
