output "stream_name" {
  description = "Nombre completo del stream."
  value       = google_datastream_stream.this.name
}

output "stream_state" {
  value = google_datastream_stream.this.state
}

# En modo single_target_dataset Datastream nombra cada tabla <base>_<tabla>.
output "destination_tables" {
  description = "Tablas que Datastream creará en BigQuery, por tabla de origen."
  value = {
    for pair in flatten([
      for db, tables in var.mysql_tables : [for t in tables : { db = db, t = t }]
    ]) :
    "${pair.db}.${pair.t}" => "${var.project_id}.${var.dataset_id}.${pair.db}_${pair.t}"
  }
}
