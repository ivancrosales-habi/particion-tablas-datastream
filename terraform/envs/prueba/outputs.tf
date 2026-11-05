output "stream_name" {
  value = module.stream.stream_name
}

# Ojo: justo después de un apply puede mostrar el estado anterior a la transición.
# El estado real se consulta con: gcloud.cmd datastream streams describe <stream_id> ...
output "stream_state" {
  value = module.stream.stream_state
}

output "tablas_destino" {
  description = "Tablas que crea Datastream en el dataset de prueba (<base>_<tabla>)."
  value       = module.stream.destination_tables
}
