variable "project_id" {
  description = "Proyecto donde vive el stream y el dataset de destino."
  type        = string
}

variable "location" {
  description = "Región de Datastream."
  type        = string
}

variable "stream_id" {
  description = "ID del stream. Nunca el de un stream existente."
  type        = string
}

variable "display_name" {
  type = string
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "desired_state" {
  description = "NOT_STARTED crea el stream sin leer nada. RUNNING lo arranca. PAUSED lo pausa."
  type        = string
  default     = "NOT_STARTED"

  validation {
    condition     = contains(["NOT_STARTED", "RUNNING", "PAUSED"], var.desired_state)
    error_message = "desired_state debe ser NOT_STARTED, RUNNING o PAUSED."
  }
}

# --- Origen -------------------------------------------------------------------

variable "source_connection_profile" {
  description = "Nombre completo del perfil de conexión MySQL existente (se referencia, no se gestiona)."
  type        = string
}

variable "mysql_tables" {
  description = "Tablas a replicar: { base_de_datos = [tabla, ...] }."
  type        = map(list(string))
}

variable "max_concurrent_cdc_tasks" {
  type    = number
  default = 1
}

variable "max_concurrent_backfill_tasks" {
  type    = number
  default = 2
}

variable "backfill" {
  description = "none: solo cambios nuevos (CDC). all: además copia la historia completa desde MySQL."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "all"], var.backfill)
    error_message = "backfill debe ser none o all."
  }
}

# --- Destino ------------------------------------------------------------------

variable "destination_connection_profile" {
  description = "Nombre completo del perfil de conexión BigQuery existente (se referencia, no se gestiona)."
  type        = string
}

variable "dataset_id" {
  description = "Dataset único de destino (modo single_target_dataset). Debe existir."
  type        = string
}

variable "data_freshness" {
  type    = string
  default = "3600s"
}

variable "write_mode" {
  description = "merge (igual que habi-brokers-co) o append_only. Las tablas sin PK son append-only en cualquier caso."
  type        = string
  default     = "merge"

  validation {
    condition     = contains(["merge", "append_only"], var.write_mode)
    error_message = "write_mode debe ser merge o append_only."
  }
}

# --- Partición y cluster por tabla -----------------------------------------------

variable "table_rules" {
  description = <<-EOT
    Reglas de partición y cluster por tabla de origen. Datastream las aplica SOLO
    cuando crea la tabla en BigQuery.
      partition.granularity: HOUR | DAY | MONTH | YEAR
  EOT
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

  validation {
    condition     = alltrue([for r in var.table_rules : length(r.cluster_columns) <= 4])
    error_message = "BigQuery admite como máximo 4 columnas de cluster."
  }

  validation {
    condition = alltrue([
      for r in var.table_rules :
      r.partition == null ? true : contains(["HOUR", "DAY", "MONTH", "YEAR"], upper(r.partition.granularity))
    ])
    error_message = "partition.granularity debe ser HOUR, DAY, MONTH o YEAR."
  }
}
