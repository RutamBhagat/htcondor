variable "compartment_id" {
  description = "OCID of the compartment that owns the lab resources."
  type        = string
}

variable "region" {
  description = "OCI home region. Always Free resources must remain in the home region."
  type        = string
  default     = "eu-frankfurt-1"
}

variable "oci_config_profile" {
  description = "OCI CLI profile used for SecurityToken authentication."
  type        = string
  default     = "DEFAULT"
}

variable "availability_domain" {
  description = "Availability domain with verified E2 micro quota and capacity."
  type        = string
}

variable "image_id" {
  description = "OCID of a verified Ubuntu 24.04 amd64 image compatible with E2 micro."
  type        = string
}

variable "admin_cidr" {
  description = "IPv4 CIDR allowed to administer both nodes over SSH."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid IPv4 CIDR narrower than 0.0.0.0/0."
  }
}

variable "ssh_public_key" {
  description = "SSH public key installed for the ubuntu user."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^ssh-(ed25519|rsa) ", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH Ed25519 or RSA public key."
  }
}

variable "name_prefix" {
  description = "Prefix used for lab resource display names."
  type        = string
  default     = "cern-htcondor"
}

variable "vcn_cidr" {
  description = "Private address range used by the HTCondor pool."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "Public subnet used by the two lab nodes."
  type        = string
  default     = "10.42.0.0/24"
}
