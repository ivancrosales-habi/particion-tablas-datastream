# Stream de Datastream: MySQL -> un solo dataset de BigQuery, con reglas de
# partición y cluster por tabla.
#
# Los perfiles de conexión NO se crean aquí: se referencian por nombre. Así el
# módulo no puede modificar los perfiles que usa producción.

resource "google_datastream_stream" "this" {
  project       = var.project_id
  location      = var.location
  stream_id     = var.stream_id
  display_name  = var.display_name
  labels        = var.labels
  desired_state = var.desired_state

  source_config {
    source_connection_profile = var.source_connection_profile

    mysql_source_config {
      max_concurrent_cdc_tasks      = var.max_concurrent_cdc_tasks
      max_concurrent_backfill_tasks = var.max_concurrent_backfill_tasks

      include_objects {
        dynamic "mysql_databases" {
          for_each = var.mysql_tables
          content {
            database = mysql_databases.key

            dynamic "mysql_tables" {
              for_each = mysql_databases.value
              content {
                table = mysql_tables.value
              }
            }
          }
        }
      }

      # Mismo método de CDC que habi-brokers-co (posición del binlog).
      binary_log_position {}
    }
  }

  destination_config {
    destination_connection_profile = var.destination_connection_profile

    bigquery_destination_config {
      data_freshness = var.data_freshness

      single_target_dataset {
        dataset_id = "${var.project_id}:${var.dataset_id}"
      }

      dynamic "merge" {
        for_each = var.write_mode == "merge" ? [1] : []
        content {}
      }

      dynamic "append_only" {
        for_each = var.write_mode == "append_only" ? [1] : []
        content {}
      }
    }
  }

  dynamic "backfill_all" {
    for_each = var.backfill == "all" ? [1] : []
    content {}
  }

  dynamic "backfill_none" {
    for_each = var.backfill == "none" ? [1] : []
    content {}
  }

  dynamic "rule_sets" {
    for_each = var.table_rules
    content {
      object_filter {
        source_object_identifier {
          mysql_identifier {
            database = rule_sets.value.database
            table    = rule_sets.value.table
          }
        }
      }

      dynamic "customization_rules" {
        for_each = rule_sets.value.partition == null ? [] : [rule_sets.value.partition]
        content {
          bigquery_partitioning {
            require_partition_filter = customization_rules.value.require_partition_filter
            time_unit_partition {
              column                        = customization_rules.value.column
              partitioning_time_granularity = "PARTITIONING_TIME_GRANULARITY_${upper(customization_rules.value.granularity)}"
            }
          }
        }
      }

      dynamic "customization_rules" {
        for_each = length(rule_sets.value.cluster_columns) == 0 ? [] : [rule_sets.value.cluster_columns]
        content {
          bigquery_clustering {
            columns = customization_rules.value
          }
        }
      }
    }
  }
}
