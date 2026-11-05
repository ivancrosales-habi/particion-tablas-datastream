variable "project_id" {
  description = "Proyecto donde se crea el stream de prueba."
  type        = string
}

variable "location" {
  description = "Región de Datastream (la del perfil de origen)."
  type        = string
}

variable "stream_id" {
  description = "ID del stream de PRUEBA. Nunca el de un stream de producción."
  type        = string

  # Candado: agrega aquí los streams de producción de tu proyecto.
  validation {
    condition     = !contains(var.streams_produccion, var.stream_id)
    error_message = "Este entorno no puede gestionar un stream de producción."
  }
}

variable "streams_produccion" {
  description = "IDs de streams de producción que este entorno nunca debe tocar."
  type        = list(string)
  default     = []
}

variable "dataset_id" {
  description = "Dataset de PRUEBA donde Datastream crea la tabla (modo single_target_dataset). Debe existir."
  type        = string

  validation {
    condition     = !can(regex(var.patron_datasets_produccion, var.dataset_id))
    error_message = "No se puede usar un dataset de producción."
  }
}

variable "patron_datasets_produccion" {
  description = "Regex de datasets de producción que este entorno nunca debe usar (ej. ^(co|mx)_)."
  type        = string
  default     = "^(co|mx)_"
}

variable "source_connection_profile" {
  description = "Nombre completo del perfil de origen MySQL existente: projects/<p>/locations/<r>/connectionProfiles/<id>."
  type        = string
}

variable "destination_connection_profile" {
  description = "Nombre completo del perfil de destino BigQuery existente."
  type        = string
}

variable "mysql_tables" {
  description = "Tablas a replicar: { base_de_datos = [tabla, ...] }."
  type        = map(list(string))
}

variable "desired_state" {
  description = "NOT_STARTED (crea sin leer), RUNNING o PAUSED."
  type        = string
  default     = "NOT_STARTED"
}

variable "backfill" {
  description = "none: solo cambios nuevos. all: también la historia (lee todo el origen y deja duplicados en tablas sin PK)."
  type        = string
  default     = "none"
}

variable "data_freshness" {
  type    = string
  default = "3600s"
}

variable "write_mode" {
  description = "merge o append_only (usa el mismo que producción)."
  type        = string
  default     = "merge"
}

variable "aplicar_reglas_particion" {
  description = "true: el stream lleva table_rules. false: sin reglas, como un stream de producción que no las tiene."
  type        = bool
  default     = true
}

variable "table_rules" {
  description = "Reglas de partición y cluster por tabla de origen (ver el módulo)."
  type = list(object({
    database = string
    table    = string
    partition = optional(object({
      column                   = string
      granularity              = string
      require_partition_filter = optional(bool, false)
    }))
    cluster_columns = optional(list(string), [])
  }))
  default = []
}

variable "labels" {
  type    = map(string)
  default = { env = "test", purpose = "prueba-particion" }
}
