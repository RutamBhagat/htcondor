terraform {
  required_version = ">= 1.10.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.21"
    }
  }
}

provider "oci" {
  auth                = "SecurityToken"
  config_file_profile = var.oci_config_profile
  region              = var.region
}
