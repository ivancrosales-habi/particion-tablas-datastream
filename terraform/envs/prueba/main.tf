# Stream de PRUEBA para ensayar el particionamiento de una tabla de Datastream
# (sección 3 de GUIA.md). Es independiente del stream de producción: escribe en un
# dataset de pruebas y reutiliza, sin gestionarlos, los perfiles de conexión existentes.

# Solo lectura: el plan falla si el dataset de destino no existe.
data "google_bigquery_dataset" "destino" {
  project    = var.project_id
  dataset_id = var.dataset_id
}

module "stream" {
  source = "../../modules/datastream_mysql_bigquery"

  project_id    = var.project_id
  location      = var.location
  stream_id     = var.stream_id
  display_name  = var.stream_id
  labels        = var.labels
  desired_state = var.desired_state

  source_connection_profile     = var.source_connection_profile
  mysql_tables                  = var.mysql_tables
  max_concurrent_cdc_tasks      = 1
  max_concurrent_backfill_tasks = 2
  backfill                      = var.backfill

  destination_connection_profile = var.destination_connection_profile
  dataset_id                     = data.google_bigquery_dataset.destino.dataset_id
  # Usa los mismos valores que el stream de producción, para que el ensayo se comporte igual.
  data_freshness = var.data_freshness
  write_mode     = var.write_mode

  # Sin reglas = igual que un stream de producción que no las tiene.
  table_rules = var.aplicar_reglas_particion ? var.table_rules : []
}
