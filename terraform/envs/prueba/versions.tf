terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }

  # Estado local: es una prueba de un solo operador. Si la prueba se vuelve
  # permanente, mover a un backend "gcs" con bloqueo.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "google" {
  project = var.project_id
  region  = var.location
}
