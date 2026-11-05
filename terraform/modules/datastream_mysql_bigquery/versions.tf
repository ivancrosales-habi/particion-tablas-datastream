terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # rule_sets (bigquery_partitioning / bigquery_clustering) existe en el provider GA.
      version = ">= 6.0"
    }
  }
}
