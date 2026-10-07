locals {
  nodes = toset(["controller", "worker"])

  common_tags = {
    Project = "cern-htcondor-lab"
    Budget  = "always-free"
  }
}

resource "oci_core_vcn" "lab" {
  cidr_block     = var.vcn_cidr
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-vcn"
  dns_label      = "htcondorlab"
  freeform_tags  = local.common_tags
}

resource "oci_core_internet_gateway" "lab" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-internet-gateway"
  enabled        = true
  vcn_id         = oci_core_vcn.lab.id
  freeform_tags  = local.common_tags
}

resource "oci_core_route_table" "lab" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-public-routes"
  vcn_id         = oci_core_vcn.lab.id
  freeform_tags  = local.common_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.lab.id
  }
}

resource "oci_core_security_list" "lab" {
  compartment_id = var.compartment_id
  display_name   = "${var.name_prefix}-security-list"
  vcn_id         = oci_core_vcn.lab.id
  freeform_tags  = local.common_tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    description = "SSH from the administrator network"
    protocol    = "6"
    source      = var.admin_cidr

    tcp_options {
      max = 22
      min = 22
    }
  }

  ingress_security_rules {
    description = "HTCondor only within the lab VCN"
    protocol    = "6"
    source      = var.vcn_cidr

    tcp_options {
      max = 9618
      min = 9618
    }
  }
}

resource "oci_core_subnet" "lab" {
  cidr_block                 = var.subnet_cidr
  compartment_id             = var.compartment_id
  display_name               = "${var.name_prefix}-public-subnet"
  dns_label                  = "nodes"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.lab.id
  security_list_ids          = [oci_core_security_list.lab.id]
  vcn_id                     = oci_core_vcn.lab.id
  freeform_tags              = local.common_tags
}

resource "oci_core_instance" "node" {
  for_each = local.nodes

  availability_domain  = var.availability_domain
  compartment_id       = var.compartment_id
  display_name         = "${var.name_prefix}-${each.key}"
  preserve_boot_volume = false
  shape                = "VM.Standard.E2.1.Micro"
  freeform_tags        = merge(local.common_tags, { Role = each.key })

  create_vnic_details {
    assign_public_ip = true
    display_name     = "${var.name_prefix}-${each.key}-vnic"
    hostname_label   = each.key
    subnet_id        = oci_core_subnet.lab.id
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  metadata = {
    ssh_authorized_keys = trimspace(var.ssh_public_key)
  }

  source_details {
    boot_volume_size_in_gbs = 50
    source_id               = var.image_id
    source_type             = "image"
  }
}
